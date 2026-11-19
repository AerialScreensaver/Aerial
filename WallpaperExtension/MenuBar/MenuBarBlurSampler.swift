//
//  MenuBarBlurSampler.swift
//  Aerial4WallpaperExtension
//
//  "Light blur" / "Dark blur": turn the part of a decoded frame that
//  sits behind the menu bar into a tiny, heavily blurred, tinted image.
//  The band layer stretches it across the strip, which finishes the
//  blur for free. The tint is applied on sRGB-encoded values so the
//  luminance floor/ceiling promised by `MenuBarBackgroundRule.blurTint`
//  holds on screen. Runs about once a second, off every renderer queue.
//

import CoreImage
import CoreVideo

enum MenuBarBlurSampler {

    /// Gaussian radius in output pixels. The blur amount picks the output
    /// width instead (a stronger blur = a smaller image, stretched more),
    /// so the radius-to-size ratio, and the smoothness of the stretch,
    /// stay the same at every setting.
    private static let blurRadius = 3.0
    /// Mild boost, as system materials do; the tint washes colour out.
    private static let saturation = 1.3

    /// `blurFraction`: blur radius as a fraction of the band's width
    /// (`MenuBarBackgroundRule.blurWidthFraction`).
    static func image(from buffer: CVPixelBuffer, sourceRect: CGRect, blurFraction: Double,
                      tint: (scale: Double, bias: Double)) -> CGImage? {
        let frame = CIImage(cvPixelBuffer: buffer)
        let crop = sourceRect.intersection(frame.extent)
        guard !crop.isNull, crop.width >= 1, crop.height >= 1,
              blurFraction.isFinite, blurFraction > 0 else { return nil }
        // 60 px wide at the strongest blur, 600 at the weakest.
        let width = min(max((blurRadius / blurFraction).rounded(), 32), 1024)
        // Same shape as the sampled strip, so the blur is as wide as it is tall.
        let outputSize = CGSize(width: width, height: max(2, (width * crop.height / crop.width).rounded()))

        let scaleY = outputSize.height / crop.height
        let scaleX = outputSize.width / crop.width
        let output = CGRect(origin: .zero, size: outputSize)
        // Clamp before each resampling step so the edges don't fade to clear.
        let small = frame.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scaleY,
                kCIInputAspectRatioKey: scaleX / scaleY,
            ])
            .cropped(to: output)
        let scale = CGFloat(tint.scale), bias = CGFloat(tint.bias)
        let tinted = small
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation])
            // HDR frames can exceed 1; the tint maths assumes 0...1.
            .applyingFilter("CIColorClamp")
            .applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ])
            .applyingFilter("CISRGBToneCurveToLinear")
            .cropped(to: output)

        return MenuBarColorSampler.context.createCGImage(
            tinted, from: output, format: .RGBA8, colorSpace: MenuBarColorSampler.sRGB)
    }
}

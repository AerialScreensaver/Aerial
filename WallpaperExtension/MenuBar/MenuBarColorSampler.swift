//
//  MenuBarColorSampler.swift
//  Aerial4WallpaperExtension
//
//  "Color from video": average the top strip of a decoded frame (what
//  sits under the menu bar) into one band colour, then nudge it into a
//  decisively light or dark tone (`MenuBarBackgroundRule.readable`).
//  Runs once per video, off every renderer queue.
//

import CoreImage
import CoreVideo

enum MenuBarColorSampler {

    /// Fraction of the frame height averaged, from the top edge.
    private static let stripFraction: CGFloat = 0.08
    private static let minStripPixels: CGFloat = 32

    /// One per process — CIContext setup is expensive. The output is a
    /// single pixel, so the render itself is cheap.
    private static let context = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false,
    ])

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func color(from buffer: CVPixelBuffer) -> CGColor? {
        let image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        // Core Image is y-up: the top of the picture is at maxY.
        let stripHeight = min(extent.height, max(minStripPixels, extent.height * stripFraction))
        let strip = CGRect(x: extent.minX, y: extent.maxY - stripHeight,
                           width: extent.width, height: stripHeight)
        guard let average = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: strip),
        ])?.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: sRGB)
        let rgb = MenuBarBackgroundRule.readable(red: Double(pixel[0]) / 255,
                                                 green: Double(pixel[1]) / 255,
                                                 blue: Double(pixel[2]) / 255)
        return CGColor(colorSpace: sRGB, components: [rgb.red, rgb.green, rgb.blue, 1])
    }
}

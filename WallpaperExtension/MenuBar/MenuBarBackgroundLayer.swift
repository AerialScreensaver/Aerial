//
//  MenuBarBackgroundLayer.swift
//  Aerial4WallpaperExtension
//
//  The "Menu bar background" band: a solid strip across the top of a
//  desktop window, exactly as tall as the menu bar (notch included),
//  with a soft shadow beneath. macOS picks the menu bar's text/glyph
//  tint from the pixels behind it; a solid band keeps that choice
//  stable whatever the video shows.
//
//  Pure presentation — knows nothing about renderers or settings.
//  `MenuBarBackgroundController` decides when it exists and what colour
//  it is. Never part of a snapshot: snapshots copy decoded video frames
//  and never render the layer tree.
//

import QuartzCore

final class MenuBarBackgroundLayer: CALayer {

    /// Colour cross-fade at a video change (Color from video).
    static let colorFadeSeconds: CFTimeInterval = 0.6

    /// Build a band for a window of `size` (the rootLayer bounds, y-up).
    static func make(size: CGSize, height: CGFloat, contentsScale: CGFloat, color: CGColor) -> MenuBarBackgroundLayer {
        let layer = MenuBarBackgroundLayer()
        layer.isOpaque = true
        // Above the video, transition ghosts and overlays (all at 0), below
        // the "No videos" fallback (1 000) and the diagnostic badge (10 000).
        layer.zPosition = 900
        layer.backgroundColor = color
        layer.shadowColor = CGColor(gray: 0, alpha: 1)
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.resize(to: size, height: height, contentsScale: contentsScale)
        return layer
    }

    /// Re-frame for a new window size, menu bar height or scale.
    func resize(to size: CGSize, height: CGFloat, contentsScale: CGFloat) {
        let band = CGRect(x: 0, y: size.height - height, width: size.width, height: height)
            .sanitized("menu bar band")
        frame = band
        self.contentsScale = contentsScale
        // Explicit path: no offscreen pass to derive the shadow shape.
        shadowPath = CGPath(rect: CGRect(origin: .zero, size: band.size), transform: nil)
    }

    func setColor(_ color: CGColor, animated: Bool) {
        guard animated else {
            backgroundColor = color
            return
        }
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = presentation()?.backgroundColor ?? backgroundColor
        fade.toValue = color
        fade.duration = Self.colorFadeSeconds
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        backgroundColor = color
        add(fade, forKey: "color")
    }
}

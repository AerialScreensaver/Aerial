//
//  MenuBarBackground.swift
//  Shared between Companion app and Aerial4WallpaperExtension.
//
//  "Menu bar background": an optional band the wallpaper extension
//  draws behind the macOS menu bar so its text/glyph tint (which the
//  system derives from the pixels underneath) stays stable whatever the
//  video shows. Solid (white, black, a colour per video) or a tinted
//  blur of the video that follows it slowly. Style lives in the control
//  file; the pure rules here are shared so they can be unit-tested from
//  the Companion test bundle.
//

import CoreGraphics
import Foundation

/// Stored in the control file as the raw string so an older extension
/// reading a newer style falls back to `.off`.
enum MenuBarBackgroundStyle: String, Codable, CaseIterable, Sendable {
    case off
    case white
    case black
    /// A colour sampled from the top of each video, picked at every cut.
    case videoColor
    /// A heavy blur of the video behind the bar, mixed toward white.
    case lightBlur
    /// The same blur, mixed toward black.
    case darkBlur

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .white: return "White"
        case .black: return "Black"
        case .videoColor: return "Color from video"
        case .lightBlur: return "Light blur"
        case .darkBlur: return "Dark blur"
        }
    }

    var isBlur: Bool { self == .lightBlur || self == .darkBlur }
}

/// How the video is scaled into its host layer, as far as the band's
/// sampling is concerned.
enum MenuBarBandGravity: Sendable {
    case fill, fit, stretch
}

enum MenuBarBackgroundRule {
    /// Whether a window draws the band right now. Desktop wallpaper only:
    /// never the screensaver (its own windows, the saver fallback flipping
    /// desktop windows to `idle`, or an excluded saver window), never a
    /// System Settings preview, never the lock screen (no menu bar), and
    /// never a screen without a permanent menu bar (auto-hide, or a
    /// secondary display when "Displays have separate Spaces" is off).
    static func shouldShow(style: MenuBarBackgroundStyle, menuBarHeight: Double,
                           isScreenSaver: Bool, isPreview: Bool, saverExcluded: Bool,
                           saverFallbackActive: Bool, presentationMode: String) -> Bool {
        guard style != .off, menuBarHeight > 1 else { return false }
        if isScreenSaver || isPreview || saverExcluded || saverFallbackActive { return false }
        return presentationMode != "locked" && presentationMode != "idle"
    }

    /// Nudge a sampled average colour (sRGB components, 0...1) into a
    /// band colour the system tints decisively: slightly desaturated, and
    /// pushed out of the mid-brightness range where the menu bar would
    /// keep hesitating between dark and light text.
    static func readable(red: Double, green: Double, blue: Double) -> (red: Double, green: Double, blue: Double) {
        var (h, s, v) = hsb(red: red, green: green, blue: blue)
        s *= 0.8
        v = v > 0.55 ? max(v, 0.85) : min(v, 0.30)
        return rgb(hue: h, saturation: s, brightness: v)
    }

    // MARK: Blur styles

    static let defaultBlurStrength = 0.7
    static let blurStrengthRange = 0.5...0.9

    /// The tint strength in use: the user's setting when set, clamped so
    /// the band can never get transparent enough for the system to flip
    /// the menu bar text.
    static func blurStrength(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite else { return defaultBlurStrength }
        return min(max(raw, blurStrengthRange.lowerBound), blurStrengthRange.upperBound)
    }

    static let defaultBlurAmount = 0.5

    /// The blur slider's value in use (0 = barely blurred, 1 = shapes
    /// dissolve entirely); the default when never set.
    static func blurAmount(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite else { return defaultBlurAmount }
        return min(max(raw, 0), 1)
    }

    /// Blur radius as a fraction of the band's width for a slider value:
    /// 0.5% at 0, about 1.6% at the default, 5% at 1. Geometric, so each
    /// slider step changes the look by the same visible amount.
    static func blurWidthFraction(amount: Double) -> Double {
        0.005 * pow(10, blurAmount(amount))
    }

    /// Per-channel `out = in × scale + bias` (sRGB-encoded values) for a
    /// blur style. Light never goes below `strength`, dark never above
    /// `1 − strength`, whatever the video shows.
    static func blurTint(style: MenuBarBackgroundStyle, strength: Double) -> (scale: Double, bias: Double) {
        let a = blurStrength(strength)
        return (1 - a, style == .lightBlur ? a : 0)
    }

    /// The part of the decoded frame (pixels, y-up like Core Image) that
    /// a blur band samples. `bandRect` and `layerFrame` are in the
    /// window's root-layer space (y-up); `layerFrame` is the video host
    /// layer, larger than the window and offset in spanned mode. Exactly
    /// what is behind the band, so a light blur lines up with the video
    /// below it. Nil when no picture sits behind the band (letterbox).
    static func sourceRect(bandRect: CGRect, windowSize: CGSize, layerFrame: CGRect,
                           gravity: MenuBarBandGravity, imageSize: CGSize) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0,
              layerFrame.width > 0, layerFrame.height > 0 else { return nil }
        var sx = layerFrame.width / imageSize.width
        var sy = layerFrame.height / imageSize.height
        switch gravity {
        case .fill: sx = max(sx, sy); sy = sx
        case .fit: sx = min(sx, sy); sy = sx
        case .stretch: break
        }
        // Where the whole picture lands in the window, centred in its layer.
        let drawn = CGRect(x: layerFrame.midX - imageSize.width * sx / 2,
                           y: layerFrame.midY - imageSize.height * sy / 2,
                           width: imageSize.width * sx, height: imageSize.height * sy)
        let visible = CGRect(origin: .zero, size: windowSize)
            .intersection(layerFrame).intersection(drawn)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }

        let strip = bandRect.intersection(visible)
        guard !strip.isNull, strip.width > 0, strip.height > 0 else { return nil }

        let source = CGRect(x: (strip.minX - drawn.minX) / sx, y: (strip.minY - drawn.minY) / sy,
                            width: strip.width / sx, height: strip.height / sy)
            .intersection(CGRect(origin: .zero, size: imageSize))
        guard !source.isNull, source.width >= 1, source.height >= 1 else { return nil }
        return source
    }

    private static func hsb(red r: Double, green g: Double, blue b: Double) -> (Double, Double, Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { h = (b - r) / delta + 2 }
            else { h = (r - g) / delta + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, maxC > 0 ? delta / maxC : 0, maxC)
    }

    private static func rgb(hue h: Double, saturation s: Double, brightness v: Double) -> (red: Double, green: Double, blue: Double) {
        let c = v * s
        let hp = h * 6
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch hp {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = v - c
        return (r + m, g + m, b + m)
    }
}

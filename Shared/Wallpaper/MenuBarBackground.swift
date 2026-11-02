//
//  MenuBarBackground.swift
//  Shared between Companion app and Aerial4WallpaperExtension.
//
//  "Menu bar background": an optional solid band the wallpaper extension
//  draws behind the macOS menu bar so its text/glyph tint (which the
//  system derives from the pixels underneath) stays stable whatever the
//  video shows. Style lives in the control file; the pure rules here are
//  shared so they can be unit-tested from the Companion test bundle.
//

import Foundation

/// Stored in the control file as the raw string so an older extension
/// reading a newer style falls back to `.off`.
enum MenuBarBackgroundStyle: String, Codable, CaseIterable, Sendable {
    case off
    case white
    case black
    /// A colour sampled from the top of each video, picked at every cut.
    case videoColor

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .white: return "White"
        case .black: return "Black"
        case .videoColor: return "Color from video"
        }
    }
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

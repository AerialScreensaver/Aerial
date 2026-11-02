//
//  MenuBarGeometry.swift
//  Aerial
//
//  Measures the menu bar a given NSScreen shows, accounting for the
//  notch on built-in displays (the menu bar grows to the notch height
//  there). Only Companion measures: in the wallpaper extension NSScreen
//  geometry is frozen at first access, so the result is relayed through
//  `WallpaperControlState.menuBarGeometry`.
//

import AppKit

struct MenuBarGeometry: Codable, Equatable {
    /// Height of the menu bar in points; 0 when the screen shows no
    /// permanent menu bar (auto-hide on, or a secondary display while
    /// "Displays have separate Spaces" is off).
    var height: CGFloat
    /// True on a display with a camera housing cut into the top edge.
    var hasNotch: Bool

    static let none = MenuBarGeometry(height: 0, hasNotch: false)

    static func detect(for screen: NSScreen) -> MenuBarGeometry {
        resolve(visibleTop: DockInfo.detect(for: screen).menuBar,
                safeAreaTop: screen.safeAreaInsets.top)
    }

    /// Pure part of `detect`. `visibleTop` is the frame/visibleFrame top
    /// inset (0 when the menu bar auto-hides); `safeAreaTop` is non-zero
    /// only on a notched display, where it spans the notch. The notch
    /// height wins when larger so the band covers the whole bar even if
    /// visibleFrame comes up a point short.
    static func resolve(visibleTop: CGFloat, safeAreaTop: CGFloat) -> MenuBarGeometry {
        let hasNotch = safeAreaTop > 0
        guard visibleTop > 1 else { return MenuBarGeometry(height: 0, hasNotch: hasNotch) }
        return MenuBarGeometry(height: hasNotch ? max(visibleTop, safeAreaTop) : visibleTop,
                               hasNotch: hasNotch)
    }
}

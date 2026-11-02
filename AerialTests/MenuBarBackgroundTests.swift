//
//  MenuBarBackgroundTests.swift
//  AerialTests
//
//  "Menu bar background" (2026-10-27): the band the wallpaper extension
//  draws behind the menu bar. These pin the notch-aware height, the
//  desktop-only show rule, the readable-colour clamp, and the tolerant
//  decode of the two new control-file fields.
//

import CoreGraphics
import Foundation
import Testing
@testable import Aerial

@Suite("Menu bar background")
struct MenuBarBackgroundTests {

    // MARK: Geometry

    @Test("no notch: the visible top inset is the height")
    func plainMenuBar() {
        #expect(MenuBarGeometry.resolve(visibleTop: 24, safeAreaTop: 0)
                == MenuBarGeometry(height: 24, hasNotch: false))
    }

    @Test("notch: the taller of visible inset and safe area")
    func notchedMenuBar() {
        #expect(MenuBarGeometry.resolve(visibleTop: 37, safeAreaTop: 38)
                == MenuBarGeometry(height: 38, hasNotch: true))
        #expect(MenuBarGeometry.resolve(visibleTop: 39, safeAreaTop: 38)
                == MenuBarGeometry(height: 39, hasNotch: true))
    }

    @Test("auto-hide or no menu bar on this screen: height 0")
    func noPermanentMenuBar() {
        #expect(MenuBarGeometry.resolve(visibleTop: 0, safeAreaTop: 0).height == 0)
        // Auto-hide on a notched display: still flagged, but no band.
        let hidden = MenuBarGeometry.resolve(visibleTop: 0, safeAreaTop: 38)
        #expect(hidden.height == 0)
        #expect(hidden.hasNotch)
        // Sub-point rounding noise is not a menu bar.
        #expect(MenuBarGeometry.resolve(visibleTop: 0.5, safeAreaTop: 0).height == 0)
    }

    // MARK: Show rule

    private func shows(style: MenuBarBackgroundStyle = .black, height: Double = 24,
                       saver: Bool = false, preview: Bool = false, excluded: Bool = false,
                       fallback: Bool = false, mode: String = "default") -> Bool {
        MenuBarBackgroundRule.shouldShow(style: style, menuBarHeight: height,
                                         isScreenSaver: saver, isPreview: preview,
                                         saverExcluded: excluded, saverFallbackActive: fallback,
                                         presentationMode: mode)
    }

    @Test("desktop window with a menu bar shows every non-off style")
    func desktopShows() {
        #expect(shows(style: .white))
        #expect(shows(style: .black))
        #expect(shows(style: .videoColor))
        #expect(!shows(style: .off))
    }

    @Test("never on the saver, previews, the lock screen, or without a menu bar")
    func hiddenElsewhere() {
        #expect(!shows(height: 0))
        #expect(!shows(saver: true))
        #expect(!shows(preview: true))
        #expect(!shows(excluded: true))
        #expect(!shows(fallback: true))
        #expect(!shows(mode: "locked"))
        #expect(!shows(mode: "idle"))
    }

    // MARK: Readable colour

    @Test("mid tones are pushed to a decisive light or dark")
    func readableClamp() {
        let light = MenuBarBackgroundRule.readable(red: 0.6, green: 0.6, blue: 0.6)
        #expect(light.red >= 0.85 - 1e-9 && light.green >= 0.85 - 1e-9 && light.blue >= 0.85 - 1e-9)
        let dark = MenuBarBackgroundRule.readable(red: 0.5, green: 0.5, blue: 0.5)
        #expect(max(dark.red, dark.green, dark.blue) <= 0.30 + 1e-9)
    }

    @Test("hue survives the clamp")
    func readableKeepsHue() {
        let sky = MenuBarBackgroundRule.readable(red: 0.2, green: 0.4, blue: 0.7)
        #expect(sky.blue > sky.green && sky.green > sky.red)
        let sand = MenuBarBackgroundRule.readable(red: 0.9, green: 0.8, blue: 0.6)
        #expect(sand.red > sand.green && sand.green > sand.blue)
    }

    // MARK: Control file

    @Test("older control files decode with the band off")
    func missingKeys() throws {
        let decoded = try JSONDecoder().decode(WallpaperControlState.self, from: Data("{\"version\": 3}".utf8))
        #expect(decoded.menuBarBackgroundValue == .off)
        #expect(decoded.menuBarGeometry.isEmpty)
    }

    @Test("unknown style reads as off; fields round-trip")
    func roundTrip() throws {
        var state = WallpaperControlState()
        state.menuBarBackground = MenuBarBackgroundStyle.videoColor.rawValue
        state.menuBarGeometry = ["SCREEN": MenuBarGeometry(height: 38, hasNotch: true)]
        let decoded = try JSONDecoder().decode(WallpaperControlState.self, from: JSONEncoder().encode(state))
        #expect(decoded.menuBarBackgroundValue == .videoColor)
        #expect(decoded.menuBarGeometry["SCREEN"] == MenuBarGeometry(height: 38, hasNotch: true))

        state.menuBarBackground = "neon"
        #expect(state.menuBarBackgroundValue == .off)
    }
}

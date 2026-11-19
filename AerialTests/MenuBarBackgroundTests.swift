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

    // MARK: Blur styles

    @Test("blur strength: default when unset, clamped when out of range")
    func blurStrength() {
        #expect(MenuBarBackgroundRule.blurStrength(nil) == 0.7)
        #expect(MenuBarBackgroundRule.blurStrength(.nan) == 0.7)
        #expect(MenuBarBackgroundRule.blurStrength(0.6) == 0.6)
        #expect(MenuBarBackgroundRule.blurStrength(0.1) == 0.5)
        #expect(MenuBarBackgroundRule.blurStrength(1.0) == 0.9)
    }

    @Test("blur amount: default when unset, clamped, and a wider blur as it rises")
    func blurAmount() {
        #expect(MenuBarBackgroundRule.blurAmount(nil) == 0.5)
        #expect(MenuBarBackgroundRule.blurAmount(-1) == 0)
        #expect(MenuBarBackgroundRule.blurAmount(3) == 1)
        #expect(abs(MenuBarBackgroundRule.blurWidthFraction(amount: 0) - 0.005) < 1e-9)
        #expect(abs(MenuBarBackgroundRule.blurWidthFraction(amount: 1) - 0.05) < 1e-9)
        let mid = MenuBarBackgroundRule.blurWidthFraction(amount: 0.5)
        #expect(mid > 0.015 && mid < 0.017)
    }

    @Test("light blur never drops below the strength, dark never rises above its complement")
    func blurTintBounds() {
        for strength in [0.5, 0.7, 0.9] {
            let light = MenuBarBackgroundRule.blurTint(style: .lightBlur, strength: strength)
            #expect(abs(0 * light.scale + light.bias - strength) < 1e-9)      // black behind the bar
            #expect(abs(1 * light.scale + light.bias - 1) < 1e-9)             // white behind the bar
            let dark = MenuBarBackgroundRule.blurTint(style: .darkBlur, strength: strength)
            #expect(dark.bias == 0)
            #expect(abs(dark.scale - (1 - strength)) < 1e-9)
        }
    }

    private func source(band: CGRect, window: CGSize, layer: CGRect? = nil,
                        gravity: MenuBarBandGravity = .fill,
                        image: CGSize = CGSize(width: 3840, height: 2160)) -> CGRect? {
        MenuBarBackgroundRule.sourceRect(bandRect: band, windowSize: window,
                                         layerFrame: layer ?? CGRect(origin: .zero, size: window),
                                         gravity: gravity, imageSize: image)
    }

    private func close(_ a: CGRect?, _ b: CGRect) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
            && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    @Test("same aspect: exactly the strip behind the bar, full width")
    func sourceSameAspect() {
        let rect = source(band: CGRect(x: 0, y: 1056, width: 1920, height: 24),
                          window: CGSize(width: 1920, height: 1080))
        #expect(close(rect, CGRect(x: 0, y: 2112, width: 3840, height: 48)))
    }

    @Test("aspect fill on a taller display crops the sides")
    func sourceFillTaller() {
        // A 4160x2400 video fills a 1920x1200 window at 0.5: drawn 2080 pt
        // wide, 80 pt cropped off each side.
        let rect = source(band: CGRect(x: 0, y: 1176, width: 1920, height: 24),
                          window: CGSize(width: 1920, height: 1200),
                          image: CGSize(width: 4160, height: 2400))
        #expect(close(rect, CGRect(x: 160, y: 2352, width: 3840, height: 48)))
    }

    @Test("aspect fill on a wider display crops the top")
    func sourceFillWider() {
        // 2560x1080 window, 3840x2160 video: scale 2/3, drawn 1440 tall, 180 pt cropped top and bottom.
        let rect = source(band: CGRect(x: 0, y: 1056, width: 2560, height: 24),
                          window: CGSize(width: 2560, height: 1080))
        #expect(close(rect, CGRect(x: 0, y: (1056 + 180) * 1.5, width: 3840, height: 36)))
    }

    @Test("aspect fit: only the picture is sampled, nil when the band sits on a bar")
    func sourceFit() {
        // Pillarbox: 16:10 video in a 16:9 window, scale 1.08.
        let pillar = source(band: CGRect(x: 0, y: 1056, width: 1920, height: 24),
                            window: CGSize(width: 1920, height: 1080), gravity: .fit,
                            image: CGSize(width: 1600, height: 1000))
        #expect(close(pillar, CGRect(x: 0, y: 1056 / 1.08, width: 1600, height: 24 / 1.08)))
        // Letterbox: a 16:9 video in a 16:10 window leaves 60 pt bars; the
        // 24 pt band is all bar.
        #expect(source(band: CGRect(x: 0, y: 1176, width: 1920, height: 24),
                       window: CGSize(width: 1920, height: 1200), gravity: .fit) == nil)
    }

    @Test("stretch maps each axis on its own")
    func sourceStretch() {
        let rect = source(band: CGRect(x: 0, y: 1100, width: 1920, height: 100),
                          window: CGSize(width: 1920, height: 1200), gravity: .stretch)
        #expect(close(rect, CGRect(x: 0, y: 1980, width: 3840, height: 180)))
    }

    @Test("spanned: each window samples its own slice of the wide layer")
    func sourceSpanned() {
        // Two 1920x1080 displays side by side; this is the right one, so the
        // 3840x1080 layer starts at x = -1920. A 16:9 video fills by width
        // (scale 1), drawn 2160 tall and centred: 540 pt cropped at the top.
        let rect = source(band: CGRect(x: 0, y: 1056, width: 1920, height: 24),
                          window: CGSize(width: 1920, height: 1080),
                          layer: CGRect(x: -1920, y: 0, width: 3840, height: 1080))
        #expect(close(rect, CGRect(x: 1920, y: 1596, width: 1920, height: 24)))
    }

    @Test("no picture, no rect")
    func sourceDegenerate() {
        #expect(source(band: CGRect(x: 0, y: 1056, width: 1920, height: 24),
                       window: CGSize(width: 1920, height: 1080), image: .zero) == nil)
        #expect(source(band: CGRect(x: 0, y: 1056, width: 1920, height: 24),
                       window: CGSize(width: 1920, height: 1080),
                       layer: CGRect(x: 5000, y: 0, width: 1920, height: 1080)) == nil)
    }

    // MARK: Control file

    @Test("older control files decode with the band off")
    func missingKeys() throws {
        let decoded = try JSONDecoder().decode(WallpaperControlState.self, from: Data("{\"version\": 3}".utf8))
        #expect(decoded.menuBarBackgroundValue == .off)
        #expect(decoded.menuBarGeometry.isEmpty)
        #expect(decoded.menuBarBlurStrength == nil)
        #expect(decoded.menuBarBlurAmount == nil)
    }

    @Test("unknown style reads as off; fields round-trip")
    func roundTrip() throws {
        var state = WallpaperControlState()
        state.menuBarBackground = MenuBarBackgroundStyle.videoColor.rawValue
        state.menuBarGeometry = ["SCREEN": MenuBarGeometry(height: 38, hasNotch: true)]
        let decoded = try JSONDecoder().decode(WallpaperControlState.self, from: JSONEncoder().encode(state))
        #expect(decoded.menuBarBackgroundValue == .videoColor)
        #expect(decoded.menuBarGeometry["SCREEN"] == MenuBarGeometry(height: 38, hasNotch: true))

        state.menuBarBackground = MenuBarBackgroundStyle.lightBlur.rawValue
        state.menuBarBlurStrength = 0.6
        state.menuBarBlurAmount = 0.25
        let blurred = try JSONDecoder().decode(WallpaperControlState.self, from: JSONEncoder().encode(state))
        #expect(blurred.menuBarBackgroundValue == .lightBlur)
        #expect(blurred.menuBarBlurStrength == 0.6)
        #expect(blurred.menuBarBlurAmount == 0.25)

        state.menuBarBackground = "neon"
        #expect(state.menuBarBackgroundValue == .off)
    }
}

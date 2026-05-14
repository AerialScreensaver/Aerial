//
//  FirstLaunch.swift
//  Aerial Companion
//
//  Model layer for the first-launch setup wizard. Owns the "should we
//  show the wizard?" sentinel logic plus the two `apply` methods that
//  translate user choices into pref writes — keeping the SwiftUI views
//  free of pref-touching code so the audit point is one file.
//

import AppKit
import Foundation

enum FirstLaunch {

    // MARK: - Mode preset

    enum ModeChoice: String {
        /// App is only used to download videos and configure the
        /// extension. Desktop mode stays off, no auto-launch.
        case screensaverOnly
        /// Desktop mode runs alongside the screensaver, with auto-pause
        /// on. App auto-launches at login. Wallpaper continuity is an
        /// independent opt-in (the wizard's checkbox); when on, Aerial
        /// also replaces the System Settings wallpaper.
        case screensaverPlusDesktop

        var title: String {
            switch self {
            case .screensaverOnly: return "Screensaver only"
            case .screensaverPlusDesktop: return "Screensaver + wallpaper"
            }
        }

        var tagline: String {
            switch self {
            case .screensaverOnly:
                return "Use Aerial just for the screensaver. Manual launch."
            case .screensaverPlusDesktop:
                return "Slow-playing video as your wallpaper, paused when covered."
            }
        }

        var thumbnailSymbol: String {
            switch self {
            case .screensaverOnly: return "moon.zzz"
            case .screensaverPlusDesktop: return "macwindow.on.rectangle"
            }
        }

        /// Listicle shown next to the cards. Each line is rendered as a
        /// bullet — no leading bullet character here.
        var settingsBullets: [String] {
            switch self {
            case .screensaverOnly:
                return [
                    "Aerial *won't* start automatically with your Mac",
                    "System Settings wallpaper — unchanged",
                    "Desktop background mode — off (try it manually any time)",
                ]
            case .screensaverPlusDesktop:
                return [
                    "Aerial starts automatically at login",
                    "Slow-playing video as your wallpaper",
                    "Pauses automatically when other windows cover the screen",
                    "You can start and stop it at anytime",
                ]
            }
        }
    }

    // MARK: - Overlay preset

    enum OverlayPreset: String {
        case none
        case classic
        case modern

        var title: String {
            switch self {
            case .none:    return "No overlays"
            case .classic: return "Classic"
            case .modern:  return "Modern"
            }
        }

        var tagline: String {
            switch self {
            case .none:    return "Just the video, nothing on top."
            case .classic: return "Aerial 3 default look — clock and location, bold drop shadow."
            case .modern:  return "Lighter overlays with weather and time, top-corner placement."
            }
        }

        var thumbnailSymbol: String {
            switch self {
            case .none:    return "rectangle"
            case .classic: return "clock.fill"
            case .modern:  return "sparkles"
            }
        }
    }

    // MARK: - Detection

    /// Whether the wizard should be shown. The sentinel is
    /// `Preferences.firstLaunchCompleted`; the safety net here keeps
    /// existing Aerial 4 users (whose `companion.json` predates this
    /// pref) from getting a surprise wizard on upgrade — if the file
    /// is non-trivially sized, we silently mark them complete.
    static var shouldShowWizard: Bool {
        if Preferences.firstLaunchCompleted { return false }
        let path = "/Users/Shared/Aerial/companion.json"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 50 {
            Preferences.firstLaunchCompleted = true
            return false
        }
        return true
    }

    /// Best-guess pre-selection for the mode card based on current
    /// prefs — so users who arrive at the wizard with non-default
    /// settings (typically post-migration) see their existing choice
    /// pre-ticked. Wallpaper continuity (formerly its own mode) is
    /// now a sub-toggle of screensaverPlusDesktop, so existing
    /// `replaceWallpaper = true` users still land on the desktop card.
    static var initialModeChoice: ModeChoice {
        if Preferences.launchMode == .startup ||
            Preferences.restartBackground ||
            Preferences.replaceWallpaper {
            return .screensaverPlusDesktop
        }
        return .screensaverOnly
    }

    /// Initial state of the wallpaper-continuity checkbox. Mirrors
    /// the current `replaceWallpaper` pref when desktop mode is
    /// already active; otherwise defaults to ON so new users (and
    /// users opting into desktop for the first time) get the
    /// recommended pairing pre-ticked.
    static var initialWallpaperContinuity: Bool {
        if Preferences.launchMode == .startup || Preferences.restartBackground {
            return Preferences.replaceWallpaper
        }
        return true
    }

    // MARK: - Apply

    static func apply(mode: ModeChoice, wallpaperContinuity: Bool) {
        switch mode {
        case .screensaverOnly:
            Preferences.launchMode = .manual
            Preferences.restartBackground = false
            Preferences.replaceWallpaper = false
            Preferences.desktopAutoPause = true
        case .screensaverPlusDesktop:
            Preferences.launchMode = .startup
            Preferences.restartBackground = true
            Preferences.replaceWallpaper = wallpaperContinuity
            Preferences.desktopAutoPause = true
        }

        // Force 4K SDR 240FPS as the playback format regardless of the
        // chosen mode or migrated state. Migrating from an old Aerial
        // doesn't bring screensaver-side prefs over, but a re-run of
        // the wizard via Settings would otherwise leave any
        // user-changed value in place — this guarantees the wizard
        // always lands new users on the best-quality default.
        PrefsVideos.videoFormat = .v4KSDR240

        // Synchronize the LaunchAgent plist with the new launchMode so
        // the choice takes effect on the next login (or right now, if
        // we just flipped from manual → startup).
        LaunchAgent.update()

        // If the user just turned on wallpaper continuity, ask the
        // cache cleaner to (re)evaluate — on macOS 26 with the cleaner
        // sub-toggle at its default-true state, this fires the
        // NSOpenPanel asking for folder access. Wizard advances
        // immediately; the panel comes up on top.
        WallpaperCacheCleaner.shared.reevaluate()
    }

    static func apply(overlay: OverlayPreset, rotateForBurnIn: Bool) {
        let layout: OverlayLayout
        switch overlay {
        case .none:
            layout = .empty
        case .classic:
            layout = classicLayout()
        case .modern:
            layout = modernLayout()
        }
        // Replace the shared layout outright — first-launch is a clean
        // slate, no per-screen overrides yet.
        OverlayConfigManager.shared.setLayout(layout, for: nil, isDesktop: false)

        var config = OverlayConfigManager.shared.config
        config.rotationMode = rotateForBurnIn ? .everyMinute : .never
        OverlayConfigManager.shared.setConfig(config)
    }

    // MARK: - Preset layouts

    /// Aerial 3 default look: clock + location stacked bottom-left,
    /// solid white text with a strong drop shadow.
    private static func classicLayout() -> OverlayLayout {
        var stacks: [OverlayPosition: [OverlayInstance]] = [:]
        stacks[.bottomLeft] = [
            .defaultInstance(kind: .clock).at(.bottomLeft),
            .defaultInstance(kind: .location).at(.bottomLeft),
        ]
        return OverlayLayout(
            stacks: stacks,
            marginTop: 50, marginLeft: 50, marginBottom: 50, marginRight: 50,
            shadowRadius: 6, shadowOpacity: 1.0,
            shadowOffsetX: 0, shadowOffsetY: 3,
            shadowColorHex: "#000000",
            textColorHex: "#FFFFFF"
        )
    }

    /// Modern preset. Four-corner layout: weather top-left, a large
    /// translucent clock pushed slightly down from the top-center,
    /// music top-right, location bottom-left. Lighter shadows than
    /// Classic so the overlays read as floating UI rather than
    /// stamped text. Per-instance sizes and opacities are tuned to
    /// the same values the maintainer ships in their personal
    /// overlay config.
    private static func modernLayout() -> OverlayLayout {
        var stacks: [OverlayPosition: [OverlayInstance]] = [:]

        stacks[.topLeft] = [
            modernWeather().at(.topLeft),
        ]

        stacks[.topCenter] = [
            verticalSpacer(height: 80).at(.topCenter),
            modernClock().at(.topCenter),
        ]

        stacks[.topRight] = [
            modernMusic().at(.topRight),
        ]

        stacks[.bottomLeft] = [
            modernLocation().at(.bottomLeft),
        ]

        return OverlayLayout(
            stacks: stacks,
            marginTop: 50, marginLeft: 50, marginBottom: 50, marginRight: 50,
            shadowRadius: 3, shadowOpacity: 0.6,
            shadowOffsetX: 0, shadowOffsetY: 2,
            shadowColorHex: "#000000",
            textColorHex: "#FFFFFF"
        )
    }

    /// A `.verticalSpacer` overlay with a custom height. The default
    /// instance ships at height 50; bump it via the typeSettings dict
    /// the spacer reads at render time.
    private static func verticalSpacer(height: Int) -> OverlayInstance {
        var instance = OverlayInstance.defaultInstance(kind: .verticalSpacer)
        instance.typeSettings["height"] = .int(height)
        return instance
    }

    /// Headline clock for the Modern preset: huge, bold, translucent,
    /// no seconds, flashing separator. Sits near top-center to read
    /// as floating UI rather than stamped text.
    private static func modernClock() -> OverlayInstance {
        var instance = OverlayInstance.defaultInstance(kind: .clock)
        instance.fontSize = 180
        instance.fontWeight = "bold"
        instance.opacity = 0.6
        instance.typeSettings["showSeconds"] = .bool(false)
        instance.typeSettings["flashSeparator"] = .bool(true)
        return instance
    }

    /// Weather overlay for the Modern preset — bigger than the
    /// default (40 vs 20pt) so it carries the top-left corner, with
    /// a touch of translucency to soften it.
    private static func modernWeather() -> OverlayInstance {
        var instance = OverlayInstance.defaultInstance(kind: .weather)
        instance.fontSize = 40
        instance.opacity = 0.85
        return instance
    }

    /// Now-playing overlay for the Modern preset — sized to match
    /// the weather overlay opposite it.
    private static func modernMusic() -> OverlayInstance {
        var instance = OverlayInstance.defaultInstance(kind: .music)
        instance.fontSize = 40
        instance.opacity = 0.85
        return instance
    }

    /// Location overlay for the Modern preset — slightly larger than
    /// the default, more translucent, and fades after ten seconds so
    /// it doesn't sit there forever once the user has read it.
    private static func modernLocation() -> OverlayInstance {
        var instance = OverlayInstance.defaultInstance(kind: .location)
        instance.fontSize = 30
        instance.opacity = 0.75
        instance.typeSettings["time"] = .string("tenSeconds")
        return instance
    }
}

// MARK: - OverlayInstance position helper

private extension OverlayInstance {
    /// Returns a copy of this instance with `position` overridden. Used
    /// to seat `OverlayInstance.defaultInstance(kind:)` (which always
    /// places at `.bottomLeft`) into a different slot for the preset
    /// layouts above.
    func at(_ newPosition: OverlayPosition) -> OverlayInstance {
        var copy = self
        copy.position = newPosition
        return copy
    }
}

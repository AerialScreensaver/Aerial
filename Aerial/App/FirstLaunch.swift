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

    /// Pre-selection for the three-mode step / one-time upgrade
    /// prompt. Reflects an already-chosen mode on a re-run; otherwise the
    /// recommended `.animated` default.
    static var initialWallpaperMode: WallpaperMode {
        if Preferences.wallpaperModeChosen { return Preferences.wallpaperMode }
        return .animated
    }

    /// Pre-selection for the presentation step / upgrade-prompt page.
    /// Reflects an already-chosen presentation on a re-run; otherwise the
    /// menu bar — Aerial's historical shape, and no behaviour change for
    /// existing users unless they opt into the Dock.
    static var initialPresentation: AppPresentation {
        if Preferences.appPresentationChosen { return Preferences.appPresentation }
        return .menuBar
    }

    // MARK: - Apply

    /// Wallpaper-mode apply (the three-mode model). Maps the chosen mode onto the
    /// extension's live controls, sets Aerial4 as the system wallpaper/screensaver
    /// via `WallpaperControl`, and records the choice.
    static func apply(wallpaperMode: WallpaperMode) {
        Preferences.wallpaperMode = wallpaperMode

        switch wallpaperMode {
        case .off:
            // Screensaver only — set Aerial4 as the screensaver and leave the
            // user's current desktop wallpaper untouched. Don't auto-launch
            // Companion (matches the legacy screensaverOnly mapping) — the
            // screensaver runs from the extension regardless.
            WallpaperControl.enableAerialScreensaverOnly()
            Preferences.launchMode = .manual
        case .paused:
            // Static wallpaper — Aerial4 set as wallpaper + screensaver, paused.
            WallpaperControl.enableAerialWallpaperAndScreensaver()
            WallpaperControl.shared.setPaused(true)
            Preferences.launchMode = .startup
        case .animated:
            // Animated wallpaper + screensaver, auto-pausing when covered (default).
            // Auto-launch so the Companion-side controller (occlusion auto-pause,
            // speed, playlists) drives the extension.
            WallpaperControl.enableAerialWallpaperAndScreensaver()
            Preferences.desktopAutoPause = true
            WallpaperControl.shared.setPaused(false)
            Preferences.launchMode = .startup
        }

        // Land new users on the best-quality default (mirrors the legacy
        // apply(mode:) — migration doesn't carry screensaver-side prefs).
        PrefsVideos.videoFormat = .v4KSDR240

        // Mark the mode explicitly chosen so the wizard step / one-time
        // upgrade prompt doesn't reappear.
        Preferences.wallpaperModeChosen = true

        // Apply the launchMode just set above.
        LaunchAgent.update()
    }

    /// Presentation apply (menu bar / Dock). Delegates to the controller,
    /// which writes the pref + `appPresentationChosen` and reconciles the
    /// activation policy and status item live — during the wizard that
    /// means the Dock icon is already there when the Thank-you step says so.
    static func apply(presentation: AppPresentation) {
        AppPresentationController.shared.apply(presentation, reason: "wizard/prompt")
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

// MARK: - WallpaperMode presentation (three-mode cards)

/// Display metadata for the wallpaper modes. Kept here (next to the
/// other wizard presentation strings) rather than on the persisted
/// `WallpaperMode` enum in Preferences.swift.
extension WallpaperMode {
    var title: String {
        switch self {
        case .off:      return "No wallpaper"
        case .paused:   return "Still wallpaper"
        case .animated: return "Live wallpaper"
        }
    }

    var tagline: String {
        switch self {
        case .off:      return "Just the screensaver — your wallpaper is left alone."
        case .paused:   return "A frozen frame as your wallpaper, like Apple's paused video wallpapers."
        case .animated: return "An animated wallpaper that pauses when windows cover it."
        }
    }

    var thumbnailSymbol: String {
        switch self {
        case .off:      return "moon.zzz"
        case .paused:   return "photo"
        case .animated: return "menubar.dock.rectangle"
        }
    }

    /// Listicle shown next to the cards. Markdown is honored (rendered
    /// via `Text(.init(line))`), so `**Aerial 4**` bolds.
    var settingsBullets: [String] {
        switch self {
        case .off:
            return [
                "Aerial runs as your screensaver",
                "Your System Settings wallpaper is left untouched",
                "Turn a live wallpaper on any time from Aerial",
            ]
        case .paused:
            return [
                "Aerial runs as your screensaver",
                "A single still frame as your wallpaper — no motion",
                "Choose **Aerial 4** in System Settings → Wallpaper to enable it",
                "Tap play in Aerial to bring it to life",
            ]
        case .animated:
            return [
                "Aerial runs as your screensaver",
                "An animated video wallpaper behind your windows",
                "Choose **Aerial 4** in System Settings → Wallpaper to enable it",
                "Pauses automatically when covered, to save power",
            ]
        }
    }
}

// MARK: - AppPresentation presentation (menu bar / Dock cards)

/// Display metadata for the two presentations. Same split as
/// `WallpaperMode` above: persisted enum in Preferences.swift, wizard
/// strings here.
extension AppPresentation {
    var title: String {
        switch self {
        case .menuBar: return "Menu bar"
        case .dock:    return "Dock"
        }
    }

    var tagline: String {
        switch self {
        case .menuBar: return "A compact popover next to the clock. Aerial stays out of your Dock."
        case .dock:    return "A regular app in the Dock — the Video Library is its main window."
        }
    }

    var thumbnailSymbol: String {
        switch self {
        case .menuBar: return "menubar.rectangle"
        case .dock:    return "dock.rectangle"
        }
    }

    /// Listicle shown next to the cards. Markdown is honored.
    var settingsBullets: [String] {
        switch self {
        case .menuBar:
            return [
                "Aerial's icon sits in the menu bar — click it for playback controls",
                "No Dock icon and no window until you open one",
                "Settings and the Video Library open from the popover",
            ]
        case .dock:
            return [
                "Aerial's icon sits in the Dock — click it to open the Video Library",
                "Home shows what's playing on every display, with playback controls",
                "A regular menu bar with a **Playback** menu and keyboard shortcuts",
                "Closing the window keeps Aerial running in the background",
            ]
        }
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

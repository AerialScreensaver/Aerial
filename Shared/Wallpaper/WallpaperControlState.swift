//
//  WallpaperControlState.swift
//  Shared between Companion app and Aerial4WallpaperExtension.
//
//  Serialized to `/Users/Shared/Aerial/wallpaper-control.json` by the
//  Companion app whenever the user changes speed, skips, or rotates
//  the playlist for a screen. The wallpaper extension subscribes to a
//  Darwin notification (com.glouel.aerial.wallpaper-control), re-reads
//  this file, and reconciles deltas against its in-memory last-applied
//  copy. Counters give "do this now" semantics without a command queue.
//

import Foundation

/// Transition style the wallpaper extension plays at a video change
/// (natural rotation and manual skips). Stored in the control file as
/// the raw string so an older extension reading a newer style falls
/// back gracefully (see `WallpaperControlState.transitionStyleValue`).
enum WallpaperTransitionStyle: String, Codable, CaseIterable, Sendable {
    /// Hard cut — the pre-transitions behavior.
    case none
    /// The outgoing frame dissolves into the incoming video.
    case crossfade
    /// Fade to black over the outgoing frame, then reveal the incoming.
    case dipToBlack
    /// Crossfade with a gentle scale drift on the outgoing frame.
    case zoomFade
}

/// Per-screen sub-state. All fields are monotonic counters or
/// generation numbers — the extension acts on the *change*, not the
/// absolute value.
struct WallpaperScreenControl: Codable, Equatable {
    /// Bumped by Companion when the user clicks "next video" on this
    /// screen. Extension acts (immediate swap-to-next) on increment.
    var advanceCounter: Int = 0

    /// Bumped by Companion when the user clicks "previous video".
    var regressCounter: Int = 0

    /// Bumped by Companion whenever PlaylistManager rewrites
    /// playlists.json for this screen. Extension reloads its
    /// in-memory playlist cache and forces an advance to the new
    /// playlist's current entry.
    var playlistGeneration: Int = 0

    /// Auto-pause (window coverage) signal from Companion's occlusion
    /// coordinator. Distinct from the global user `paused` flag: the
    /// extension defers it while the saver runs, and clearing it never
    /// overrides an explicit user pause.
    var autoPaused: Bool = false

    /// Monotonic token bumped by Companion to request an immediate jump
    /// to `jumpIndex` in this screen's playlist (the dashboard/popover
    /// playlist click). A token (not just an index) so re-jumping to the
    /// same index still fires.
    var jumpToken: Int = 0

    /// Target playlist index for the most recent `jumpToken` bump.
    var jumpIndex: Int = 0
}

/// Root state shared between Companion and the wallpaper extension.
struct WallpaperControlState: Codable, Equatable {
    /// Monotonic version number, bumped on every Companion write.
    /// Lets the extension skip stale state if it reads a half-written
    /// file (it won't because we write atomically, but defence in
    /// depth) or replays the same notification.
    var version: Int = 0

    /// Global playback rate (1.0 = native source rate; 0.125 = the
    /// cinematic Aerial default). Applied to all renderers across all
    /// screens.
    var speed: Double = 0.125

    /// Global pause flag. When true, every renderer is paused (deep
    /// pause — timebase rate 0, readers cancelled after a short delay).
    /// Resume restores the configured `speed`. Pause is global rather
    /// than per-screen on purpose: the temp UI exposes one button and
    /// the screensaver behaves the same way (pause is system-wide).
    var paused: Bool = false

    /// Battery-pause flag, set by Companion's battery monitor when the
    /// "pause on battery" rule fires. Kept SEPARATE from the user's
    /// `paused` (static/animated) intent so battery-resume never
    /// un-pauses a user who deliberately chose a still wallpaper. The
    /// extension treats the effective global pause as `paused ||
    /// batteryPaused`.
    var batteryPaused: Bool = false

    /// Thermal/Low Power Mode pause flag, set by Companion's thermal
    /// monitor when thermal pressure reaches `.serious` (and the pref is
    /// on) or macOS Low Power Mode is enabled (and that pref is on).
    /// Separate from `paused`/`batteryPaused` for the same reason those
    /// are separate: clearing one source must never un-pause another.
    var thermalPaused: Bool = false

    /// Camera-in-use pause flag, set by Companion's camera monitor while
    /// any camera device is running (and the pref is on) — covers
    /// videoconferences without window-coverage tuning. Same separation
    /// rationale as the other flags.
    var cameraPaused: Bool = false

    /// Per-screenUUID state — keyed by the CFUUIDCreateString form of
    /// the screen's CGDisplayCreateUUIDFromDisplayID output (matches
    /// what the playlist code keys by).
    var screens: [String: WallpaperScreenControl] = [:]

    /// Bumped by Companion whenever displays-related settings change
    /// (viewing mode, display mode, aspect, margins). The extension
    /// re-reads screensaver.json and reconfigures every active
    /// wallpaper in place — its process outlives settings changes by
    /// days, and WallpaperAgent never re-acquires on our behalf.
    var settingsGeneration: Int = 0

    /// Bumped by Companion whenever overlay-config.json is rewritten
    /// (separate-desktop toggle, any overlay-editor save). The
    /// extension re-reads the config and rebuilds its overlay drivers.
    var overlayGeneration: Int = 0

    /// Transition style between videos, as a raw string (see
    /// `WallpaperTransitionStyle`). Raw so a newer Companion can write
    /// styles an older extension doesn't know — it falls back to
    /// `.zoomFade` via `transitionStyleValue`.
    var transitionStyle: String = WallpaperTransitionStyle.zoomFade.rawValue

    /// Natural-boundary transition duration in wall-clock seconds.
    /// Manual skips and fast-rate (saver) boundaries derive shorter
    /// values in the extension; this is the one user knob.
    var transitionDuration: Double = 2.0

    /// Typed accessor for `transitionStyle` with the forward-compat
    /// fallback baked in.
    var transitionStyleValue: WallpaperTransitionStyle {
        WallpaperTransitionStyle(rawValue: transitionStyle) ?? .zoomFade
    }

    /// Per-screen dock/menubar insets relayed by Companion, keyed by
    /// screen UUID → [top, leading, bottom, trailing] in points. The
    /// extension can't measure these live: an appex has no NSApplication
    /// run loop, so its NSScreen.visibleFrame is frozen at first access.
    /// Companion re-measures on every screen-parameter change and
    /// publishes here.
    var dockInsets: [String: [Double]] = [:]

    /// Bumped by Companion when the NSScreen layout (display ids +
    /// frames) changed on a screen-parameter event — a monitor added,
    /// removed, or rearranged. The extension re-detects displays and
    /// re-slices spanned windows. Separate from `dockInsets`: a
    /// rearrangement can leave every inset identical.
    var screenLayoutGeneration: Int = 0

    /// Play the video's own audio track. Audio only actually sounds
    /// while the effective playback rate is 1.0 (screensaver, or
    /// wallpaper at 100% speed) and never on the lock screen; exactly
    /// one renderer owns audio (broadcast, or the main display's in
    /// independent mode).
    var audioEnabled: Bool = false

    /// Audio volume, 0...1. Applied live to the owning renderer.
    var audioVolume: Double = 0.5

    /// True while Aerial is the system desktop wallpaper (Companion reads
    /// the wallpaper store). False = screensaver-only: the extension is
    /// hosted only for the saver, so the desktop-side pause flags
    /// (`paused`, per-screen `autoPaused`) have nothing to act on and are
    /// ignored, and every non-preview `idle` acquire IS the screensaver.
    /// Defaults to true so a control file from an older Companion keeps
    /// the historical behaviour until the new one writes the field.
    var desktopWallpaperActive: Bool = true

    static let fileURL: URL = URL(
        fileURLWithPath: "/Users/Shared/Aerial/wallpaper-control.json"
    )

    /// Name of the Darwin notification posted by Companion after every
    /// write to the file. Extensions register for this and re-read on
    /// wake.
    static let darwinNotificationName = "com.glouel.aerial.wallpaper-control"
}

// Tolerant decoding: fields added over time (settingsGeneration,
// overlayGeneration, …) default to 0 when reading a file written by an
// older build. Without this, the first post-update read would throw,
// reset the state to version 0, and the extension's higher last-applied
// version would then ignore commands until the count caught back up.
extension WallpaperScreenControl {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        advanceCounter = try c.decodeIfPresent(Int.self, forKey: .advanceCounter) ?? 0
        regressCounter = try c.decodeIfPresent(Int.self, forKey: .regressCounter) ?? 0
        playlistGeneration = try c.decodeIfPresent(Int.self, forKey: .playlistGeneration) ?? 0
        autoPaused = try c.decodeIfPresent(Bool.self, forKey: .autoPaused) ?? false
        jumpToken = try c.decodeIfPresent(Int.self, forKey: .jumpToken) ?? 0
        jumpIndex = try c.decodeIfPresent(Int.self, forKey: .jumpIndex) ?? 0
    }
}

extension WallpaperControlState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 0.125
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        batteryPaused = try c.decodeIfPresent(Bool.self, forKey: .batteryPaused) ?? false
        thermalPaused = try c.decodeIfPresent(Bool.self, forKey: .thermalPaused) ?? false
        cameraPaused = try c.decodeIfPresent(Bool.self, forKey: .cameraPaused) ?? false
        screens = try c.decodeIfPresent([String: WallpaperScreenControl].self, forKey: .screens) ?? [:]
        settingsGeneration = try c.decodeIfPresent(Int.self, forKey: .settingsGeneration) ?? 0
        overlayGeneration = try c.decodeIfPresent(Int.self, forKey: .overlayGeneration) ?? 0
        transitionStyle = try c.decodeIfPresent(String.self, forKey: .transitionStyle)
            ?? WallpaperTransitionStyle.zoomFade.rawValue
        transitionDuration = try c.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? 2.0
        dockInsets = try c.decodeIfPresent([String: [Double]].self, forKey: .dockInsets) ?? [:]
        screenLayoutGeneration = try c.decodeIfPresent(Int.self, forKey: .screenLayoutGeneration) ?? 0
        audioEnabled = try c.decodeIfPresent(Bool.self, forKey: .audioEnabled) ?? false
        audioVolume = try c.decodeIfPresent(Double.self, forKey: .audioVolume) ?? 0.5
        desktopWallpaperActive = try c.decodeIfPresent(Bool.self, forKey: .desktopWallpaperActive) ?? true
    }
}

extension WallpaperControlState {
    /// The user/coverage pause inputs a renderer should honour. Both are
    /// desktop concerns: when Aerial isn't the desktop wallpaper there is
    /// nothing for them to act on, and letting them through seeded a
    /// screensaver session paused on its first frame (2026-09-17). The
    /// broadcast renderer (cloned/spanned) is covered while ANY screen is.
    func effectivePauseInputs(rendererKey: String, isBroadcast: Bool) -> (user: Bool, coverage: Bool) {
        guard desktopWallpaperActive else { return (false, false) }
        let covered = isBroadcast
            ? screens.values.contains { $0.autoPaused }
            : (screens[rendererKey]?.autoPaused ?? false)
        return (paused, covered)
    }
}

/// How the extension classifies a fresh acquire. Pure so it can be
/// unit-tested against the profiles seen in the field:
///  - the screensaver arrives as `presentationMode == "idle"`; macOS only
///    presents idle while a saver is up, so `saverRunning` is true for
///    every non-preview idle acquire (drives the process-wide saver flag);
///  - `isSaverRole` (subscriber accounting, overlay layout, status) is the
///    stricter call: when Aerial is not the desktop wallpaper every idle
///    acquire is the saver window; when it is, an idle acquire may also be
///    the desktop window re-acquired mid-saver, and only the absence of a
///    picker placement tells them apart (the desktop choice carries
///    `placement=Crop/Fill`; a screensaver choice usually doesn't, but a
///    System Settings–written store can put one there too — the 2026-09-17
///    frozen-first-start report);
///  - System Settings previews (`preview=true`) are never the saver.
enum SaverAcquireRule {
    struct Verdict: Equatable {
        let isSaverRole: Bool
        let saverRunning: Bool
    }

    static func classify(presentationMode: String, isPreview: Bool, placement: String?,
                         desktopWallpaperActive: Bool) -> Verdict {
        guard presentationMode == "idle", !isPreview else {
            return Verdict(isSaverRole: false, saverRunning: false)
        }
        return Verdict(isSaverRole: placement == nil || !desktopWallpaperActive, saverRunning: true)
    }

    /// "Don't resume video at launch": gated on the desktop wallpaper being
    /// INACTIVE, not on the role. With Aerial also the wallpaper, the saver
    /// window subscribes to the desktop's renderer and skipping there would
    /// cut the desktop's video at every saver engage (the role verdict is
    /// true for a bare idle acquire in that setup too). `saverRunning`
    /// already excludes previews and non-idle acquires.
    static func advancesAtLaunch(_ verdict: Verdict, desktopWallpaperActive: Bool, optionEnabled: Bool) -> Bool {
        optionEnabled && verdict.saverRunning && !desktopWallpaperActive
    }
}

//
//  CompanionSettings.swift
//  Aerial Companion
//

import Foundation

/// Consolidated settings structure for Aerial Companion app
/// Replaces individual UserDefaults entries with a single JSON file at /Users/Shared/Aerial/companion.json
struct CompanionSettings: Codable {

    // MARK: - Launch Settings

    /// Launch mode (manual, startup, or background)
    var intLaunchMode: Int

    // MARK: - Debug Settings

    /// Debug mode enabled
    var debugMode: Bool

    /// First time setup completed
    var firstTimeSetup: Bool

    // MARK: - Wallpaper Settings

    /// The user's chosen wallpaper mode on macOS Sonoma+ (off / paused /
    /// animated — see `WallpaperMode`). Stored as the raw Int. Optional
    /// so old `companion.json` files decode cleanly; `Preferences.
    /// wallpaperMode` maps a nil to `.animated` (the recommended default).
    var intWallpaperMode: Int?

    // MARK: - Performance Settings

    /// Global playback speed (0-100)
    var globalSpeed: Int

    // MARK: - UI Settings

    /// Show playlist in list mode (true) or strip mode (false)
    var playlistListMode: Bool

    /// Shuffle playlist on wrap-around (true) or replay same order (false).
    /// Legacy — superseded by `playlistCycleMode`; kept so old files decode
    /// and the migration can derive the new value from it.
    var playlistShuffle: Bool

    /// Playlist cycle mode (PlaylistCycleMode raw value: 0 = loop,
    /// 1 = shuffle, 2 = repeat one). Replaces `playlistShuffle`.
    var playlistCycleMode: Int

    // MARK: - Desktop Behavior Settings

    /// Auto-pause desktop mode when windows occlude the screen
    var desktopAutoPause: Bool

    /// Coverage threshold (0.0–1.0) at which to auto-pause
    var desktopAutoPauseThreshold: Double

    /// Apps whose windows are excluded from the occlusion coverage
    /// calculation (language tools, window managers that keep large
    /// transparent windows on screen). Bundle identifiers, falling back
    /// to the CGWindowList owner name for processes without one.
    var desktopAutoPauseIgnoredApps: [String]

    /// Sub-option of wallpaper continuity. When on (default), Aerial
    /// prunes macOS's wallpaper-agent cache to keep it under 2 GB —
    /// macOS 26 doesn't clean this cache automatically and it can
    /// balloon to many GB when continuity is on. Requires user
    /// approval (security-scoped folder access) before the cleaner
    /// can actually delete anything.
    var cleanWallpaperCache: Bool

    /// Security-scoped bookmark to the wallpaper-agent container
    /// folder, granting the cleaner read/delete access. Base64-encoded
    /// in JSON. `nil` until the user approves the NSOpenPanel; cleared
    /// if the bookmark goes stale at resolve time.
    var wallpaperCacheBookmark: Data?

    /// Optional, opt-in: when on, delete macOS's own downloaded wallpaper
    /// aerial videos (~/Library/Application Support/com.apple.wallpaper/
    /// aerials/videos) at launch to reclaim disk space. Default off.
    var reclaimMacOSWallpaperVideosAtStartup: Bool

    // MARK: - Accessibility Settings

    /// Use a solid (opaque) popover background instead of the default translucent vibrancy
    var popoverSolidBackground: Bool

    /// Invert video playback colors for accessibility
    var invertColors: Bool

    /// Master switch for system-wide hotkeys (toggle pause / next /
    /// previous video). Default `false` — when on, the per-action
    /// bindings stored by `KeyboardShortcuts` are activated.
    var globalShortcutsEnabled: Bool

    // MARK: - UI Discovery Flags

    /// IDs of orange "New" pills the user has already dismissed by
    /// engaging with the corresponding sidebar section. Adding a new
    /// badge is just a matter of picking a fresh string ID and reading
    /// it via `Preferences.isNewBadgeDismissed(_:)`.
    var dismissedNewBadges: [String]

    /// True once the user has completed (or dismissed) the first-launch
    /// setup wizard. Optional so old `companion.json` files predating
    /// this field decode cleanly. The wizard runs while this is `false`
    /// or `nil` — see `FirstLaunch.shouldShowWizard`.
    var firstLaunchCompleted: Bool?

    /// True once the user has explicitly picked a wallpaper mode (the
    /// first-launch wizard's mode step or the one-time 4.1 upgrade
    /// prompt). Independent of `firstLaunchCompleted` so existing users
    /// — already marked wizard-complete — still get the mode prompt
    /// exactly once. Optional for back-compat decode.
    var wallpaperModeChosen: Bool?

    /// The app version string (`CFBundleShortVersionString`) seen at the
    /// previous launch. Used to detect upgrades (e.g. the first launch
    /// on 4.1) so we can show the one-time wallpaper-mode prompt.
    /// Optional for back-compat decode.
    var lastLaunchedVersion: String?

    // MARK: - App Presentation

    /// Where the app lives: menu bar (0, the default) or Dock (1) — see
    /// `AppPresentation`. Stored as the raw Int; optional so files
    /// predating the field decode cleanly (`Preferences.appPresentation`
    /// maps nil → `.menuBar`).
    var intAppPresentation: Int?

    /// True once the user explicitly picked a presentation (wizard step
    /// or the one-time upgrade prompt). Optional for back-compat decode.
    var appPresentationChosen: Bool?

    /// True when the first-launch wizard found Aerial 3 data it could not
    /// read (Full Disk Access) and the user skipped: the upgrade prompt
    /// offers the migration again once the data is readable. Cleared by a
    /// completed migration. Optional for back-compat decode.
    var legacyMigrationPending: Bool?

    /// Dock presentation: true once the one-time quit explanation has
    /// been shown and suppressed. Optional for back-compat decode.
    var dockQuitExplained: Bool?

    /// Dock presentation: badge the Dock icon with the number of videos
    /// left to download. Default ON (nil → true); Settings → Cache →
    /// Downloads. Optional for back-compat decode.
    var dockDownloadBadge: Bool?

    /// `WallpaperExtensionIdentity.description` of the bundled appex for
    /// which Companion already restarted WallpaperAgent (stale-extension
    /// check, once per installed build). Optional for back-compat decode.
    var agentRestartedForIdentity: String?

    // MARK: - Now Playing Settings

    /// Reverse-DNS identifiers of `NowPlayingSource` implementations
    /// the user has enabled. Empty array = all known sources enabled
    /// (default for fresh installs and the implicit behavior until the
    /// user touches the inspector's per-player checkboxes). The
    /// coordinator restarts itself when this changes.
    var enabledNowPlayingSources: [String]

    // MARK: - Battery-aware pause

    /// Auto-pause desktop wallpaper and fullscreen-window playback when
    /// the system is on battery (or low battery, per `desktopPauseOnBatteryMode`).
    /// Default off — opt-in for users who want to preserve battery life.
    var desktopPauseOnBattery: Bool

    /// `"anyBattery"`: pause whenever AC is unplugged.
    /// `"lowBattery"`: pause only when on battery AND remaining capacity is below 20%.
    var desktopPauseOnBatteryMode: String

    // MARK: - Thermal / Low Power Mode pause

    /// Pause the wallpaper while thermal pressure is `.serious` or
    /// `.critical`. Default ON — protective, rare, and what users want
    /// when the machine is already cooking.
    var desktopPauseOnThermal: Bool

    /// Pause the wallpaper while macOS Low Power Mode is enabled.
    /// Default off — opt-in, consistent with `desktopPauseOnBattery`.
    var desktopPauseOnLowPower: Bool

    /// Pause the wallpaper while any camera is in use (videoconference
    /// case). Default off — opt-in.
    var desktopPauseOnCamera: Bool

    /// Auto-advance the playlist on all screens at a fixed cadence
    /// (equivalent of pressing next), so paused/auto-paused wallpapers
    /// don't show the same frame forever. Default off — opt-in.
    var desktopAutoAdvance: Bool

    /// Auto-advance cadence in minutes (15…1440). Only meaningful when
    /// `desktopAutoAdvance` is on.
    var desktopAutoAdvanceMinutes: Int

    /// Show a "Restart Wallpaper Agent" button in the menu bar popover
    /// (bottom row) and on the Home dashboard's Wallpaper card, in
    /// addition to Settings → Wallpaper → Troubleshooting. Default off.
    var showRestartWallpaperButton: Bool

    // MARK: - Defaults

    /// Default settings for fresh install
    static let `default` = CompanionSettings(
        intLaunchMode: LaunchMode.manual.rawValue,
        debugMode: false,
        firstTimeSetup: false,
        globalSpeed: 0,
        playlistListMode: true,
        playlistShuffle: false,
        playlistCycleMode: 0,
        desktopAutoPause: true,
        desktopAutoPauseThreshold: 0.6,
        desktopAutoPauseIgnoredApps: [],
        cleanWallpaperCache: true,
        wallpaperCacheBookmark: nil,
        reclaimMacOSWallpaperVideosAtStartup: false,
        popoverSolidBackground: false,
        invertColors: false,
        globalShortcutsEnabled: false,
        dismissedNewBadges: [],
        firstLaunchCompleted: nil,
        enabledNowPlayingSources: [],
        desktopPauseOnBattery: false,
        desktopPauseOnBatteryMode: "anyBattery",
        intWallpaperMode: nil,
        wallpaperModeChosen: nil,
        lastLaunchedVersion: nil,
        intAppPresentation: nil,
        appPresentationChosen: nil,
        legacyMigrationPending: nil,
        dockQuitExplained: nil,
        dockDownloadBadge: nil,
        agentRestartedForIdentity: nil
    )

    // MARK: - File Location

    /// URL for the companion settings JSON file
    static var fileURL: URL {
        let baseURL = URL(fileURLWithPath: AerialPaths.baseDirectory)
        return baseURL.appendingPathComponent("companion.json")
    }

    // MARK: - Migration

    /// Create CompanionSettings from current UserDefaults values
    /// Used during migration from plist to JSON
    static func fromUserDefaults() -> CompanionSettings {
        return CompanionSettings(
            intLaunchMode: UserDefaults.standard.object(forKey: "intLaunchMode") as? Int ?? LaunchMode.manual.rawValue,
            debugMode: UserDefaults.standard.object(forKey: "debugMode") as? Bool ?? false,
            firstTimeSetup: UserDefaults.standard.object(forKey: "firstTimeSetup") as? Bool ?? false,
            globalSpeed: UserDefaults.standard.object(forKey: "globalSpeed") as? Int ?? 0,
            playlistListMode: true,
            playlistShuffle: false,
            desktopAutoPause: true,
            desktopAutoPauseThreshold: 0.6
        )
    }

    // MARK: - Memberwise Init

    init(intLaunchMode: Int, debugMode: Bool, firstTimeSetup: Bool,
         globalSpeed: Int, playlistListMode: Bool,
         playlistShuffle: Bool, playlistCycleMode: Int = 0,
         desktopAutoPause: Bool = true,
         desktopAutoPauseThreshold: Double = 0.6,
         desktopAutoPauseIgnoredApps: [String] = [],
         cleanWallpaperCache: Bool = true,
         wallpaperCacheBookmark: Data? = nil,
         reclaimMacOSWallpaperVideosAtStartup: Bool = false,
         popoverSolidBackground: Bool = false,
         invertColors: Bool = false,
         globalShortcutsEnabled: Bool = false,
         dismissedNewBadges: [String] = [],
         firstLaunchCompleted: Bool? = nil,
         enabledNowPlayingSources: [String] = [],
         desktopPauseOnBattery: Bool = false,
         desktopPauseOnBatteryMode: String = "anyBattery",
         desktopPauseOnThermal: Bool = true,
         desktopPauseOnLowPower: Bool = false,
         desktopPauseOnCamera: Bool = false,
         desktopAutoAdvance: Bool = false,
         desktopAutoAdvanceMinutes: Int = 60,
         showRestartWallpaperButton: Bool = false,
         intWallpaperMode: Int? = nil,
         wallpaperModeChosen: Bool? = nil,
         lastLaunchedVersion: String? = nil,
         intAppPresentation: Int? = nil,
         appPresentationChosen: Bool? = nil,
         legacyMigrationPending: Bool? = nil,
         dockQuitExplained: Bool? = nil,
         dockDownloadBadge: Bool? = nil,
         agentRestartedForIdentity: String? = nil) {
        self.intLaunchMode = intLaunchMode
        self.debugMode = debugMode
        self.firstTimeSetup = firstTimeSetup
        self.globalSpeed = globalSpeed
        self.playlistListMode = playlistListMode
        self.playlistShuffle = playlistShuffle
        self.playlistCycleMode = playlistCycleMode
        self.desktopAutoPause = desktopAutoPause
        self.desktopAutoPauseThreshold = desktopAutoPauseThreshold
        self.desktopAutoPauseIgnoredApps = desktopAutoPauseIgnoredApps
        self.cleanWallpaperCache = cleanWallpaperCache
        self.wallpaperCacheBookmark = wallpaperCacheBookmark
        self.reclaimMacOSWallpaperVideosAtStartup = reclaimMacOSWallpaperVideosAtStartup
        self.popoverSolidBackground = popoverSolidBackground
        self.invertColors = invertColors
        self.globalShortcutsEnabled = globalShortcutsEnabled
        self.dismissedNewBadges = dismissedNewBadges
        self.firstLaunchCompleted = firstLaunchCompleted
        self.enabledNowPlayingSources = enabledNowPlayingSources
        self.desktopPauseOnBattery = desktopPauseOnBattery
        self.desktopPauseOnBatteryMode = desktopPauseOnBatteryMode
        self.desktopPauseOnThermal = desktopPauseOnThermal
        self.desktopPauseOnLowPower = desktopPauseOnLowPower
        self.desktopPauseOnCamera = desktopPauseOnCamera
        self.desktopAutoAdvance = desktopAutoAdvance
        self.desktopAutoAdvanceMinutes = desktopAutoAdvanceMinutes
        self.showRestartWallpaperButton = showRestartWallpaperButton
        self.intWallpaperMode = intWallpaperMode
        self.wallpaperModeChosen = wallpaperModeChosen
        self.lastLaunchedVersion = lastLaunchedVersion
        self.intAppPresentation = intAppPresentation
        self.appPresentationChosen = appPresentationChosen
        self.legacyMigrationPending = legacyMigrationPending
        self.dockQuitExplained = dockQuitExplained
        self.dockDownloadBadge = dockDownloadBadge
        self.agentRestartedForIdentity = agentRestartedForIdentity
    }

    // MARK: - Backward-Compatible Decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intLaunchMode = try container.decode(Int.self, forKey: .intLaunchMode)
        debugMode = try container.decode(Bool.self, forKey: .debugMode)
        firstTimeSetup = try container.decode(Bool.self, forKey: .firstTimeSetup)
        globalSpeed = try container.decode(Int.self, forKey: .globalSpeed)
        playlistListMode = try container.decodeIfPresent(Bool.self, forKey: .playlistListMode) ?? false
        playlistShuffle = try container.decodeIfPresent(Bool.self, forKey: .playlistShuffle) ?? false
        // Migration: files predating the tri-state mode derive it from the
        // legacy shuffle Bool.
        playlistCycleMode = try container.decodeIfPresent(Int.self, forKey: .playlistCycleMode) ?? (playlistShuffle ? 1 : 0)
        desktopAutoPause = try container.decodeIfPresent(Bool.self, forKey: .desktopAutoPause) ?? true
        desktopAutoPauseThreshold = try container.decodeIfPresent(Double.self, forKey: .desktopAutoPauseThreshold) ?? 0.6
        desktopAutoPauseIgnoredApps = try container.decodeIfPresent([String].self, forKey: .desktopAutoPauseIgnoredApps) ?? []
        cleanWallpaperCache = try container.decodeIfPresent(Bool.self, forKey: .cleanWallpaperCache) ?? true
        wallpaperCacheBookmark = try container.decodeIfPresent(Data.self, forKey: .wallpaperCacheBookmark)
        reclaimMacOSWallpaperVideosAtStartup = try container.decodeIfPresent(Bool.self, forKey: .reclaimMacOSWallpaperVideosAtStartup) ?? false
        popoverSolidBackground = try container.decodeIfPresent(Bool.self, forKey: .popoverSolidBackground) ?? false
        invertColors = try container.decodeIfPresent(Bool.self, forKey: .invertColors) ?? false
        globalShortcutsEnabled = try container.decodeIfPresent(Bool.self, forKey: .globalShortcutsEnabled) ?? false
        dismissedNewBadges = try container.decodeIfPresent([String].self, forKey: .dismissedNewBadges) ?? []
        firstLaunchCompleted = try container.decodeIfPresent(Bool.self, forKey: .firstLaunchCompleted)
        enabledNowPlayingSources = try container.decodeIfPresent([String].self, forKey: .enabledNowPlayingSources) ?? []
        desktopPauseOnBattery = try container.decodeIfPresent(Bool.self, forKey: .desktopPauseOnBattery) ?? false
        desktopPauseOnBatteryMode = try container.decodeIfPresent(String.self, forKey: .desktopPauseOnBatteryMode) ?? "anyBattery"
        desktopPauseOnThermal = try container.decodeIfPresent(Bool.self, forKey: .desktopPauseOnThermal) ?? true
        desktopPauseOnLowPower = try container.decodeIfPresent(Bool.self, forKey: .desktopPauseOnLowPower) ?? false
        desktopPauseOnCamera = try container.decodeIfPresent(Bool.self, forKey: .desktopPauseOnCamera) ?? false
        desktopAutoAdvance = try container.decodeIfPresent(Bool.self, forKey: .desktopAutoAdvance) ?? false
        desktopAutoAdvanceMinutes = try container.decodeIfPresent(Int.self, forKey: .desktopAutoAdvanceMinutes) ?? 60
        showRestartWallpaperButton = try container.decodeIfPresent(Bool.self, forKey: .showRestartWallpaperButton) ?? false
        intWallpaperMode = try container.decodeIfPresent(Int.self, forKey: .intWallpaperMode)
        wallpaperModeChosen = try container.decodeIfPresent(Bool.self, forKey: .wallpaperModeChosen)
        lastLaunchedVersion = try container.decodeIfPresent(String.self, forKey: .lastLaunchedVersion)
        intAppPresentation = try container.decodeIfPresent(Int.self, forKey: .intAppPresentation)
        appPresentationChosen = try container.decodeIfPresent(Bool.self, forKey: .appPresentationChosen)
        legacyMigrationPending = try container.decodeIfPresent(Bool.self, forKey: .legacyMigrationPending)
        dockQuitExplained = try container.decodeIfPresent(Bool.self, forKey: .dockQuitExplained)
        dockDownloadBadge = try container.decodeIfPresent(Bool.self, forKey: .dockDownloadBadge)
        agentRestartedForIdentity = try container.decodeIfPresent(String.self, forKey: .agentRestartedForIdentity)
    }
}

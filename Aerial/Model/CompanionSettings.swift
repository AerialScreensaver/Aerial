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

    /// UUIDs of screens with wallpaper mode enabled
    var enabledWallpaperScreenUuids: [String]

    /// Whether to restart background mode after wallpaper changes
    var restartBackground: Bool

    /// Whether background mode was running before (state tracking)
    var wasRunningBackground: Bool

    // MARK: - Performance Settings

    /// Global playback speed (0-100)
    var globalSpeed: Int

    // MARK: - UI Settings

    /// Show playlist in list mode (true) or strip mode (false)
    var playlistListMode: Bool

    /// Shuffle playlist on wrap-around (true) or replay same order (false)
    var playlistShuffle: Bool

    // MARK: - Desktop Behavior Settings

    /// Auto-pause desktop mode when windows occlude the screen
    var desktopAutoPause: Bool

    /// Coverage threshold (0.0–1.0) at which to auto-pause
    var desktopAutoPauseThreshold: Double

    /// Replace the desktop wallpaper with a still frame of the playing
    /// video at key moments (new video, system sleep) to keep visual
    /// continuity through the wake/login transition.
    var replaceWallpaper: Bool

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

    // MARK: - Defaults

    /// Default settings for fresh install
    static let `default` = CompanionSettings(
        intLaunchMode: LaunchMode.manual.rawValue,
        debugMode: false,
        firstTimeSetup: false,
        enabledWallpaperScreenUuids: [],
        restartBackground: true,
        wasRunningBackground: false,
        globalSpeed: 0,
        playlistListMode: true,
        playlistShuffle: false,
        desktopAutoPause: true,
        desktopAutoPauseThreshold: 0.6,
        replaceWallpaper: false,
        cleanWallpaperCache: true,
        wallpaperCacheBookmark: nil,
        popoverSolidBackground: false,
        invertColors: false,
        globalShortcutsEnabled: false,
        dismissedNewBadges: [],
        firstLaunchCompleted: nil,
        enabledNowPlayingSources: [],
        desktopPauseOnBattery: false,
        desktopPauseOnBatteryMode: "anyBattery"
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
            enabledWallpaperScreenUuids: UserDefaults.standard.object(forKey: "enabledWallpaperScreenUuids") as? [String] ?? [],
            restartBackground: UserDefaults.standard.object(forKey: "restartBackground") as? Bool ?? true,
            wasRunningBackground: UserDefaults.standard.object(forKey: "wasRunningBackground") as? Bool ?? false,
            globalSpeed: UserDefaults.standard.object(forKey: "globalSpeed") as? Int ?? 0,
            playlistListMode: true,
            playlistShuffle: false,
            desktopAutoPause: true,
            desktopAutoPauseThreshold: 0.6
        )
    }

    // MARK: - Memberwise Init

    init(intLaunchMode: Int, debugMode: Bool, firstTimeSetup: Bool,
         enabledWallpaperScreenUuids: [String], restartBackground: Bool,
         wasRunningBackground: Bool, globalSpeed: Int, playlistListMode: Bool,
         playlistShuffle: Bool, desktopAutoPause: Bool = true,
         desktopAutoPauseThreshold: Double = 0.6,
         replaceWallpaper: Bool = false,
         cleanWallpaperCache: Bool = true,
         wallpaperCacheBookmark: Data? = nil,
         popoverSolidBackground: Bool = false,
         invertColors: Bool = false,
         globalShortcutsEnabled: Bool = false,
         dismissedNewBadges: [String] = [],
         firstLaunchCompleted: Bool? = nil,
         enabledNowPlayingSources: [String] = [],
         desktopPauseOnBattery: Bool = false,
         desktopPauseOnBatteryMode: String = "anyBattery") {
        self.intLaunchMode = intLaunchMode
        self.debugMode = debugMode
        self.firstTimeSetup = firstTimeSetup
        self.enabledWallpaperScreenUuids = enabledWallpaperScreenUuids
        self.restartBackground = restartBackground
        self.wasRunningBackground = wasRunningBackground
        self.globalSpeed = globalSpeed
        self.playlistListMode = playlistListMode
        self.playlistShuffle = playlistShuffle
        self.desktopAutoPause = desktopAutoPause
        self.desktopAutoPauseThreshold = desktopAutoPauseThreshold
        self.replaceWallpaper = replaceWallpaper
        self.cleanWallpaperCache = cleanWallpaperCache
        self.wallpaperCacheBookmark = wallpaperCacheBookmark
        self.popoverSolidBackground = popoverSolidBackground
        self.invertColors = invertColors
        self.globalShortcutsEnabled = globalShortcutsEnabled
        self.dismissedNewBadges = dismissedNewBadges
        self.firstLaunchCompleted = firstLaunchCompleted
        self.enabledNowPlayingSources = enabledNowPlayingSources
        self.desktopPauseOnBattery = desktopPauseOnBattery
        self.desktopPauseOnBatteryMode = desktopPauseOnBatteryMode
    }

    // MARK: - Backward-Compatible Decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intLaunchMode = try container.decode(Int.self, forKey: .intLaunchMode)
        debugMode = try container.decode(Bool.self, forKey: .debugMode)
        firstTimeSetup = try container.decode(Bool.self, forKey: .firstTimeSetup)
        enabledWallpaperScreenUuids = try container.decode([String].self, forKey: .enabledWallpaperScreenUuids)
        restartBackground = try container.decode(Bool.self, forKey: .restartBackground)
        wasRunningBackground = try container.decode(Bool.self, forKey: .wasRunningBackground)
        globalSpeed = try container.decode(Int.self, forKey: .globalSpeed)
        playlistListMode = try container.decodeIfPresent(Bool.self, forKey: .playlistListMode) ?? false
        playlistShuffle = try container.decodeIfPresent(Bool.self, forKey: .playlistShuffle) ?? false
        desktopAutoPause = try container.decodeIfPresent(Bool.self, forKey: .desktopAutoPause) ?? true
        desktopAutoPauseThreshold = try container.decodeIfPresent(Double.self, forKey: .desktopAutoPauseThreshold) ?? 0.6
        replaceWallpaper = try container.decodeIfPresent(Bool.self, forKey: .replaceWallpaper) ?? false
        cleanWallpaperCache = try container.decodeIfPresent(Bool.self, forKey: .cleanWallpaperCache) ?? true
        wallpaperCacheBookmark = try container.decodeIfPresent(Data.self, forKey: .wallpaperCacheBookmark)
        popoverSolidBackground = try container.decodeIfPresent(Bool.self, forKey: .popoverSolidBackground) ?? false
        invertColors = try container.decodeIfPresent(Bool.self, forKey: .invertColors) ?? false
        globalShortcutsEnabled = try container.decodeIfPresent(Bool.self, forKey: .globalShortcutsEnabled) ?? false
        dismissedNewBadges = try container.decodeIfPresent([String].self, forKey: .dismissedNewBadges) ?? []
        firstLaunchCompleted = try container.decodeIfPresent(Bool.self, forKey: .firstLaunchCompleted)
        enabledNowPlayingSources = try container.decodeIfPresent([String].self, forKey: .enabledNowPlayingSources) ?? []
        desktopPauseOnBattery = try container.decodeIfPresent(Bool.self, forKey: .desktopPauseOnBattery) ?? false
        desktopPauseOnBatteryMode = try container.decodeIfPresent(String.self, forKey: .desktopPauseOnBatteryMode) ?? "anyBattery"
    }
}

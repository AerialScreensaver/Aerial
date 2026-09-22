//
//  Preferences.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 25/07/2020.
//

import Foundation

enum LaunchMode: Int, Codable {
    case manual = 0
    case startup = 1
    // Legacy "background" (rawValue 2) is mapped to .startup in the getter below
}

/// The user's chosen wallpaper mode on macOS Sonoma+ (the three-mode
/// model). Persisted via `Preferences.wallpaperMode`.
///
/// - `off`: screensaver only — Aerial4 isn't the system wallpaper.
/// - `paused`: Aerial4 is the wallpaper but paused (a static frame).
/// - `animated`: Aerial4 wallpaper plays, auto-pausing when covered.
///
/// `paused` ↔ `animated` is the live switch driven by
/// `WallpaperControl.paused` (the popover/dashboard play-pause button).
/// Turning the wallpaper on/off as the *system* wallpaper isn't yet
/// programmatically possible — see `WallpaperEnablement` TODOs.
enum WallpaperMode: Int, Codable {
    case off = 0
    case paused = 1
    case animated = 2
}

/// Where the Companion app lives on screen — its "presentation".
/// Persisted via `Preferences.appPresentation`.
///
/// - `menuBar`: accessory app (LSUIElement); the status item + popover
///   is the main UI. The historical Aerial shape.
/// - `dock`: regular app with a Dock icon and a visible main menu; the
///   Video Library window (Home) is the main UI, there is no status item.
///
/// Kept as an enum rather than a Bool so a combined "Dock and menu bar"
/// presentation can be added later by flipping the two flags below —
/// `AppPresentationController` only ever reads the flags.
enum AppPresentation: Int, Codable, CaseIterable {
    case menuBar = 0
    case dock = 1

    /// Whether the status item + popover exist in this presentation.
    var showsStatusItem: Bool { self == .menuBar }

    /// Whether the app runs with the `.regular` activation policy
    /// (Dock icon, main menu, Video Library as the main window).
    var showsDockIcon: Bool { self == .dock }
}

struct Preferences {
    // MARK: - Settings Manager

    private static let manager = CompanionSettingsManager.shared

    // MARK: - Launch Settings

    static var intLaunchMode: Int {
        get { manager.getValue(forKeyPath: \.intLaunchMode) }
        set { manager.setValue(newValue, forKeyPath: \.intLaunchMode) }
    }

    static var launchMode: LaunchMode {
        get {
            let raw = intLaunchMode
            // Legacy "background" mode (rawValue 2) maps to startup
            if raw >= 2 { return .startup }
            return LaunchMode(rawValue: raw) ?? .manual
        }
        set(value) {
            intLaunchMode = value.rawValue
        }
    }

    // MARK: - Wallpaper Settings

    /// Raw backing store for `wallpaperMode`. Nil until the user picks a
    /// mode (or on legacy installs); `wallpaperMode` maps nil → `.animated`.
    static var intWallpaperMode: Int? {
        get { manager.getValue(forKeyPath: \.intWallpaperMode) }
        set { manager.setValue(newValue, forKeyPath: \.intWallpaperMode) }
    }

    /// The chosen Sonoma+ wallpaper mode (off / paused / animated).
    /// Defaults to `.animated` — the recommended default — when unset.
    static var wallpaperMode: WallpaperMode {
        get { WallpaperMode(rawValue: intWallpaperMode ?? WallpaperMode.animated.rawValue) ?? .animated }
        set { intWallpaperMode = newValue.rawValue }
    }

    // MARK: - App Presentation

    /// Raw backing store for `appPresentation`. Nil until the user picks
    /// one (wizard step, upgrade prompt or Settings); nil → `.menuBar`.
    static var intAppPresentation: Int? {
        get { manager.getValue(forKeyPath: \.intAppPresentation) }
        set { manager.setValue(newValue, forKeyPath: \.intAppPresentation) }
    }

    /// Menu bar (the default) or Dock — see `AppPresentation`.
    static var appPresentation: AppPresentation {
        get { AppPresentation(rawValue: intAppPresentation ?? AppPresentation.menuBar.rawValue) ?? .menuBar }
        set { intAppPresentation = newValue.rawValue }
    }

    /// True once the user has explicitly chosen a presentation (the
    /// wizard step or the one-time upgrade prompt). Gates the prompt for
    /// existing users. Deliberately a sentinel and NOT a version check:
    /// beta installs already report a 4.1 `lastLaunchedVersion`, so a
    /// "first launch of 4.1" test would skip them.
    static var appPresentationChosen: Bool {
        get { manager.getValue(forKeyPath: \.appPresentationChosen) ?? false }
        set { manager.setValue(newValue, forKeyPath: \.appPresentationChosen) }
    }

    /// Dock presentation only: true once the one-time "Aerial keeps
    /// working in the background" quit explanation has been shown and
    /// suppressed — see `AppPresentationController.shouldTerminate()`.
    static var dockQuitExplained: Bool {
        get { manager.getValue(forKeyPath: \.dockQuitExplained) ?? false }
        set { manager.setValue(newValue, forKeyPath: \.dockQuitExplained) }
    }

    /// Dock presentation: badge the Dock icon with the number of videos
    /// left to download. On by default (Settings → Cache → Downloads).
    static var dockDownloadBadge: Bool {
        get { manager.getValue(forKeyPath: \.dockDownloadBadge) ?? true }
        set { manager.setValue(newValue, forKeyPath: \.dockDownloadBadge) }
    }

    // MARK: - Performance Settings

    static var globalSpeed: Int {
        get { manager.getValue(forKeyPath: \.globalSpeed) }
        set { manager.setValue(newValue, forKeyPath: \.globalSpeed) }
    }

    // MARK: - UI Settings

    static var playlistListMode: Bool {
        get { manager.getValue(forKeyPath: \.playlistListMode) }
        set { manager.setValue(newValue, forKeyPath: \.playlistListMode) }
    }

    static var playlistShuffle: Bool {
        get { manager.getValue(forKeyPath: \.playlistShuffle) }
        set { manager.setValue(newValue, forKeyPath: \.playlistShuffle) }
    }

    /// Tri-state playlist cycle mode (loop / shuffle / repeat one).
    /// Supersedes `playlistShuffle`.
    static var playlistMode: PlaylistCycleMode {
        get { PlaylistCycleMode(rawValue: manager.getValue(forKeyPath: \.playlistCycleMode)) ?? .loop }
        set { manager.setValue(newValue.rawValue, forKeyPath: \.playlistCycleMode) }
    }

    // MARK: - Desktop Behavior Settings

    static var desktopAutoPause: Bool {
        get { manager.getValue(forKeyPath: \.desktopAutoPause) }
        set { manager.setValue(newValue, forKeyPath: \.desktopAutoPause) }
    }

    static var desktopAutoPauseThreshold: Double {
        get { manager.getValue(forKeyPath: \.desktopAutoPauseThreshold) }
        set { manager.setValue(newValue, forKeyPath: \.desktopAutoPauseThreshold) }
    }

    static var desktopAutoPauseIgnoredApps: [String] {
        get { manager.getValue(forKeyPath: \.desktopAutoPauseIgnoredApps) }
        set { manager.setValue(newValue, forKeyPath: \.desktopAutoPauseIgnoredApps) }
    }

    static var cleanWallpaperCache: Bool {
        get { manager.getValue(forKeyPath: \.cleanWallpaperCache) }
        set { manager.setValue(newValue, forKeyPath: \.cleanWallpaperCache) }
    }

    static var wallpaperCacheBookmark: Data? {
        get { manager.getValue(forKeyPath: \.wallpaperCacheBookmark) }
        set { manager.setValue(newValue, forKeyPath: \.wallpaperCacheBookmark) }
    }

    static var reclaimMacOSWallpaperVideosAtStartup: Bool {
        get { manager.getValue(forKeyPath: \.reclaimMacOSWallpaperVideosAtStartup) }
        set { manager.setValue(newValue, forKeyPath: \.reclaimMacOSWallpaperVideosAtStartup) }
    }

    // MARK: - Accessibility Settings

    static var popoverSolidBackground: Bool {
        get { manager.getValue(forKeyPath: \.popoverSolidBackground) }
        set { manager.setValue(newValue, forKeyPath: \.popoverSolidBackground) }
    }

    static var invertColors: Bool {
        get { manager.getValue(forKeyPath: \.invertColors) }
        set { manager.setValue(newValue, forKeyPath: \.invertColors) }
    }

    static var globalShortcutsEnabled: Bool {
        get { manager.getValue(forKeyPath: \.globalShortcutsEnabled) }
        set { manager.setValue(newValue, forKeyPath: \.globalShortcutsEnabled) }
    }

    static var dismissedNewBadges: [String] {
        get { manager.getValue(forKeyPath: \.dismissedNewBadges) }
        set { manager.setValue(newValue, forKeyPath: \.dismissedNewBadges) }
    }

    static func dismissNewBadge(_ id: String) {
        var current = dismissedNewBadges
        guard !current.contains(id) else { return }
        current.append(id)
        dismissedNewBadges = current
    }

    // MARK: - First-Launch Wizard

    /// True once the wizard has been completed (or dismissed). Defaults
    /// to false when the field is missing in the on-disk settings — see
    /// `FirstLaunch.shouldShowWizard` for the existing-user safety net
    /// that auto-marks pre-existing installs as already complete.
    static var firstLaunchCompleted: Bool {
        get { manager.getValue(forKeyPath: \.firstLaunchCompleted) ?? false }
        set { manager.setValue(newValue, forKeyPath: \.firstLaunchCompleted) }
    }

    /// True once the user has explicitly chosen a wallpaper mode (wizard
    /// mode step or the one-time 4.1 upgrade prompt). Separate from
    /// `firstLaunchCompleted` so existing users — already wizard-complete
    /// — still get the mode prompt exactly once on the Sonoma+ upgrade.
    static var wallpaperModeChosen: Bool {
        get { manager.getValue(forKeyPath: \.wallpaperModeChosen) ?? false }
        set { manager.setValue(newValue, forKeyPath: \.wallpaperModeChosen) }
    }

    /// App version string (`CFBundleShortVersionString`) seen at the
    /// previous launch, for upgrade detection. Nil on the first launch
    /// that records it.
    static var lastLaunchedVersion: String? {
        get { manager.getValue(forKeyPath: \.lastLaunchedVersion) }
        set { manager.setValue(newValue, forKeyPath: \.lastLaunchedVersion) }
    }

    /// Bundled-appex identity for which the stale-extension check has
    /// already restarted WallpaperAgent — see `WallpaperExtensionHealth`.
    static var agentRestartedForIdentity: String? {
        get { manager.getValue(forKeyPath: \.agentRestartedForIdentity) }
        set { manager.setValue(newValue, forKeyPath: \.agentRestartedForIdentity) }
    }

    // MARK: - Now Playing Sources

    /// Reverse-DNS identifiers of enabled NowPlayingSource providers.
    /// Empty array = all sources from `NowPlayingSourceRegistry.all`
    /// are enabled (the implicit default until the user customizes).
    static var enabledNowPlayingSources: [String] {
        get { manager.getValue(forKeyPath: \.enabledNowPlayingSources) }
        set { manager.setValue(newValue, forKeyPath: \.enabledNowPlayingSources) }
    }

    // MARK: - Battery-aware pause

    /// Master switch — when true, desktop wallpaper and fullscreen-window
    /// playback pauses on battery per `desktopPauseOnBatteryMode`.
    static var desktopPauseOnBattery: Bool {
        get { manager.getValue(forKeyPath: \.desktopPauseOnBattery) }
        set { manager.setValue(newValue, forKeyPath: \.desktopPauseOnBattery) }
    }

    /// `"anyBattery"` (any time AC is unplugged) or `"lowBattery"`
    /// (unplugged AND remaining capacity <20%).
    static var desktopPauseOnBatteryMode: String {
        get { manager.getValue(forKeyPath: \.desktopPauseOnBatteryMode) }
        set { manager.setValue(newValue, forKeyPath: \.desktopPauseOnBatteryMode) }
    }

    // MARK: - Thermal / Low Power Mode pause

    /// Pause the wallpaper while thermal pressure is serious/critical.
    static var desktopPauseOnThermal: Bool {
        get { manager.getValue(forKeyPath: \.desktopPauseOnThermal) }
        set { manager.setValue(newValue, forKeyPath: \.desktopPauseOnThermal) }
    }

    /// Pause the wallpaper while macOS Low Power Mode is enabled.
    static var desktopPauseOnLowPower: Bool {
        get { manager.getValue(forKeyPath: \.desktopPauseOnLowPower) }
        set { manager.setValue(newValue, forKeyPath: \.desktopPauseOnLowPower) }
    }

    /// Pause the wallpaper while any camera is in use.
    static var desktopPauseOnCamera: Bool {
        get { manager.getValue(forKeyPath: \.desktopPauseOnCamera) }
        set { manager.setValue(newValue, forKeyPath: \.desktopPauseOnCamera) }
    }

    // MARK: - Auto-Advance

    /// Auto-advance the playlist on all screens at a fixed cadence
    /// (equivalent of pressing next), so paused/auto-paused wallpapers
    /// don't show the same frame forever. Off by default.
    static var desktopAutoAdvance: Bool {
        get { manager.getValue(forKeyPath: \.desktopAutoAdvance) }
        set { manager.setValue(newValue, forKeyPath: \.desktopAutoAdvance) }
    }

    /// Auto-advance cadence in minutes (15…1440 = daily).
    static var desktopAutoAdvanceMinutes: Int {
        get { manager.getValue(forKeyPath: \.desktopAutoAdvanceMinutes) }
        set { manager.setValue(newValue, forKeyPath: \.desktopAutoAdvanceMinutes) }
    }

    /// Show a "Restart Wallpaper Agent" button in the menu bar popover
    /// and on Home — Settings → Wallpaper → Troubleshooting checkbox.
    /// Surfaces observe `.showRestartWallpaperButtonDidChange`.
    static var showRestartWallpaperButton: Bool {
        get { manager.getValue(forKeyPath: \.showRestartWallpaperButton) }
        set { manager.setValue(newValue, forKeyPath: \.showRestartWallpaperButton) }
    }

}

extension Notification.Name {
    static let popoverSolidBackgroundDidChange = Notification.Name("com.glouel.aerial.popoverSolidBackgroundDidChange")
    static let showRestartWallpaperButtonDidChange = Notification.Name("com.glouel.aerial.showRestartWallpaperButtonDidChange")
}

// MARK: - Legacy Property Wrappers (Deprecated)
// The following property wrappers are no longer used as of v3.x
// Settings are now stored in /Users/Shared/Aerial/companion.json
// Kept for reference during migration period

/*
@propertyWrapper struct CompanionStorage<T: Codable> {
    private let key: String
    private let defaultValue: T

    init(key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: T {
        get {
            if let jsonString = UserDefaults.standard.string(forKey: key) {
                guard let jsonData = jsonString.data(using: .utf8) else {
                    return defaultValue
                }
                guard let value = try? JSONDecoder().decode(T.self, from: jsonData) else {
                    return defaultValue
                }
                return value
            }
            return defaultValue
        }
        set {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try? encoder.encode(newValue)
            let jsonString = String(bytes: jsonData!, encoding: .utf8)
            UserDefaults.standard.set(jsonString, forKey: key)
            UserDefaults.standard.synchronize()
        }
    }
}

@propertyWrapper struct CompanionSimpleStorage<T> {
    private let key: String
    private let defaultValue: T

    init(key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: T {
        get {
            return UserDefaults.standard.object(forKey: key) as? T ?? defaultValue
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            UserDefaults.standard.synchronize()
        }
    }
}
*/

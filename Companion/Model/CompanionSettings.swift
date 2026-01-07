//
//  CompanionSettings.swift
//  Aerial Companion
//

import Foundation

/// Consolidated settings structure for Aerial Companion app
/// Replaces individual UserDefaults entries with a single JSON file at /Users/Shared/Aerial/companion.json
struct CompanionSettings: Codable {

    // MARK: - Update Settings

    /// Which version to check for (beta or release)
    var intDesiredVersion: Int

    /// Update mode (automatic or notify)
    var intUpdateMode: Int

    /// How often to check for updates
    var intCheckEvery: Int

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

    // MARK: - Screensaver Watchdog Settings

    /// Enable the legacy screensaver watchdog
    var enableScreensaverWatchdog: Bool

    /// Watchdog timer delay in seconds before killing legacyScreenSaver
    var watchdogTimerDelay: Int

    // MARK: - Defaults

    /// Default settings for fresh install
    static let `default` = CompanionSettings(
        intDesiredVersion: DesiredVersion.release.rawValue,
        intUpdateMode: CompanionUpdateMode.notifyme.rawValue,
        intCheckEvery: CheckEvery.day.rawValue,
        intLaunchMode: LaunchMode.manual.rawValue,
        debugMode: false,
        firstTimeSetup: false,
        enabledWallpaperScreenUuids: [],
        restartBackground: true,
        wasRunningBackground: false,
        globalSpeed: 100,
        enableScreensaverWatchdog: true,
        watchdogTimerDelay: 5
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
            intDesiredVersion: UserDefaults.standard.object(forKey: "intDesiredVersion") as? Int ?? DesiredVersion.release.rawValue,
            intUpdateMode: UserDefaults.standard.object(forKey: "intUpdateMode") as? Int ?? CompanionUpdateMode.notifyme.rawValue,
            intCheckEvery: UserDefaults.standard.object(forKey: "intCheckEvery") as? Int ?? CheckEvery.day.rawValue,
            intLaunchMode: UserDefaults.standard.object(forKey: "intLaunchMode") as? Int ?? LaunchMode.manual.rawValue,
            debugMode: UserDefaults.standard.object(forKey: "debugMode") as? Bool ?? false,
            firstTimeSetup: UserDefaults.standard.object(forKey: "firstTimeSetup") as? Bool ?? false,
            enabledWallpaperScreenUuids: UserDefaults.standard.object(forKey: "enabledWallpaperScreenUuids") as? [String] ?? [],
            restartBackground: UserDefaults.standard.object(forKey: "restartBackground") as? Bool ?? true,
            wasRunningBackground: UserDefaults.standard.object(forKey: "wasRunningBackground") as? Bool ?? false,
            globalSpeed: UserDefaults.standard.object(forKey: "globalSpeed") as? Int ?? 100,
            enableScreensaverWatchdog: UserDefaults.standard.object(forKey: "enableScreensaverWatchdog") as? Bool ?? true,
            watchdogTimerDelay: UserDefaults.standard.object(forKey: "watchdogTimerDelay") as? Int ?? 5
        )
    }
}

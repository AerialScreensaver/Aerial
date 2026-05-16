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

    static var enabledWallpaperScreenUuids: [String] {
        get { manager.getValue(forKeyPath: \.enabledWallpaperScreenUuids) }
        set { manager.setValue(newValue, forKeyPath: \.enabledWallpaperScreenUuids) }
    }

    static var restartBackground: Bool {
        get { manager.getValue(forKeyPath: \.restartBackground) }
        set { manager.setValue(newValue, forKeyPath: \.restartBackground) }
    }

    static var wasRunningBackground: Bool {
        get { manager.getValue(forKeyPath: \.wasRunningBackground) }
        set { manager.setValue(newValue, forKeyPath: \.wasRunningBackground) }
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

    // MARK: - Desktop Behavior Settings

    static var desktopAutoPause: Bool {
        get { manager.getValue(forKeyPath: \.desktopAutoPause) }
        set { manager.setValue(newValue, forKeyPath: \.desktopAutoPause) }
    }

    static var desktopAutoPauseThreshold: Double {
        get { manager.getValue(forKeyPath: \.desktopAutoPauseThreshold) }
        set { manager.setValue(newValue, forKeyPath: \.desktopAutoPauseThreshold) }
    }

    static var replaceWallpaper: Bool {
        get { manager.getValue(forKeyPath: \.replaceWallpaper) }
        set { manager.setValue(newValue, forKeyPath: \.replaceWallpaper) }
    }

    static var cleanWallpaperCache: Bool {
        get { manager.getValue(forKeyPath: \.cleanWallpaperCache) }
        set { manager.setValue(newValue, forKeyPath: \.cleanWallpaperCache) }
    }

    static var wallpaperCacheBookmark: Data? {
        get { manager.getValue(forKeyPath: \.wallpaperCacheBookmark) }
        set { manager.setValue(newValue, forKeyPath: \.wallpaperCacheBookmark) }
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

    // MARK: - Now Playing Sources

    /// Reverse-DNS identifiers of enabled NowPlayingSource providers.
    /// Empty array = all sources from `NowPlayingSourceRegistry.all`
    /// are enabled (the implicit default until the user customizes).
    static var enabledNowPlayingSources: [String] {
        get { manager.getValue(forKeyPath: \.enabledNowPlayingSources) }
        set { manager.setValue(newValue, forKeyPath: \.enabledNowPlayingSources) }
    }

}

extension Notification.Name {
    static let popoverSolidBackgroundDidChange = Notification.Name("com.glouel.aerial.popoverSolidBackgroundDidChange")
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

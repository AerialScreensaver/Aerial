//
//  Preferences.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 25/07/2020.
//

import Foundation

enum DesiredVersion: Int, Codable {
    case beta, release
}

enum CompanionUpdateMode: Int, Codable {
    case automatic, notifyme
}

enum CheckEvery: Int, Codable {
    case hour, day, week
}

enum LaunchMode: Int, Codable {
    case manual, startup, background
}

struct Preferences {
    // MARK: - Settings Manager

    private static let manager = CompanionSettingsManager.shared

    // MARK: - Update Settings

    // Which version are we looking for ? Defaults to release
    static var intDesiredVersion: Int {
        get { manager.getValue(forKeyPath: \.intDesiredVersion) }
        set { manager.setValue(newValue, forKeyPath: \.intDesiredVersion) }
    }

    static var desiredVersion: DesiredVersion {
        get {
            return DesiredVersion(rawValue: intDesiredVersion)!
        }
        set(value) {
            intDesiredVersion = value.rawValue
        }
    }

    // Automatic or notifications ?
    static var intUpdateMode: Int {
        get { manager.getValue(forKeyPath: \.intUpdateMode) }
        set { manager.setValue(newValue, forKeyPath: \.intUpdateMode) }
    }

    static var updateMode: CompanionUpdateMode {
        get {
            return CompanionUpdateMode(rawValue: intUpdateMode)!
        }
        set(value) {
            intUpdateMode = value.rawValue
        }
    }

    // Check frequency
    static var intCheckEvery: Int {
        get { manager.getValue(forKeyPath: \.intCheckEvery) }
        set { manager.setValue(newValue, forKeyPath: \.intCheckEvery) }
    }

    static var checkEvery: CheckEvery {
        get {
            return CheckEvery(rawValue: intCheckEvery)!
        }
        set(value) {
            intCheckEvery = value.rawValue
        }
    }

    // MARK: - Launch Settings

    // Automatic or notifications ?
    static var intLaunchMode: Int {
        get { manager.getValue(forKeyPath: \.intLaunchMode) }
        set { manager.setValue(newValue, forKeyPath: \.intLaunchMode) }
    }

    static var launchMode: LaunchMode {
        get {
            return LaunchMode(rawValue: intLaunchMode)!
        }
        set(value) {
            intLaunchMode = value.rawValue
        }
    }

    // MARK: - Debug Settings

    static var debugMode: Bool {
        get { manager.getValue(forKeyPath: \.debugMode) }
        set { manager.setValue(newValue, forKeyPath: \.debugMode) }
    }

    static var firstTimeSetup: Bool {
        get { manager.getValue(forKeyPath: \.firstTimeSetup) }
        set { manager.setValue(newValue, forKeyPath: \.firstTimeSetup) }
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

    // MARK: - Screensaver Watchdog Settings

    // Enable/disable the legacy screensaver watchdog
    static var enableScreensaverWatchdog: Bool {
        get { manager.getValue(forKeyPath: \.enableScreensaverWatchdog) }
        set { manager.setValue(newValue, forKeyPath: \.enableScreensaverWatchdog) }
    }

    // Watchdog delay in seconds before killing legacyScreenSaver
    static var watchdogTimerDelay: Int {
        get { manager.getValue(forKeyPath: \.watchdogTimerDelay) }
        set { manager.setValue(newValue, forKeyPath: \.watchdogTimerDelay) }
    }
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
            if #available(OSX 10.13, *) {
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            } else {
                encoder.outputFormatting = [.prettyPrinted]
            }
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

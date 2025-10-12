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
    // Which version are we looking for ? Defaults to release
    @CompanionSimpleStorage(key: "intDesiredVersion", defaultValue: DesiredVersion.release.rawValue)
    static var intDesiredVersion: Int
    
    // We wrap in a separate value, as we can't store an enum as a Codable in
    // macOS < 10.15
    static var desiredVersion: DesiredVersion {
        get {
            return DesiredVersion(rawValue: intDesiredVersion)!
        }
        set(value) {
            intDesiredVersion = value.rawValue
        }
    }
    
    // Automatic or notifications ?
    @CompanionSimpleStorage(key: "intUpdateMode", defaultValue: CompanionUpdateMode.notifyme.rawValue)
    static var intUpdateMode: Int
    
    // We wrap in a separate value, as we can't store an enum as a Codable in
    // macOS < 10.15
    static var updateMode: CompanionUpdateMode {
        get {
            return CompanionUpdateMode(rawValue: intUpdateMode)!
        }
        set(value) {
            intUpdateMode = value.rawValue
        }
    }
    
    
    // Check frequency
    @CompanionSimpleStorage(key: "intCheckEvery", defaultValue: CheckEvery.day.rawValue)
    static var intCheckEvery: Int
    
    // We wrap in a separate value, as we can't store an enum as a Codable in
    // macOS < 10.15
    static var checkEvery: CheckEvery {
        get {
            return CheckEvery(rawValue: intCheckEvery)!
        }
        set(value) {
            intCheckEvery = value.rawValue
        }
    }
    
    // Automatic or notifications ?
    @CompanionSimpleStorage(key: "intLaunchMode", defaultValue: LaunchMode.manual.rawValue)
    static var intLaunchMode: Int
    
    // We wrap in a separate value, as we can't store an enum as a Codable in
    // macOS < 10.15
    static var launchMode: LaunchMode {
        get {
            return LaunchMode(rawValue: intLaunchMode)!
        }
        set(value) {
            intLaunchMode = value.rawValue
        }
    }
    
    @CompanionSimpleStorage(key: "debugMode", defaultValue: false)
    static var debugMode: Bool
    
    @CompanionSimpleStorage(key: "firstTimeSetup", defaultValue: false)
    static var firstTimeSetup: Bool

    // Check frequency
    @CompanionSimpleStorage(key: "enabledWallpaperScreenUuids", defaultValue: [])
    static var enabledWallpaperScreenUuids: [String]
    
    @CompanionSimpleStorage(key: "restartBackground", defaultValue: true)
    static var restartBackground: Bool
    
    @CompanionSimpleStorage(key: "wasRunningBackground", defaultValue: false)
    static var wasRunningBackground: Bool
    
    @CompanionSimpleStorage(key: "globalSpeed", defaultValue: 100)
    static var globalSpeed: Int

    // Enable/disable the legacy screensaver watchdog
    @CompanionSimpleStorage(key: "enableScreensaverWatchdog", defaultValue: true)
    static var enableScreensaverWatchdog: Bool
}


// This retrieves/store any type of property in our plist
@propertyWrapper struct CompanionStorage<T: Codable> {
    private let key: String
    private let defaultValue: T

    init(key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: T {
        get {
            // We shoot for a string in the new system
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

            // Set value to UserDefaults
            UserDefaults.standard.set(jsonString, forKey: key)

            // This is probably not needed here but...
            UserDefaults.standard.synchronize()
        }
    }
}

// This retrieves store "simple" types that are natively storable on plists
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
            UserDefaults.standard.synchronize() // Again...
        }
    }
}

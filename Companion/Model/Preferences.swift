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

enum UpdateMode: Int, Codable {
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
    @SimpleStorage(key: "intDesiredVersion", defaultValue: DesiredVersion.release.rawValue)
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
    @SimpleStorage(key: "intUpdateMode", defaultValue: UpdateMode.notifyme.rawValue)
    static var intUpdateMode: Int
    
    // We wrap in a separate value, as we can't store an enum as a Codable in
    // macOS < 10.15
    static var updateMode: UpdateMode {
        get {
            return UpdateMode(rawValue: intUpdateMode)!
        }
        set(value) {
            intUpdateMode = value.rawValue
        }
    }
    
    
    // Check frequency
    @SimpleStorage(key: "intCheckEvery", defaultValue: CheckEvery.day.rawValue)
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
    @SimpleStorage(key: "intLaunchMode", defaultValue: LaunchMode.manual.rawValue)
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
    
    @SimpleStorage(key: "debugMode", defaultValue: false)
    static var debugMode: Bool
    
    @SimpleStorage(key: "firstTimeSetup", defaultValue: false)
    static var firstTimeSetup: Bool

    // Check frequency
    @SimpleStorage(key: "enabledWallpaperScreenUuids", defaultValue: [])
    static var enabledWallpaperScreenUuids: [String]
    
    @SimpleStorage(key: "restartBackground", defaultValue: true)
    static var restartBackground: Bool
    
    @SimpleStorage(key: "wasRunningBackground", defaultValue: false)
    static var wasRunningBackground: Bool
    
    @SimpleStorage(key: "globalSpeed", defaultValue: 100)
    static var globalSpeed: Int
}


// This retrieves/store any type of property in our plist
@propertyWrapper struct Storage<T: Codable> {
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
@propertyWrapper struct SimpleStorage<T> {
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

//
//  PrefsTime.swift
//  Aerial
//
//  Created by Guillaume Louel on 21/01/2020.
//  Copyright © 2020 Guillaume Louel. All rights reserved.
//

import Foundation

enum TimeMode: Int {
    case disabled, nightShift, manual, lightDarkMode, coordinates, locationService
}

enum SolarMode: Int {
    case strict, official, civil, nautical, astronomical
}

struct PrefsTime {
    // MARK: - Settings Manager

    private static let manager = ScreensaverSettingsManager.shared

    // MARK: - Time Settings

    // Time Mode
    static var intTimeMode: Int {
        get { manager.getValue(forKeyPath: \.time.intTimeMode) }
        set { manager.setValue(newValue, forKeyPath: \.time.intTimeMode) }
    }

    static var timeMode: TimeMode {
        get {
            return TimeMode(rawValue: intTimeMode)!
        }
        set(value) {
            intTimeMode = value.rawValue
        }
    }

    // Manually specified sunrise/sunsets
    static var manualSunrise: String {
        get { manager.getValue(forKeyPath: \.time.manualSunrise) }
        set { manager.setValue(newValue, forKeyPath: \.time.manualSunrise) }
    }

    static var manualSunset: String {
        get { manager.getValue(forKeyPath: \.time.manualSunset) }
        set { manager.setValue(newValue, forKeyPath: \.time.manualSunset) }
    }

    // Manually specified latitude/longitude (strings)
    static var latitude: String {
        get { manager.getValue(forKeyPath: \.time.latitude) }
        set { manager.setValue(newValue, forKeyPath: \.time.latitude) }
    }

    static var longitude: String {
        get { manager.getValue(forKeyPath: \.time.longitude) }
        set { manager.setValue(newValue, forKeyPath: \.time.longitude) }
    }

    // Solar Mode
    static var intSolarMode: Int {
        get { manager.getValue(forKeyPath: \.time.intSolarMode) }
        set { manager.setValue(newValue, forKeyPath: \.time.intSolarMode) }
    }

    // Prefs sunrise/sunset duration
    static var sunEventWindow: Int {
        get { manager.getValue(forKeyPath: \.time.sunEventWindow) }
        set { manager.setValue(newValue, forKeyPath: \.time.sunEventWindow) }
    }

    static var solarMode: SolarMode {
        get {
            return SolarMode(rawValue: intSolarMode)!
        }
        set(value) {
            intSolarMode = value.rawValue
        }
    }

    // Override on macOS dark mode
    static var darkModeNightOverride: Bool {
        get { manager.getValue(forKeyPath: \.time.darkModeNightOverride) }
        set { manager.setValue(newValue, forKeyPath: \.time.darkModeNightOverride) }
    }

    // Last successful coordinates
    static var cachedLatitude: Double {
        get { manager.getValue(forKeyPath: \.time.cachedLatitude) }
        set { manager.setValue(newValue, forKeyPath: \.time.cachedLatitude) }
    }

    static var cachedLongitude: Double {
        get { manager.getValue(forKeyPath: \.time.cachedLongitude) }
        set { manager.setValue(newValue, forKeyPath: \.time.cachedLongitude) }
    }

    // Last geocoded string
    static var geocodedString: String {
        get { manager.getValue(forKeyPath: \.time.geocodedString) }
        set { manager.setValue(newValue, forKeyPath: \.time.geocodedString) }
    }
}

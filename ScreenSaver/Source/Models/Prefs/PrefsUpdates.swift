//
//  PrefsUpdates.swift
//  Aerial
//
//  Created by Guillaume Louel on 16/02/2020.
//  Copyright © 2020 Guillaume Louel. All rights reserved.
//

import Foundation

enum UpdateMode: Int {
    case notify, install
}

struct PrefsUpdates {
    // MARK: - Settings Manager

    private static let manager = ScreensaverSettingsManager.shared

    // MARK: - Update Settings

    // Whether to check for updates
    static var checkForUpdates: Bool {
        get { manager.getValue(forKeyPath: \.updatesPrefs.checkForUpdates) }
        set { manager.setValue(newValue, forKeyPath: \.updatesPrefs.checkForUpdates) }
    }

    // Update Mode when the screensaver runs (notify or install)
    static var intSparkleUpdateMode: Int {
        get { manager.getValue(forKeyPath: \.updatesPrefs.intSparkleUpdateMode) }
        set { manager.setValue(newValue, forKeyPath: \.updatesPrefs.intSparkleUpdateMode) }
    }

    // We wrap in a separate value for convenience
    static var sparkleUpdateMode: UpdateMode {
        get {
            return UpdateMode(rawValue: intSparkleUpdateMode)!
        }
        set(value) {
            intSparkleUpdateMode = value.rawValue
        }
    }
}

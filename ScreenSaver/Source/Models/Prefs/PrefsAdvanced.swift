//
//  PrefsAdvanced.swift
//  Aerial
//
//  Created by Guillaume Louel on 23/04/2020.
//  Copyright © 2020 Guillaume Louel. All rights reserved.
//

import Foundation

struct PrefsAdvanced {
    // MARK: - Settings Manager

    private static let manager = ScreensaverSettingsManager.shared

    // MARK: - Advanced Settings

    static var muteSound: Bool {
        get { manager.getValue(forKeyPath: \.advanced.muteSound) }
        set { manager.setValue(newValue, forKeyPath: \.advanced.muteSound) }
    }

    static var muteGlobalSound: Bool {
        get { manager.getValue(forKeyPath: \.advanced.muteGlobalSound) }
        set { manager.setValue(newValue, forKeyPath: \.advanced.muteGlobalSound) }
    }

    static var favorOrientation: Bool {
        get { manager.getValue(forKeyPath: \.advanced.favorOrientation) }
        set { manager.setValue(newValue, forKeyPath: \.advanced.favorOrientation) }
    }

    static var debugMode: Bool {
        get { manager.getValue(forKeyPath: \.advanced.debugMode) }
        set { manager.setValue(newValue, forKeyPath: \.advanced.debugMode) }
    }

    static var ciOverrideLanguage: String {
        get { manager.getValue(forKeyPath: \.advanced.ciOverrideLanguage) }
        set { manager.setValue(newValue, forKeyPath: \.advanced.ciOverrideLanguage) }
    }

    static var newDisplayDict: [String: Bool] {
        get { manager.getValue(forKeyPath: \.advanced.newDisplayDict) }
        set { manager.setValue(newValue, forKeyPath: \.advanced.newDisplayDict) }
    }
}

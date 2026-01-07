//
//  PrefsDisplays.swift
//  Aerial
//
//  Created by Guillaume Louel on 21/01/2020.
//  Copyright © 2020 Guillaume Louel. All rights reserved.
//

import Foundation

enum DisplayMode: Int {
    case allDisplays, mainOnly, secondaryOnly, selection
}

enum AspectMode: Int {
    case fill, fit
}

enum ViewingMode: Int {
    case independent, cloned, spanned, mirrored
}

struct PrefsDisplays {
    // MARK: - Settings Manager

    private static let manager = ScreensaverSettingsManager.shared

    // MARK: - Display Settings

    // Display Mode
    static var intDisplayMode: Int {
        get { manager.getValue(forKeyPath: \.displays.intDisplayMode) }
        set { manager.setValue(newValue, forKeyPath: \.displays.intDisplayMode) }
    }

    static var displayMode: DisplayMode {
        get {
            return DisplayMode(rawValue: intDisplayMode)!
        }
        set(value) {
            intDisplayMode = value.rawValue
        }
    }

    // Viewing Mode
    static var intViewingMode: Int {
        get { manager.getValue(forKeyPath: \.displays.intViewingMode) }
        set { manager.setValue(newValue, forKeyPath: \.displays.intViewingMode) }
    }

    static var viewingMode: ViewingMode {
        get {
            return ViewingMode(rawValue: intViewingMode)!
        }
        set(value) {
            intViewingMode = value.rawValue
        }
    }

    // Aspect Mode
    static var intAspectMode: Int {
        get { manager.getValue(forKeyPath: \.displays.intAspectMode) }
        set { manager.setValue(newValue, forKeyPath: \.displays.intAspectMode) }
    }

    static var aspectMode: AspectMode {
        get {
            return AspectMode(rawValue: intAspectMode)!
        }
        set(value) {
            intAspectMode = value.rawValue
        }
    }

    // Display margins
    static var displayMarginsAdvanced: Bool {
        get { manager.getValue(forKeyPath: \.displays.displayMarginsAdvanced) }
        set { manager.setValue(newValue, forKeyPath: \.displays.displayMarginsAdvanced) }
    }

    static var horizontalMargin: Double {
        get { manager.getValue(forKeyPath: \.displays.horizontalMargin) }
        set { manager.setValue(newValue, forKeyPath: \.displays.horizontalMargin) }
    }

    static var verticalMargin: Double {
        get { manager.getValue(forKeyPath: \.displays.verticalMargin) }
        set { manager.setValue(newValue, forKeyPath: \.displays.verticalMargin) }
    }

    // Advanced margins are stored as a string
    static var advancedMargins: String {
        get { manager.getValue(forKeyPath: \.displays.advancedMargins) }
        set { manager.setValue(newValue, forKeyPath: \.displays.advancedMargins) }
    }

    // Dimming settings
    static var dimBrightness: Bool {
        get { manager.getValue(forKeyPath: \.displays.dimBrightness) ?? false }
        set { manager.setValue(newValue, forKeyPath: \.displays.dimBrightness) }
    }

    static var dimOnlyAtNight: Bool {
        get { manager.getValue(forKeyPath: \.displays.dimOnlyAtNight) ?? false }
        set { manager.setValue(newValue, forKeyPath: \.displays.dimOnlyAtNight) }
    }

    static var dimOnlyOnBattery: Bool {
        get { manager.getValue(forKeyPath: \.displays.dimOnlyOnBattery) ?? false }
        set { manager.setValue(newValue, forKeyPath: \.displays.dimOnlyOnBattery) }
    }

    static var overrideDimInMinutes: Bool {
        get { manager.getValue(forKeyPath: \.displays.overrideDimInMinutes) ?? false }
        set { manager.setValue(newValue, forKeyPath: \.displays.overrideDimInMinutes) }
    }

    static var startDim: Double {
        get { manager.getValue(forKeyPath: \.displays.startDim) ?? 0.5 }
        set { manager.setValue(newValue, forKeyPath: \.displays.startDim) }
    }

    static var endDim: Double {
        get { manager.getValue(forKeyPath: \.displays.endDim) ?? 0.0 }
        set { manager.setValue(newValue, forKeyPath: \.displays.endDim) }
    }

    static var dimInMinutes: Int {
        get { manager.getValue(forKeyPath: \.displays.dimInMinutes) ?? 30 }
        set { manager.setValue(newValue, forKeyPath: \.displays.dimInMinutes) }
    }
}

struct PrefsDisplaysDesktop {
    // MARK: - Settings Manager

    private static let manager = ScreensaverSettingsManager.shared

    // MARK: - Desktop Display Settings

    // Display Mode
    static var intDisplayMode: Int {
        get { manager.getValue(forKeyPath: \.displaysDesktop.intDisplayMode) }
        set { manager.setValue(newValue, forKeyPath: \.displaysDesktop.intDisplayMode) }
    }

    static var displayMode: DisplayMode {
        get {
            return DisplayMode(rawValue: intDisplayMode)!
        }
        set(value) {
            intDisplayMode = value.rawValue
        }
    }

    // Viewing Mode
    static var intViewingMode: Int {
        get { manager.getValue(forKeyPath: \.displaysDesktop.intViewingMode) }
        set { manager.setValue(newValue, forKeyPath: \.displaysDesktop.intViewingMode) }
    }

    static var viewingMode: ViewingMode {
        get {
            return ViewingMode(rawValue: intViewingMode)!
        }
        set(value) {
            intViewingMode = value.rawValue
        }
    }

    // Aspect Mode
    static var intAspectMode: Int {
        get { manager.getValue(forKeyPath: \.displaysDesktop.intAspectMode) }
        set { manager.setValue(newValue, forKeyPath: \.displaysDesktop.intAspectMode) }
    }

    static var aspectMode: AspectMode {
        get {
            return AspectMode(rawValue: intAspectMode)!
        }
        set(value) {
            intAspectMode = value.rawValue
        }
    }

    // Display margins
    static var displayMarginsAdvanced: Bool {
        get { manager.getValue(forKeyPath: \.displaysDesktop.displayMarginsAdvanced) }
        set { manager.setValue(newValue, forKeyPath: \.displaysDesktop.displayMarginsAdvanced) }
    }

    static var horizontalMargin: Double {
        get { manager.getValue(forKeyPath: \.displaysDesktop.horizontalMargin) }
        set { manager.setValue(newValue, forKeyPath: \.displaysDesktop.horizontalMargin) }
    }

    static var verticalMargin: Double {
        get { manager.getValue(forKeyPath: \.displaysDesktop.verticalMargin) }
        set { manager.setValue(newValue, forKeyPath: \.displaysDesktop.verticalMargin) }
    }
}
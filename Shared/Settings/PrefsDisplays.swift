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

/// "Override if only one display remains": what the SCREENSAVER does on a
/// lone display when "Screensaver plays videos on" is anything but All
/// displays and the override is enabled. `play` equals the rule's own
/// fallback (a lone display always plays) stated explicitly; `dontPlay`
/// keeps it black. Evaluated by `SaverDisplayRule.playingDisplays`.
enum SingleDisplayOverride: Int {
    case play, dontPlay
}

enum AspectMode: Int {
    case fill, fit
}

enum ViewingMode: Int {
    case independent, cloned, spanned, mirrored

    /// Lowercase, sentence-friendly label. Used by settings panels that
    /// embed the mode name into a sentence ("In spanned mode...").
    var displayName: String {
        switch self {
        case .independent: return "independent"
        case .cloned:      return "cloned"
        case .spanned:     return "spanned"
        case .mirrored:    return "mirrored"
        }
    }
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
            return DisplayMode(rawValue: intDisplayMode) ?? .allDisplays
        }
        set(value) {
            intDisplayMode = value.rawValue
        }
    }

    // "Override if only one display remains" (checkbox + Play / Don't
    // play). Saver-only, like `displayMode`; inert under All displays.
    static var singleDisplayOverrideEnabled: Bool {
        get { manager.getValue(forKeyPath: \.displays.singleDisplayOverrideEnabled) }
        set { manager.setValue(newValue, forKeyPath: \.displays.singleDisplayOverrideEnabled) }
    }

    static var intSingleDisplayOverride: Int {
        get { manager.getValue(forKeyPath: \.displays.intSingleDisplayOverride) }
        set { manager.setValue(newValue, forKeyPath: \.displays.intSingleDisplayOverride) }
    }

    static var singleDisplayOverride: SingleDisplayOverride {
        get {
            return SingleDisplayOverride(rawValue: intSingleDisplayOverride) ?? .play
        }
        set(value) {
            intSingleDisplayOverride = value.rawValue
        }
    }

    /// The override as the rule wants it: nil while the checkbox is off.
    static var effectiveSingleDisplayOverride: SingleDisplayOverride? {
        singleDisplayOverrideEnabled ? singleDisplayOverride : nil
    }

    // "Use overlays from" (sub-option of the override, shown with per-screen
    // overlay layouts on): the display whose layout the lone display borrows.
    static var singleDisplayOverlayScreenUUID: String {
        get { manager.getValue(forKeyPath: \.displays.singleDisplayOverlayScreenUUID) }
        set { manager.setValue(newValue, forKeyPath: \.displays.singleDisplayOverlayScreenUUID) }
    }

    static var singleDisplayOverlayScreenName: String {
        get { manager.getValue(forKeyPath: \.displays.singleDisplayOverlayScreenName) }
        set { manager.setValue(newValue, forKeyPath: \.displays.singleDisplayOverlayScreenName) }
    }

    // Viewing Mode
    static var intViewingMode: Int {
        get { manager.getValue(forKeyPath: \.displays.intViewingMode) }
        set { manager.setValue(newValue, forKeyPath: \.displays.intViewingMode) }
    }

    static var viewingMode: ViewingMode {
        get {
            return ViewingMode(rawValue: intViewingMode) ?? .independent
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
            return AspectMode(rawValue: intAspectMode) ?? .fill
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

}
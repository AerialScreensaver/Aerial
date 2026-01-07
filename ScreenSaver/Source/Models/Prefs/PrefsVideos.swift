//
//  PrefsVideos.swift
//  Aerial
//
//  Created by Guillaume Louel on 23/12/2019.
//  Copyright © 2019 Guillaume Louel. All rights reserved.
//

import Foundation

enum VideoFormat: Int, Codable, CaseIterable {
    case v1080pH264, v1080pHEVC, v1080pHDR, v4KHEVC, v4KHDR, v4KSDR240
}

enum OnBatteryMode: Int, Codable {
    case keepEnabled, alwaysDisabled, disableOnLow
}

enum FadeMode: Int {
    // swiftlint:disable:next identifier_name
    case disabled, t0_5, t1, t2
}

enum ShouldPlay: Int {
    case everything, favorites, location, time, scene, source, collection
}

enum NewShouldPlay: Int {
    case location, favorites, time, scene, source
}

enum RefreshPeriodicity: Int {
    case weekly, monthly, never
}

struct PrefsVideos {
    // MARK: - Settings Manager

    private static let manager = ScreensaverSettingsManager.shared

    // MARK: - Video Settings

    // Main playback mode after v2.5
    static var intNewShouldPlay: Int {
        get { manager.getValue(forKeyPath: \.videos.intNewShouldPlay) }
        set { manager.setValue(newValue, forKeyPath: \.videos.intNewShouldPlay) }
    }

    static var newShouldPlay: NewShouldPlay {
        get {
            return NewShouldPlay(rawValue: intNewShouldPlay)!
        }
        set(value) {
            intNewShouldPlay = value.rawValue
        }
    }

    // Main playback mode (deprecated in 2.5)
    static var intShouldPlay: Int {
        get { manager.getValue(forKeyPath: \.videos.intShouldPlay) }
        set { manager.setValue(newValue, forKeyPath: \.videos.intShouldPlay) }
    }

    static var shouldPlay: ShouldPlay {
        get {
            return ShouldPlay(rawValue: intShouldPlay)!
        }
        set(value) {
            intShouldPlay = value.rawValue
        }
    }

    // Starting with v2.5
    static var newShouldPlayString: [String] {
        get { manager.getValue(forKeyPath: \.videos.newShouldPlayString) }
        set { manager.setValue(newValue, forKeyPath: \.videos.newShouldPlayString) }
    }

    // Deprecated in v2.5
    static var shouldPlayString: String {
        get { manager.getValue(forKeyPath: \.videos.shouldPlayString) }
        set { manager.setValue(newValue, forKeyPath: \.videos.shouldPlayString) }
    }

    // What do we do on battery?
    static var intOnBatteryMode: Int {
        get { manager.getValue(forKeyPath: \.videos.intOnBatteryMode) }
        set { manager.setValue(newValue, forKeyPath: \.videos.intOnBatteryMode) }
    }

    static var onBatteryMode: OnBatteryMode {
        get {
            return OnBatteryMode(rawValue: intOnBatteryMode)!
        }
        set(value) {
            intOnBatteryMode = value.rawValue
        }
    }

    // Internal storage for video format
    static var intVideoFormat: Int {
        get { manager.getValue(forKeyPath: \.videos.intVideoFormat) }
        set { manager.setValue(newValue, forKeyPath: \.videos.intVideoFormat) }
    }

    static var videoFormat: VideoFormat {
        get {
            return VideoFormat(rawValue: intVideoFormat)!
        }
        set(value) {
            intVideoFormat = value.rawValue
        }
    }

    // Video fade in/out mode
    static var intFadeMode: Int {
        get { manager.getValue(forKeyPath: \.videos.intFadeMode) }
        set { manager.setValue(newValue, forKeyPath: \.videos.intFadeMode) }
    }

    static var fadeMode: FadeMode {
        get {
            return FadeMode(rawValue: intFadeMode)!
        }
        set(value) {
            intFadeMode = value.rawValue
        }
    }

    // How often should we look for new videos?
    static var intRefreshPeriodicity: Int {
        get { manager.getValue(forKeyPath: \.videos.intRefreshPeriodicity) }
        set { manager.setValue(newValue, forKeyPath: \.videos.intRefreshPeriodicity) }
    }

    static var refreshPeriodicity: RefreshPeriodicity {
        get {
            return RefreshPeriodicity(rawValue: intRefreshPeriodicity)!
        }
        set(value) {
            intRefreshPeriodicity = value.rawValue
        }
    }

    // Allow video skips with right arrow key (on supporting OSes)
    static var allowSkips: Bool {
        get { manager.getValue(forKeyPath: \.videos.allowSkips) }
        set { manager.setValue(newValue, forKeyPath: \.videos.allowSkips) }
    }

    static var enabledSources: [String: Bool] {
        get { manager.getValue(forKeyPath: \.videos.sourcesEnabled) }
        set { manager.setValue(newValue, forKeyPath: \.videos.sourcesEnabled) }
    }

    // Favorites (we use the video ID)
    static var favorites: [String] {
        get { manager.getValue(forKeyPath: \.videos.favorites) }
        set { manager.setValue(newValue, forKeyPath: \.videos.favorites) }
    }

    // Hidden list (same)
    static var hidden: [String] {
        get { manager.getValue(forKeyPath: \.videos.hidden) }
        set { manager.setValue(newValue, forKeyPath: \.videos.hidden) }
    }

    static var vibrance: [String: Double] {
        get { manager.getValue(forKeyPath: \.videos.vibrance) }
        set { manager.setValue(newValue, forKeyPath: \.videos.vibrance) }
    }

    static var durationCache: [String: Double] {
        get { manager.getValue(forKeyPath: \.videos.durationCache) }
        set { manager.setValue(newValue, forKeyPath: \.videos.durationCache) }
    }

    static var playbackSpeed: [String: Float] {
        get { manager.getValue(forKeyPath: \.videos.playbackSpeed) }
        set { manager.setValue(newValue, forKeyPath: \.videos.playbackSpeed) }
    }

    static var globalVibrance: Double {
        get { manager.getValue(forKeyPath: \.videos.globalVibrance) }
        set { manager.setValue(newValue, forKeyPath: \.videos.globalVibrance) }
    }

    static var allowPerVideoVibrance: Bool {
        get { manager.getValue(forKeyPath: \.videos.allowPerVideoVibrance) }
        set { manager.setValue(newValue, forKeyPath: \.videos.allowPerVideoVibrance) }
    }

    static private func defaultLastVideoCheck() -> String {
        let dateFormatter = DateFormatter()
        let current = Date(timeIntervalSinceReferenceDate: -123456789.0)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return dateFormatter.string(from: current)
    }

    static var lastVideoCheck: String {
        get { manager.getValue(forKeyPath: \.videos.lastVideoCheck) }
        set { manager.setValue(newValue, forKeyPath: \.videos.lastVideoCheck) }
    }


    
    static private func intervalSinceLastVideoCheck() -> TimeInterval {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale.init(identifier: "en_GB")
        let dateObj = dateFormatter.date(from: PrefsVideos.lastVideoCheck)!

        // debugLog("Last manifest check : \(dateObj)")

        return dateObj.timeIntervalSinceNow
    }

    static func saveLastVideoCheck() {
        let dateFormatter = DateFormatter()
        let current = Date()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        PrefsVideos.lastVideoCheck = dateFormatter.string(from: current)
    }

    static func shouldCheckForNewVideos() -> Bool {
        if refreshPeriodicity == .never {
            return false
        }

        var dayCheck = 7
        if refreshPeriodicity == .monthly {
            dayCheck = 30
        }

        // debugLog("Interval : \(intervalSinceLastVideoCheck())")
        if Int(intervalSinceLastVideoCheck()) < -dayCheck * 86400 {
            // debugLog("Checking for new videos")
            return true
        } else {
            // debugLog("No need to check for new videos")
            return false
        }
    }
}

//
//  PrefsInfo.swift
//  Aerial
//
//  Created by Guillaume Louel on 16/12/2019.
//  Copyright © 2019 Guillaume Louel. All rights reserved.
//

import Foundation
import ScreenSaver

protocol CommonInfo {
    var isEnabled: Bool { get set }
    var fontName: String { get set }
    var fontSize: Double { get set }
    var corner: InfoCorner { get set }
    var displays: InfoDisplays { get set }
}

// Helper Enums for the common infos
enum InfoCorner: Int, Codable, CaseIterable {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight, screenCenter, random, absTopRight
}

enum InfoDisplays: Int, Codable {
    case allDisplays, mainOnly, secondaryOnly
}

enum InfoTime: Int, Codable {
    case always, tenSeconds
}

enum InfoClockFormat: Int, Codable {
    case tdefault, t24hours, t12hours, custom
}

enum InfoDate: Int, Codable {
    case textual, compact, custom
}

enum InfoIconText: Int, Codable {
    case text, icon
}

enum InfoCountdownMode: Int, Codable {
    case preciseDate, timeOfDay
}

enum InfoLocationMode: Int, Codable {
    case useCurrent, manuallySpecify
}

enum InfoDegree: Int, Codable {
    case celsius, fahrenheit
}

enum InfoIconsWeather: Int, Codable {
    case flat, colorflat, oweather
}

// The various info types available
enum InfoType: String, Codable {
    case location, message, clock, date, battery, updates, weather, countdown, timer, music
}

enum InfoMessageType: Int, Codable {
    case text, shell, textfile
}

enum InfoRefreshPeriodicity: Int, Codable {
    case never, tenseconds, thirtyseconds, oneminute, fiveminutes, tenminutes
}

enum InfoWeatherMode: Int, Codable {
    case current, forecast6hours, forecast3days, forecast5days
}

enum InfoWeatherWind: Int, Codable {
    case kph, mps
}

// swiftlint:disable:next type_body_length
struct PrefsInfo {
    // MARK: - Settings Manager

    private static let manager = ScreensaverSettingsManager.shared

    // MARK: - Info Layer Structures (Nested, for compatibility)

    struct Location: CommonInfo, Codable {
        var isEnabled: Bool
        var fontName: String
        var fontSize: Double
        var corner: InfoCorner
        var displays: InfoDisplays
        var time: InfoTime
    }

    struct Message: CommonInfo, Codable {
        var isEnabled: Bool
        var fontName: String
        var fontSize: Double
        var corner: InfoCorner
        var displays: InfoDisplays
        var message: String
        var shellScript: String
        var textFile: String
        var messageType: InfoMessageType
        var refreshPeriodicity: InfoRefreshPeriodicity
    }

    struct Clock: CommonInfo, Codable {
        var isEnabled: Bool
        var fontName: String
        var fontSize: Double
        var corner: InfoCorner
        var displays: InfoDisplays
        var showSeconds: Bool
        var hideAmPm: Bool
        var clockFormat: InfoClockFormat
    }

    struct IDate: CommonInfo, Codable {
        var isEnabled: Bool
        var fontName: String
        var fontSize: Double
        var corner: InfoCorner
        var displays: InfoDisplays
        var format: InfoDate
        var withYear: Bool
    }

    struct Weather: CommonInfo, Codable {
        var isEnabled: Bool
        var fontName: String
        var fontSize: Double
        var corner: InfoCorner
        var displays: InfoDisplays
        var locationMode: InfoLocationMode
        var locationString: String
        var degree: InfoDegree
        var icons: InfoIconsWeather
        var mode: InfoWeatherMode
        var showHumidity: Bool
        var showWind: Bool
        var showCity: Bool
    }

    struct Battery: CommonInfo, Codable {
        var isEnabled: Bool
        var fontName: String
        var fontSize: Double
        var corner: InfoCorner
        var displays: InfoDisplays
        var mode: InfoIconText
        var disableWhenFull: Bool
    }

    struct Updates: CommonInfo, Codable {
        var isEnabled: Bool
        var fontName: String
        var fontSize: Double
        var corner: InfoCorner
        var displays: InfoDisplays
        var betaReset: Bool // This is useless, just to reload default settings for users of 1.7.2 early betas
    }

    struct Countdown: CommonInfo, Codable {
        var isEnabled: Bool
        var fontName: String
        var fontSize: Double
        var corner: InfoCorner
        var displays: InfoDisplays
        var mode: InfoCountdownMode
        var targetDate: Date
        var enforceInterval: Bool
        var triggerDate: Date
        var showSeconds: Bool
    }

    struct Timer: CommonInfo, Codable {
        var isEnabled: Bool
        var fontName: String
        var fontSize: Double
        var corner: InfoCorner
        var displays: InfoDisplays
        var duration: Date
        var showSeconds: Bool
        var disableWhenElapsed: Bool
        var replaceWithMessage: Bool
        var customMessage: String
    }

    struct Music: CommonInfo, Codable {
        var isEnabled: Bool
        var fontName: String
        var fontSize: Double
        var corner: InfoCorner
        var displays: InfoDisplays
    }

    // MARK: - Info Layer Settings

    // Our array of Info layers. User can reorder the array, and we may periodically add new Info types
    static var layers: [InfoType] {
        get {
            let stringLayers = manager.getValue(forKeyPath: \.info.layers)
            return stringLayers.compactMap { InfoType(rawValue: $0) }
        }
        set {
            let stringLayers = newValue.map { $0.rawValue }
            manager.setValue(stringLayers, forKeyPath: \.info.layers)
        }
    }

    // Location information
    static var location: Location {
        get {
            let info = manager.getValue(forKeyPath: \.info.location)
            return Location(isEnabled: info.isEnabled,
                          fontName: info.fontName,
                          fontSize: info.fontSize,
                          corner: InfoCorner(rawValue: info.corner)!,
                          displays: InfoDisplays(rawValue: info.displays)!,
                          time: InfoTime(rawValue: info.time)!)
        }
        set {
            let info = InfoLocation(isEnabled: newValue.isEnabled,
                                   fontName: newValue.fontName,
                                   fontSize: newValue.fontSize,
                                   corner: newValue.corner.rawValue,
                                   displays: newValue.displays.rawValue,
                                   time: newValue.time.rawValue)
            manager.setValue(info, forKeyPath: \.info.location)
        }
    }

    // Custom string message
    static var message: Message {
        get {
            let info = manager.getValue(forKeyPath: \.info.message)
            return Message(isEnabled: info.isEnabled,
                          fontName: info.fontName,
                          fontSize: info.fontSize,
                          corner: InfoCorner(rawValue: info.corner)!,
                          displays: InfoDisplays(rawValue: info.displays)!,
                          message: info.message,
                          shellScript: info.shellScript,
                          textFile: info.textFile,
                          messageType: InfoMessageType(rawValue: info.messageType)!,
                          refreshPeriodicity: InfoRefreshPeriodicity(rawValue: info.refreshPeriodicity)!)
        }
        set {
            let info = InfoMessage(isEnabled: newValue.isEnabled,
                                  fontName: newValue.fontName,
                                  fontSize: newValue.fontSize,
                                  corner: newValue.corner.rawValue,
                                  displays: newValue.displays.rawValue,
                                  message: newValue.message,
                                  shellScript: newValue.shellScript,
                                  textFile: newValue.textFile,
                                  messageType: newValue.messageType.rawValue,
                                  refreshPeriodicity: newValue.refreshPeriodicity.rawValue)
            manager.setValue(info, forKeyPath: \.info.message)
        }
    }

    // Clock
    static var clock: Clock {
        get {
            let info = manager.getValue(forKeyPath: \.info.clock)
            return Clock(isEnabled: info.isEnabled,
                        fontName: info.fontName,
                        fontSize: info.fontSize,
                        corner: InfoCorner(rawValue: info.corner)!,
                        displays: InfoDisplays(rawValue: info.displays)!,
                        showSeconds: info.showSeconds,
                        hideAmPm: info.hideAmPm,
                        clockFormat: InfoClockFormat(rawValue: info.clockFormat)!)
        }
        set {
            let info = InfoClock(isEnabled: newValue.isEnabled,
                                fontName: newValue.fontName,
                                fontSize: newValue.fontSize,
                                corner: newValue.corner.rawValue,
                                displays: newValue.displays.rawValue,
                                showSeconds: newValue.showSeconds,
                                hideAmPm: newValue.hideAmPm,
                                clockFormat: newValue.clockFormat.rawValue)
            manager.setValue(info, forKeyPath: \.info.clock)
        }
    }

    // Date
    static var date: IDate {
        get {
            let info = manager.getValue(forKeyPath: \.info.date)
            return IDate(isEnabled: info.isEnabled,
                        fontName: info.fontName,
                        fontSize: info.fontSize,
                        corner: InfoCorner(rawValue: info.corner)!,
                        displays: InfoDisplays(rawValue: info.displays)!,
                        format: InfoDate(rawValue: info.format)!,
                        withYear: info.withYear)
        }
        set {
            let info = InfoDateLayer(isEnabled: newValue.isEnabled,
                                    fontName: newValue.fontName,
                                    fontSize: newValue.fontSize,
                                    corner: newValue.corner.rawValue,
                                    displays: newValue.displays.rawValue,
                                    format: newValue.format.rawValue,
                                    withYear: newValue.withYear)
            manager.setValue(info, forKeyPath: \.info.date)
        }
    }

    // Battery
    static var battery: Battery {
        get {
            let info = manager.getValue(forKeyPath: \.info.battery)
            return Battery(isEnabled: info.isEnabled,
                          fontName: info.fontName,
                          fontSize: info.fontSize,
                          corner: InfoCorner(rawValue: info.corner)!,
                          displays: InfoDisplays(rawValue: info.displays)!,
                          mode: InfoIconText(rawValue: info.mode)!,
                          disableWhenFull: info.disableWhenFull)
        }
        set {
            let info = InfoBattery(isEnabled: newValue.isEnabled,
                                  fontName: newValue.fontName,
                                  fontSize: newValue.fontSize,
                                  corner: newValue.corner.rawValue,
                                  displays: newValue.displays.rawValue,
                                  mode: newValue.mode.rawValue,
                                  disableWhenFull: newValue.disableWhenFull)
            manager.setValue(info, forKeyPath: \.info.battery)
        }
    }

    // Updates
    static var updates: Updates {
        get {
            let info = manager.getValue(forKeyPath: \.info.updates)
            return Updates(isEnabled: info.isEnabled,
                          fontName: info.fontName,
                          fontSize: info.fontSize,
                          corner: InfoCorner(rawValue: info.corner)!,
                          displays: InfoDisplays(rawValue: info.displays)!,
                          betaReset: info.betaReset)
        }
        set {
            let info = InfoUpdates(isEnabled: newValue.isEnabled,
                                  fontName: newValue.fontName,
                                  fontSize: newValue.fontSize,
                                  corner: newValue.corner.rawValue,
                                  displays: newValue.displays.rawValue,
                                  betaReset: newValue.betaReset)
            manager.setValue(info, forKeyPath: \.info.updates)
        }
    }

    // Weather
    static var weather: Weather {
        get {
            let info = manager.getValue(forKeyPath: \.info.weather)
            return Weather(isEnabled: info.isEnabled,
                          fontName: info.fontName,
                          fontSize: info.fontSize,
                          corner: InfoCorner(rawValue: info.corner)!,
                          displays: InfoDisplays(rawValue: info.displays)!,
                          locationMode: InfoLocationMode(rawValue: info.locationMode)!,
                          locationString: info.locationString,
                          degree: InfoDegree(rawValue: info.degree)!,
                          icons: InfoIconsWeather(rawValue: info.icons)!,
                          mode: InfoWeatherMode(rawValue: info.mode)!,
                          showHumidity: info.showHumidity,
                          showWind: info.showWind,
                          showCity: info.showCity)
        }
        set {
            let info = InfoWeather(isEnabled: newValue.isEnabled,
                                  fontName: newValue.fontName,
                                  fontSize: newValue.fontSize,
                                  corner: newValue.corner.rawValue,
                                  displays: newValue.displays.rawValue,
                                  locationMode: newValue.locationMode.rawValue,
                                  locationString: newValue.locationString,
                                  degree: newValue.degree.rawValue,
                                  icons: newValue.icons.rawValue,
                                  mode: newValue.mode.rawValue,
                                  showHumidity: newValue.showHumidity,
                                  showWind: newValue.showWind,
                                  showCity: newValue.showCity)
            manager.setValue(info, forKeyPath: \.info.weather)
        }
    }

    // Weather wind mode
    static var intWeatherWindMode: Int {
        get { manager.getValue(forKeyPath: \.info.intWeatherWindMode) }
        set { manager.setValue(newValue, forKeyPath: \.info.intWeatherWindMode) }
    }

    static var weatherWindMode: InfoWeatherWind {
        get {
            return InfoWeatherWind(rawValue: intWeatherWindMode)!
        }
        set(value) {
            intWeatherWindMode = value.rawValue
        }
    }

    // Music
    static var music: Music {
        get {
            let info = manager.getValue(forKeyPath: \.info.music)
            return Music(isEnabled: info.isEnabled,
                        fontName: info.fontName,
                        fontSize: info.fontSize,
                        corner: InfoCorner(rawValue: info.corner)!,
                        displays: InfoDisplays(rawValue: info.displays)!)
        }
        set {
            let info = InfoMusic(isEnabled: newValue.isEnabled,
                                fontName: newValue.fontName,
                                fontSize: newValue.fontSize,
                                corner: newValue.corner.rawValue,
                                displays: newValue.displays.rawValue)
            manager.setValue(info, forKeyPath: \.info.music)
        }
    }

    // Apple Music storefront to be used
    static var appleMusicStoreFront: String {
        get { manager.getValue(forKeyPath: \.info.appleMusicStoreFront) }
        set { manager.setValue(newValue, forKeyPath: \.info.appleMusicStoreFront) }
    }

    // Music provider
    static var musicProvider: String {
        get { manager.getValue(forKeyPath: \.info.musicProvider) }
        set { manager.setValue(newValue, forKeyPath: \.info.musicProvider) }
    }

    // Countdown
    static var countdown: Countdown {
        get {
            let info = manager.getValue(forKeyPath: \.info.countdown)
            return Countdown(isEnabled: info.isEnabled,
                            fontName: info.fontName,
                            fontSize: info.fontSize,
                            corner: InfoCorner(rawValue: info.corner)!,
                            displays: InfoDisplays(rawValue: info.displays)!,
                            mode: InfoCountdownMode(rawValue: info.mode)!,
                            targetDate: info.targetDate,
                            enforceInterval: info.enforceInterval,
                            triggerDate: info.triggerDate,
                            showSeconds: info.showSeconds)
        }
        set {
            let info = InfoCountdown(isEnabled: newValue.isEnabled,
                                    fontName: newValue.fontName,
                                    fontSize: newValue.fontSize,
                                    corner: newValue.corner.rawValue,
                                    displays: newValue.displays.rawValue,
                                    mode: newValue.mode.rawValue,
                                    targetDate: newValue.targetDate,
                                    enforceInterval: newValue.enforceInterval,
                                    triggerDate: newValue.triggerDate,
                                    showSeconds: newValue.showSeconds)
            manager.setValue(info, forKeyPath: \.info.countdown)
        }
    }

    // Timer
    static var timer: Timer {
        get {
            let info = manager.getValue(forKeyPath: \.info.timer)
            return Timer(isEnabled: info.isEnabled,
                        fontName: info.fontName,
                        fontSize: info.fontSize,
                        corner: InfoCorner(rawValue: info.corner)!,
                        displays: InfoDisplays(rawValue: info.displays)!,
                        duration: info.duration,
                        showSeconds: info.showSeconds,
                        disableWhenElapsed: info.disableWhenElapsed,
                        replaceWithMessage: info.replaceWithMessage,
                        customMessage: info.customMessage)
        }
        set {
            let info = InfoTimer(isEnabled: newValue.isEnabled,
                                fontName: newValue.fontName,
                                fontSize: newValue.fontSize,
                                corner: newValue.corner.rawValue,
                                displays: newValue.displays.rawValue,
                                duration: newValue.duration,
                                showSeconds: newValue.showSeconds,
                                disableWhenElapsed: newValue.disableWhenElapsed,
                                replaceWithMessage: newValue.replaceWithMessage,
                                customMessage: newValue.customMessage)
            manager.setValue(info, forKeyPath: \.info.timer)
        }
    }

    static var customDateFormat: String {
        get { manager.getValue(forKeyPath: \.info.customDateFormat) }
        set { manager.setValue(newValue, forKeyPath: \.info.customDateFormat) }
    }

    static var customTimeFormat: String {
        get { manager.getValue(forKeyPath: \.info.customTimeFormat) }
        set { manager.setValue(newValue, forKeyPath: \.info.customTimeFormat) }
    }

    // MARK: - Advanced text settings

    // Text fade in/out mode
    static var intFadeModeText: Int {
        get { manager.getValue(forKeyPath: \.info.intFadeModeText) }
        set { manager.setValue(newValue, forKeyPath: \.info.intFadeModeText) }
    }

    static var fadeModeText: FadeMode {
        get {
            return FadeMode(rawValue: intFadeModeText)!
        }
        set(value) {
            intFadeModeText = value.rawValue
        }
    }

    // MARK: - Advanced Text Settings (migrated to JSON storage)

    // Fast rendering mode
    static var highQualityTextRendering: Bool {
        get { manager.getValue(forKeyPath: \.info.highQualityTextRendering) }
        set { manager.setValue(newValue, forKeyPath: \.info.highQualityTextRendering) }
    }

    // Override margins
    static var overrideMargins: Bool {
        get { manager.getValue(forKeyPath: \.info.overrideMargins) }
        set { manager.setValue(newValue, forKeyPath: \.info.overrideMargins) }
    }

    // Hide overlays under Companion
    static var hideUnderCompanion: Bool {
        get { manager.getValue(forKeyPath: \.info.hideUnderCompanion) }
        set { manager.setValue(newValue, forKeyPath: \.info.hideUnderCompanion) }
    }

    static var marginX: Int {
        get { manager.getValue(forKeyPath: \.info.marginX) }
        set { manager.setValue(newValue, forKeyPath: \.info.marginX) }
    }

    static var marginY: Int {
        get { manager.getValue(forKeyPath: \.info.marginY) }
        set { manager.setValue(newValue, forKeyPath: \.info.marginY) }
    }

    // MARK: - Shadows

    static var shadowRadius: Int {
        get { manager.getValue(forKeyPath: \.info.shadowRadius) }
        set { manager.setValue(newValue, forKeyPath: \.info.shadowRadius) }
    }

    static var shadowOpacity: Float {
        get { manager.getValue(forKeyPath: \.info.shadowOpacity) }
        set { manager.setValue(newValue, forKeyPath: \.info.shadowOpacity) }
    }

    static var shadowOffsetX: CGFloat {
        get { CGFloat(manager.getValue(forKeyPath: \.info.shadowOffsetX)) }
        set { manager.setValue(Double(newValue), forKeyPath: \.info.shadowOffsetX) }
    }

    static var shadowOffsetY: CGFloat {
        get { CGFloat(manager.getValue(forKeyPath: \.info.shadowOffsetY)) }
        set { manager.setValue(Double(newValue), forKeyPath: \.info.shadowOffsetY) }
    }

    static func isMacOS11() -> Bool {
        if #available(macOS 11.0, *) {
            return true
        } else {
            return false
        }
    }

    // MARK: - Helpers
    // Helper to quickly access a given struct (read-only as we return a copy of the struct)
    static func ofType(_ type: InfoType) -> CommonInfo {
        switch type {
        case .location:
            return location
        case .message:
            return message
        case .clock:
            return clock
        case .date:
            return date
        case .battery:
            return battery
        case .updates:
            return updates
        case .weather:
            return weather
        case .countdown:
            return countdown
        case .timer:
            return timer
        case .music:
            return music
        }
    }

    // Helpers to store the value for the common properties of all info layers
    static func setEnabled(_ type: InfoType, value: Bool) {
        switch type {
        case .location:
            location.isEnabled = value
        case .message:
            message.isEnabled = value
        case .clock:
            clock.isEnabled = value
        case .date:
            date.isEnabled = value
        case .battery:
            battery.isEnabled = value
        case .updates:
            updates.isEnabled = value
        case .weather:
            weather.isEnabled = value
        case .countdown:
            countdown.isEnabled = value
        case .timer:
            timer.isEnabled = value
        case .music:
            music.isEnabled = value
        }
    }

    static func setFontName(_ type: InfoType, name: String) {
        switch type {
        case .location:
            location.fontName = name
        case .message:
            message.fontName = name
        case .clock:
            clock.fontName = name
        case .date:
            date.fontName = name
        case .battery:
            battery.fontName = name
        case .updates:
            updates.fontName = name
        case .weather:
            weather.fontName = name
        case .countdown:
            countdown.fontName = name
        case .timer:
            timer.fontName = name
        case .music:
            music.fontName = name
        }
    }

    static func setFontSize(_ type: InfoType, size: Double) {
        switch type {
        case .location:
            location.fontSize = size
        case .message:
            message.fontSize = size
        case .clock:
            clock.fontSize = size
        case .date:
            date.fontSize = size
        case .battery:
            battery.fontSize = size
        case .updates:
            updates.fontSize = size
        case .weather:
            weather.fontSize = size
        case .countdown:
            countdown.fontSize = size
        case .timer:
            timer.fontSize = size
        case .music:
            music.fontSize = size
        }
    }

    static func setCorner(_ type: InfoType, corner: InfoCorner) {
        switch type {
        case .location:
            location.corner = corner
        case .message:
            message.corner = corner
        case .clock:
            clock.corner = corner
        case .date:
            date.corner = corner
        case .battery:
            battery.corner = corner
        case .updates:
            updates.corner = corner
        case .weather:
            weather.corner = corner
        case .countdown:
            countdown.corner = corner
        case .timer:
            timer.corner = corner
        case .music:
            music.corner = corner
        }

    }
    static func setDisplayMode(_ type: InfoType, mode: InfoDisplays) {
        switch type {
        case .location:
            location.displays = mode
        case .message:
            message.displays = mode
        case .clock:
            clock.displays = mode
        case .date:
            date.displays = mode
        case .battery:
            battery.displays = mode
        case .updates:
            updates.displays = mode
        case .weather:
            weather.displays = mode
        case .countdown:
            countdown.displays = mode
        case .timer:
            timer.displays = mode
        case .music:
            music.displays = mode
        }
    }

    // This may be a temp workaround, will depend on where it goes
    // We periodically add new types so we must add them
    static func updateLayerList() {
        if !PrefsInfo.layers.contains(.battery) {
            PrefsInfo.layers.append(.battery)
        }

        if !PrefsInfo.layers.contains(.countdown) {
            PrefsInfo.layers.append(.countdown)
        }

        if !PrefsInfo.layers.contains(.timer) {
            PrefsInfo.layers.append(.timer)
        }

        if !PrefsInfo.layers.contains(.date) {
            PrefsInfo.layers.append(.date)
        }

        if !PrefsInfo.layers.contains(.weather) {
            PrefsInfo.layers.append(.weather)
        }

        if !PrefsInfo.layers.contains(.music) {
            PrefsInfo.layers.append(.music)
        }

        // Annnd for backward compatibility with 1.7.2 betas, remove the updates that was once here ;)
        if PrefsInfo.layers.contains(.updates) {
            PrefsInfo.layers.remove(at: PrefsInfo.layers.firstIndex(of: .updates)!)
        }
    }
}

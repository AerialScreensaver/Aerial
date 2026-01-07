//
//  ScreensaverSettings.swift
//  Aerial
//
//  Consolidated screensaver settings structure for JSON storage
//

import Foundation

// MARK: - Main Settings Structure

/// Consolidated settings structure for Aerial Screensaver
/// Replaces individual UserDefaults entries with a single JSON file at /Users/Shared/Aerial/screensaver.json
struct ScreensaverSettings: Codable {
    var videos: VideoSettings
    var cache: CacheSettings
    var info: InfoSettings
    var displays: DisplaySettings
    var displaysDesktop: DisplaySettings  // Desktop mode uses same structure
    var time: TimeSettings
    var advanced: AdvancedSettings

    // MARK: - Defaults

    /// Default settings for fresh install
    static let `default` = ScreensaverSettings(
        videos: .default,
        cache: .default,
        info: .default,
        displays: .default,
        displaysDesktop: .default,
        time: .default,
        advanced: .default
    )

    // MARK: - File Location

    /// URL for the screensaver settings JSON file
    static var fileURL: URL {
        let baseURL = URL(fileURLWithPath: AerialPaths.baseDirectory)
        return baseURL.appendingPathComponent("screensaver.json")
    }
}

// MARK: - Video Settings

struct VideoSettings: Codable {
    // Playback modes
    var intNewShouldPlay: Int
    var intShouldPlay: Int  // Deprecated in v2.5
    var newShouldPlayString: [String]
    var shouldPlayString: String  // Deprecated in v2.5

    // Battery behavior
    var intOnBatteryMode: Int

    // Video format
    var intVideoFormat: Int

    // Fade mode
    var intFadeMode: Int

    // Refresh periodicity
    var intRefreshPeriodicity: Int

    // Features
    var allowSkips: Bool
    var sourcesEnabled: [String: Bool]

    // Video management
    var favorites: [String]
    var hidden: [String]

    // Vibrance
    var vibrance: [String: Double]
    var globalVibrance: Double
    var allowPerVideoVibrance: Bool

    // Caches
    var durationCache: [String: Double]
    var playbackSpeed: [String: Float]

    // Last check date
    var lastVideoCheck: String

    static let `default` = VideoSettings(
        intNewShouldPlay: 0,  // NewShouldPlay.location
        intShouldPlay: 0,  // ShouldPlay.everything
        newShouldPlayString: [],
        shouldPlayString: "",
        intOnBatteryMode: 0,  // OnBatteryMode.keepEnabled
        intVideoFormat: 0,  // VideoFormat.v1080pH264
        intFadeMode: 2,  // FadeMode.t1
        intRefreshPeriodicity: 1,  // RefreshPeriodicity.monthly
        allowSkips: true,
        sourcesEnabled: ["macOS 26": true, "tvOS 16": false, "tvOS 13": false],
        favorites: [],
        hidden: [],
        vibrance: [:],
        globalVibrance: 0,
        allowPerVideoVibrance: false,
        durationCache: [:],
        playbackSpeed: [:],
        lastVideoCheck: {
            let dateFormatter = DateFormatter()
            let current = Date(timeIntervalSinceReferenceDate: -123456789.0)
            dateFormatter.dateFormat = "yyyy-MM-dd"
            return dateFormatter.string(from: current)
        }()
    )
}

// MARK: - Cache Settings

struct CacheSettings: Codable {
    var enableManagement: Bool
    var cacheLimit: Double
    var intCachePeriodicity: Int
    var restrictOnWiFi: Bool
    var allowedNetworks: [String]
    var showBackgroundDownloads: Bool
    var overrideCache: Bool
    var cacheBookmarkData: Data?
    var cachePath: String?
    var supportBookmarkData: Data?
    var supportPath: String?

    static let `default` = CacheSettings(
        enableManagement: true,
        cacheLimit: 5,
        intCachePeriodicity: 3,  // CachePeriodicity.never
        restrictOnWiFi: false,
        allowedNetworks: [],
        showBackgroundDownloads: false,
        overrideCache: false,
        cacheBookmarkData: nil,
        cachePath: nil,
        supportBookmarkData: nil,
        supportPath: nil
    )
}

// MARK: - Info Settings

/// Info layer settings - these are the overlays shown on the screensaver
struct InfoSettings: Codable {
    var layers: [String]  // List of enabled info types (stored as strings for Codable)

    // Individual layer settings
    var location: InfoLocation
    var message: InfoMessage
    var clock: InfoClock
    var date: InfoDateLayer
    var weather: InfoWeather
    var battery: InfoBattery
    var updates: InfoUpdates
    var countdown: InfoCountdown
    var timer: InfoTimer
    var music: InfoMusic

    // Additional info settings
    var intWeatherWindMode: Int
    var appleMusicStoreFront: String
    var musicProvider: String
    var customDateFormat: String
    var customTimeFormat: String
    var intFadeModeText: Int

    static let `default` = InfoSettings(
        layers: ["message", "clock", "date", "location", "battery", "updates", "weather", "countdown", "timer"],
        location: InfoLocation.default,
        message: InfoMessage.default,
        clock: InfoClock.default,
        date: InfoDateLayer.default,
        weather: InfoWeather.default,
        battery: InfoBattery.default,
        updates: InfoUpdates.default,
        countdown: InfoCountdown.default,
        timer: InfoTimer.default,
        music: InfoMusic.default,
        intWeatherWindMode: 0,  // InfoWeatherWind.kph
        appleMusicStoreFront: "United States",
        musicProvider: "Apple Music",
        customDateFormat: "",
        customTimeFormat: "",
        intFadeModeText: 2  // FadeMode.t1
    )
}

// MARK: - Info Layer Structures

struct InfoLocation: Codable {
    var isEnabled: Bool
    var fontName: String
    var fontSize: Double
    var corner: Int  // InfoCorner raw value
    var displays: Int  // InfoDisplays raw value
    var time: Int  // InfoTime raw value

    static let `default` = InfoLocation(
        isEnabled: true,
        fontName: "Helvetica Neue Medium",
        fontSize: 28,
        corner: 8,  // .random
        displays: 0,  // .allDisplays
        time: 0  // .always
    )
}

struct InfoMessage: Codable {
    var isEnabled: Bool
    var fontName: String
    var fontSize: Double
    var corner: Int
    var displays: Int
    var message: String
    var shellScript: String
    var textFile: String
    var messageType: Int  // InfoMessageType raw value
    var refreshPeriodicity: Int  // InfoRefreshPeriodicity raw value

    static let `default` = InfoMessage(
        isEnabled: false,
        fontName: "Helvetica Neue Medium",
        fontSize: 20,
        corner: 1,  // .topCenter
        displays: 0,
        message: "Hello there!",
        shellScript: "",
        textFile: "",
        messageType: 0,  // .text
        refreshPeriodicity: 5  // .tenminutes
    )
}

struct InfoClock: Codable {
    var isEnabled: Bool
    var fontName: String
    var fontSize: Double
    var corner: Int
    var displays: Int
    var showSeconds: Bool
    var hideAmPm: Bool
    var clockFormat: Int  // InfoClockFormat raw value

    static let `default` = InfoClock(
        isEnabled: true,
        fontName: "Helvetica Neue Medium",
        fontSize: 50,
        corner: 3,  // .bottomLeft
        displays: 0,
        showSeconds: true,
        hideAmPm: false,
        clockFormat: 0  // .tdefault
    )
}

struct InfoDateLayer: Codable {
    var isEnabled: Bool
    var fontName: String
    var fontSize: Double
    var corner: Int
    var displays: Int
    var format: Int  // InfoDate enum raw value
    var withYear: Bool

    static let `default` = InfoDateLayer(
        isEnabled: false,
        fontName: "Helvetica Neue Thin",
        fontSize: 25,
        corner: 3,  // .bottomLeft
        displays: 0,
        format: 0,  // .textual
        withYear: false
    )
}

struct InfoWeather: Codable {
    var isEnabled: Bool
    var fontName: String
    var fontSize: Double
    var corner: Int
    var displays: Int
    var locationMode: Int  // InfoLocationMode raw value
    var locationString: String
    var degree: Int  // InfoDegree raw value
    var icons: Int  // InfoIconsWeather raw value
    var mode: Int  // InfoWeatherMode raw value
    var showHumidity: Bool
    var showWind: Bool
    var showCity: Bool

    static let `default` = InfoWeather(
        isEnabled: false,
        fontName: "Helvetica Neue Medium",
        fontSize: 40,
        corner: 2,  // .topRight
        displays: 0,
        locationMode: 1,  // .manuallySpecify
        locationString: "",
        degree: 0,  // .celsius
        icons: 0,  // .flat
        mode: 0,  // .current
        showHumidity: true,
        showWind: true,
        showCity: true
    )
}

struct InfoBattery: Codable {
    var isEnabled: Bool
    var fontName: String
    var fontSize: Double
    var corner: Int
    var displays: Int
    var mode: Int  // InfoIconText raw value
    var disableWhenFull: Bool

    static let `default` = InfoBattery(
        isEnabled: false,
        fontName: "Helvetica Neue Medium",
        fontSize: 20,
        corner: 2,  // .topRight
        displays: 0,
        mode: 1,  // .icon
        disableWhenFull: false
    )
}

struct InfoUpdates: Codable {
    var isEnabled: Bool
    var fontName: String
    var fontSize: Double
    var corner: Int
    var displays: Int
    var betaReset: Bool

    static let `default` = InfoUpdates(
        isEnabled: true,
        fontName: "Helvetica Neue Medium",
        fontSize: 20,
        corner: 2,  // .topRight
        displays: 0,
        betaReset: true
    )
}

struct InfoCountdown: Codable {
    var isEnabled: Bool
    var fontName: String
    var fontSize: Double
    var corner: Int
    var displays: Int
    var mode: Int  // InfoCountdownMode raw value
    var targetDate: Date
    var enforceInterval: Bool
    var triggerDate: Date
    var showSeconds: Bool

    static let `default` = InfoCountdown(
        isEnabled: false,
        fontName: "Helvetica Neue Medium",
        fontSize: 100,
        corner: 6,  // .screenCenter
        displays: 0,
        mode: 1,  // .timeOfDay
        targetDate: Date(),
        enforceInterval: false,
        triggerDate: Date(),
        showSeconds: true
    )
}

struct InfoTimer: Codable {
    var isEnabled: Bool
    var fontName: String
    var fontSize: Double
    var corner: Int
    var displays: Int
    var duration: Date
    var showSeconds: Bool
    var disableWhenElapsed: Bool
    var replaceWithMessage: Bool
    var customMessage: String

    static let `default` = InfoTimer(
        isEnabled: false,
        fontName: "Helvetica Neue Medium",
        fontSize: 100,
        corner: 6,  // .screenCenter
        displays: 0,
        duration: Date(timeIntervalSince1970: 300),
        showSeconds: true,
        disableWhenElapsed: true,
        replaceWithMessage: false,
        customMessage: ""
    )
}

struct InfoMusic: Codable {
    var isEnabled: Bool
    var fontName: String
    var fontSize: Double
    var corner: Int
    var displays: Int

    static let `default` = InfoMusic(
        isEnabled: true,
        fontName: "Helvetica Neue Medium",
        fontSize: 20,
        corner: 2,  // .topRight
        displays: 0
    )
}

// MARK: - Display Settings

struct DisplaySettings: Codable {
    // Display modes
    var intDisplayMode: Int
    var intViewingMode: Int
    var intAspectMode: Int

    // Margins
    var displayMarginsAdvanced: Bool
    var horizontalMargin: Double
    var verticalMargin: Double
    var advancedMargins: String

    // Dimming (only for screensaver, not desktop)
    var dimBrightness: Bool?
    var dimOnlyAtNight: Bool?
    var dimOnlyOnBattery: Bool?
    var overrideDimInMinutes: Bool?
    var startDim: Double?
    var endDim: Double?
    var dimInMinutes: Int?

    static let `default` = DisplaySettings(
        intDisplayMode: 0,  // DisplayMode.allDisplays
        intViewingMode: 0,  // ViewingMode.independent
        intAspectMode: 0,  // AspectMode.fill
        displayMarginsAdvanced: false,
        horizontalMargin: 0,
        verticalMargin: 0,
        advancedMargins: "",
        dimBrightness: false,
        dimOnlyAtNight: false,
        dimOnlyOnBattery: false,
        overrideDimInMinutes: false,
        startDim: 0.5,
        endDim: 0.0,
        dimInMinutes: 30
    )
}

// MARK: - Time Settings

struct TimeSettings: Codable {
    var intTimeMode: Int
    var manualSunrise: String
    var manualSunset: String
    var latitude: String
    var longitude: String
    var intSolarMode: Int
    var sunEventWindow: Int
    var darkModeNightOverride: Bool
    var cachedLatitude: Double
    var cachedLongitude: Double
    var geocodedString: String

    static let `default` = TimeSettings(
        intTimeMode: 0,  // TimeMode.disabled
        manualSunrise: "09:00",
        manualSunset: "19:00",
        latitude: "",
        longitude: "",
        intSolarMode: 1,  // SolarMode.official
        sunEventWindow: 60 * 180,
        darkModeNightOverride: false,
        cachedLatitude: 0,
        cachedLongitude: 0,
        geocodedString: ""
    )
}

// MARK: - Advanced Settings

struct AdvancedSettings: Codable {
    var muteSound: Bool
    var muteGlobalSound: Bool
    var autoPlayPreviews: Bool
    var firstTimeSetup: Bool
    var favorOrientation: Bool
    var invertColors: Bool
    var debugMode: Bool
    var ciOverrideLanguage: String
    var newDisplayDict: [String: Bool]

    static let `default` = AdvancedSettings(
        muteSound: true,
        muteGlobalSound: false,
        autoPlayPreviews: true,
        firstTimeSetup: false,
        favorOrientation: true,
        invertColors: false,
        debugMode: false,
        ciOverrideLanguage: "",
        newDisplayDict: [:]
    )
}

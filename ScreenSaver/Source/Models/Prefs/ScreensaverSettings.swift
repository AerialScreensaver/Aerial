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
    var displays: DisplaySettings
    var displaysDesktop: DisplaySettings  // Desktop mode uses same structure
    var time: TimeSettings
    var advanced: AdvancedSettings
    var updatesPrefs: UpdatesSettings

    // MARK: - Defaults

    /// Default settings for fresh install
    static let `default` = ScreensaverSettings(
        videos: .default,
        cache: .default,
        displays: .default,
        displaysDesktop: .default,
        time: .default,
        advanced: .default,
        updatesPrefs: .default
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
    var newShouldPlayString: [String]

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

    // Time-of-day override per video
    var timeOfDayOverride: [String: String]

    // Per-video format override (stores VideoFormat.rawValue).
    // When set, wins over the global `intVideoFormat` for that
    // specific video id — playback, cache path, and download target
    // all resolve through `AerialVideo.preferredFormat()`.
    var videoFormatOverride: [String: Int]

    // Last check date
    var lastVideoCheck: String

    static let `default` = VideoSettings(
        intNewShouldPlay: 0,  // NewShouldPlay.location
        newShouldPlayString: [],
        intOnBatteryMode: 0,  // OnBatteryMode.keepEnabled
        intVideoFormat: 5,  // VideoFormat.v4KSDR240
        intFadeMode: 0,  // FadeMode.disabled
        intRefreshPeriodicity: 0,  // RefreshPeriodicity.weekly
        allowSkips: true,
        sourcesEnabled: ["macOS 26": true, "tvOS 26": false, "tvOS 13": false],
        favorites: [],
        hidden: [],
        vibrance: [:],
        globalVibrance: 0,
        allowPerVideoVibrance: false,
        durationCache: [:],
        playbackSpeed: [:],
        timeOfDayOverride: [:],
        videoFormatOverride: [:],
        lastVideoCheck: {
            let dateFormatter = DateFormatter()
            let current = Date(timeIntervalSinceReferenceDate: -123456789.0)
            dateFormatter.dateFormat = "yyyy-MM-dd"
            return dateFormatter.string(from: current)
        }()
    )
}

extension VideoSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intNewShouldPlay = try container.decode(Int.self, forKey: .intNewShouldPlay)
        newShouldPlayString = try container.decode([String].self, forKey: .newShouldPlayString)
        intOnBatteryMode = try container.decode(Int.self, forKey: .intOnBatteryMode)
        intVideoFormat = try container.decode(Int.self, forKey: .intVideoFormat)
        intFadeMode = try container.decode(Int.self, forKey: .intFadeMode)
        intRefreshPeriodicity = try container.decode(Int.self, forKey: .intRefreshPeriodicity)
        allowSkips = try container.decode(Bool.self, forKey: .allowSkips)
        sourcesEnabled = try container.decode([String: Bool].self, forKey: .sourcesEnabled)
        favorites = try container.decode([String].self, forKey: .favorites)
        hidden = try container.decode([String].self, forKey: .hidden)
        vibrance = try container.decode([String: Double].self, forKey: .vibrance)
        globalVibrance = try container.decode(Double.self, forKey: .globalVibrance)
        allowPerVideoVibrance = try container.decode(Bool.self, forKey: .allowPerVideoVibrance)
        durationCache = try container.decode([String: Double].self, forKey: .durationCache)
        playbackSpeed = try container.decode([String: Float].self, forKey: .playbackSpeed)
        timeOfDayOverride = try container.decodeIfPresent([String: String].self, forKey: .timeOfDayOverride) ?? [:]
        videoFormatOverride = try container.decodeIfPresent([String: Int].self, forKey: .videoFormatOverride) ?? [:]
        lastVideoCheck = try container.decode(String.self, forKey: .lastVideoCheck)
    }
}

// MARK: - Cache Settings

struct CacheSettings: Codable {
    var enableManagement: Bool
    var cacheLimit: Double
    var intCachePeriodicity: Int
    var restrictOnWiFi: Bool
    var allowedNetworks: [String]
    var overrideCache: Bool
    var cachePath: String?
    var lastRotationRun: Date?

    static let `default` = CacheSettings(
        enableManagement: true,
        cacheLimit: 20,
        intCachePeriodicity: 1,  // CachePeriodicity.weekly
        restrictOnWiFi: false,
        allowedNetworks: [],
        overrideCache: false,
        cachePath: nil,
        lastRotationRun: nil
    )

    // Custom decoder to handle old JSON files that may still have removed fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enableManagement = try container.decode(Bool.self, forKey: .enableManagement)
        cacheLimit = try container.decode(Double.self, forKey: .cacheLimit)
        intCachePeriodicity = try container.decode(Int.self, forKey: .intCachePeriodicity)
        restrictOnWiFi = try container.decode(Bool.self, forKey: .restrictOnWiFi)
        allowedNetworks = try container.decode([String].self, forKey: .allowedNetworks)
        overrideCache = try container.decode(Bool.self, forKey: .overrideCache)
        cachePath = try container.decodeIfPresent(String.self, forKey: .cachePath)
        lastRotationRun = try container.decodeIfPresent(Date.self, forKey: .lastRotationRun)
    }

    init(enableManagement: Bool, cacheLimit: Double, intCachePeriodicity: Int,
         restrictOnWiFi: Bool, allowedNetworks: [String],
         overrideCache: Bool, cachePath: String?, lastRotationRun: Date?) {
        self.enableManagement = enableManagement
        self.cacheLimit = cacheLimit
        self.intCachePeriodicity = intCachePeriodicity
        self.restrictOnWiFi = restrictOnWiFi
        self.allowedNetworks = allowedNetworks
        self.overrideCache = overrideCache
        self.cachePath = cachePath
        self.lastRotationRun = lastRotationRun
    }
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

    static let `default` = DisplaySettings(
        intDisplayMode: 0,  // DisplayMode.allDisplays
        intViewingMode: 0,  // ViewingMode.independent
        intAspectMode: 0,  // AspectMode.fill
        displayMarginsAdvanced: false,
        horizontalMargin: 0,
        verticalMargin: 0,
        advancedMargins: ""
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
    var cachedNightShiftSunrise: Double  // timeIntervalSinceReferenceDate
    var cachedNightShiftSunset: Double

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
        cachedNightShiftSunrise: 0,
        cachedNightShiftSunset: 0
    )
}

extension TimeSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intTimeMode = try container.decode(Int.self, forKey: .intTimeMode)
        manualSunrise = try container.decode(String.self, forKey: .manualSunrise)
        manualSunset = try container.decode(String.self, forKey: .manualSunset)
        latitude = try container.decode(String.self, forKey: .latitude)
        longitude = try container.decode(String.self, forKey: .longitude)
        intSolarMode = try container.decode(Int.self, forKey: .intSolarMode)
        sunEventWindow = try container.decode(Int.self, forKey: .sunEventWindow)
        darkModeNightOverride = try container.decode(Bool.self, forKey: .darkModeNightOverride)
        cachedLatitude = try container.decode(Double.self, forKey: .cachedLatitude)
        cachedLongitude = try container.decode(Double.self, forKey: .cachedLongitude)
        cachedNightShiftSunrise = try container.decodeIfPresent(Double.self, forKey: .cachedNightShiftSunrise) ?? 0
        cachedNightShiftSunset = try container.decodeIfPresent(Double.self, forKey: .cachedNightShiftSunset) ?? 0
    }
}

// MARK: - Advanced Settings

struct AdvancedSettings: Codable {
    var muteSound: Bool
    var muteGlobalSound: Bool
    var favorOrientation: Bool
    var debugMode: Bool
    var ciOverrideLanguage: String
    var newDisplayDict: [String: Bool]

    static let `default` = AdvancedSettings(
        muteSound: true,
        muteGlobalSound: false,
        favorOrientation: true,
        debugMode: false,
        ciOverrideLanguage: "",
        newDisplayDict: [:]
    )
}

// MARK: - Updates Settings

/// App update checking settings.
struct UpdatesSettings: Codable {
    var checkForUpdates: Bool
    var intSparkleUpdateMode: Int  // UpdateMode raw value (0 = notify, 1 = install)

    static let `default` = UpdatesSettings(
        checkForUpdates: true,
        intSparkleUpdateMode: 0  // UpdateMode.notify
    )
}

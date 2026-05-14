//
//  CodableRoundTripTests.swift
//  AerialTests
//
//  Encode → Decode round-trip tests for all key Codable models.
//  Catches serialization regressions and validates custom decoders.
//

import Testing
import Foundation
@testable import Aerial

// MARK: - Helper

/// Encode a value to JSON Data, then decode it back.
/// Uses default date strategy (.deferredToDate = seconds since reference date).
private func roundTrip<T: Codable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

@Suite("Codable Round-Trip")
struct CodableRoundTripTests {

    // MARK: - PlaylistModels

    @Test("PersistedPlaylist round-trip preserves all fields")
    func persistedPlaylistRoundTrip() throws {
        let original = PersistedPlaylist(
            entries: [
                PlaylistEntry(videoId: "vid1", videoName: "Video 1", secondaryName: "Sub", duration: 120.5),
                PlaylistEntry(videoId: "vid2", videoName: "Video 2", secondaryName: "", duration: nil),
            ],
            currentIndex: 1,
            playbackTimestamp: 45.3,
            filterMode: 2,
            filterStrings: ["source:macOS"],
            generatedAt: Date(timeIntervalSinceReferenceDate: 700000000),
            cycleMode: .shuffle
        )
        let decoded = try roundTrip(original)
        #expect(decoded.entries.count == 2)
        #expect(decoded.entries[0].videoId == "vid1")
        #expect(decoded.entries[0].duration == 120.5)
        #expect(decoded.entries[1].duration == nil)
        #expect(decoded.currentIndex == 1)
        #expect(decoded.playbackTimestamp == 45.3)
        #expect(decoded.filterMode == 2)
        #expect(decoded.filterStrings == ["source:macOS"])
        #expect(decoded.cycleMode == .shuffle)
    }

    @Test("PersistedPlaylist cycleMode defaults to .loop when missing")
    func persistedPlaylistCycleModeFallback() throws {
        // Simulate old JSON without cycleMode field
        // Date uses .deferredToDate format (seconds since reference date as Double)
        let json = """
        {
            "entries": [],
            "currentIndex": 0,
            "filterMode": 0,
            "filterStrings": [],
            "generatedAt": 700000000.0
        }
        """
        let decoded = try JSONDecoder().decode(PersistedPlaylist.self, from: json.data(using: .utf8)!)
        #expect(decoded.cycleMode == .loop)
    }

    @Test("PlaylistState round-trip")
    func playlistStateRoundTrip() throws {
        let state = PlaylistState(
            version: 1,
            sharedPlaylist: PersistedPlaylist(
                entries: [PlaylistEntry(videoId: "a", videoName: "A", secondaryName: "", duration: nil)],
                currentIndex: 0,
                playbackTimestamp: nil,
                filterMode: 0,
                filterStrings: [],
                generatedAt: Date(timeIntervalSinceReferenceDate: 700000000)
            ),
            screenPlaylists: [:]
        )
        let decoded = try roundTrip(state)
        #expect(decoded.version == 1)
        #expect(decoded.sharedPlaylist?.entries.count == 1)
        #expect(decoded.screenPlaylists.isEmpty)
    }

    // MARK: - OverlayConfig

    @Test("OverlayConfig round-trip preserves all fields")
    func overlayConfigRoundTrip() throws {
        let instance = OverlayInstance(
            id: UUID(),
            kind: .weather,
            position: .topRight,
            fontName: "SF Pro",
            fontSize: 32,
            fontWeight: "bold",
            opacity: 0.8,
            typeSettings: ["city": .string("Paris"), "showWind": .bool(true), "count": .int(5)]
        )
        var layout = OverlayLayout.empty
        layout.addInstance(instance)

        let config = OverlayConfig(
            version: 1,
            perScreen: true,
            separateDesktopConfig: true,
            hideOverlaysDuringLogin: false,
            showVersionAtStartup: false,
            sharedLayout: layout,
            screenLayouts: ["screen1": .empty],
            desktopSharedLayout: .empty,
            desktopScreenLayouts: ["screen1": layout]
        )

        let decoded = try roundTrip(config)
        #expect(decoded.version == 1)
        #expect(decoded.perScreen == true)
        #expect(decoded.separateDesktopConfig == true)
        #expect(decoded.hideOverlaysDuringLogin == false)
        #expect(decoded.showVersionAtStartup == false)
        #expect(decoded.sharedLayout.allInstances.count == 1)
        let decodedInstance = decoded.sharedLayout.allInstances.first!
        #expect(decodedInstance.kind == .weather)
        #expect(decodedInstance.fontWeight == "bold")
        #expect(decodedInstance.opacity == 0.8)
        #expect(decodedInstance.typeSettings["city"]?.asString == "Paris")
        #expect(decodedInstance.typeSettings["showWind"]?.asBool == true)
        #expect(decodedInstance.typeSettings["count"]?.asInt == 5)
    }

    @Test("OverlayConfig defaults for missing optional fields")
    func overlayConfigDefaults() throws {
        // Simulate old JSON without hideOverlaysDuringLogin/showVersionAtStartup
        let json = """
        {
            "version": 1,
            "perScreen": false,
            "separateDesktopConfig": false,
            "sharedLayout": {
                "stacks": {},
                "marginTop": 50,
                "marginLeft": 50,
                "marginBottom": 50,
                "marginRight": 50,
                "shadowRadius": 6,
                "shadowOpacity": 1.0,
                "shadowOffsetX": 0,
                "shadowOffsetY": 3,
                "shadowColorHex": "#000000",
                "textColorHex": "#FFFFFF"
            },
            "screenLayouts": {}
        }
        """
        let decoded = try JSONDecoder().decode(OverlayConfig.self, from: json.data(using: .utf8)!)
        #expect(decoded.hideOverlaysDuringLogin == true)
        #expect(decoded.showVersionAtStartup == true)
        #expect(decoded.desktopSharedLayout == nil)
        #expect(decoded.desktopScreenLayouts == nil)
    }

    @Test("OverlayLayout legacy marginX/marginY migrate to four-side fields")
    func overlayLayoutLegacyMarginMigration() throws {
        // Old config with only marginX/marginY (no marginTop/Left/Bottom/Right)
        let json = """
        {
            "stacks": {},
            "marginX": 80,
            "marginY": 30,
            "shadowRadius": 6,
            "shadowOpacity": 1.0,
            "shadowOffsetX": 0,
            "shadowOffsetY": 3
        }
        """
        let decoded = try JSONDecoder().decode(OverlayLayout.self, from: json.data(using: .utf8)!)
        #expect(decoded.marginTop == 30)
        #expect(decoded.marginBottom == 30)
        #expect(decoded.marginLeft == 80)
        #expect(decoded.marginRight == 80)

        // Re-encode and confirm only the new four-side keys are emitted
        let reEncoded = try JSONEncoder().encode(decoded)
        let dict = try JSONSerialization.jsonObject(with: reEncoded) as! [String: Any]
        #expect(dict["marginTop"] != nil)
        #expect(dict["marginLeft"] != nil)
        #expect(dict["marginBottom"] != nil)
        #expect(dict["marginRight"] != nil)
        #expect(dict["marginX"] == nil)
        #expect(dict["marginY"] == nil)
    }

    @Test("OverlayInstance defaults for missing fontWeight/opacity")
    func overlayInstanceDefaults() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "kind": "clock",
            "position": "bottomLeft",
            "fontName": "Helvetica",
            "fontSize": 20,
            "typeSettings": {}
        }
        """
        let decoded = try JSONDecoder().decode(OverlayInstance.self, from: json.data(using: .utf8)!)
        #expect(decoded.fontWeight == "medium")
        #expect(decoded.opacity == 1.0)
    }

    // MARK: - AnyCodableValue

    @Test("AnyCodableValue round-trip for all types")
    func anyCodableValueRoundTrip() throws {
        let values: [AnyCodableValue] = [.string("hello"), .int(42), .double(3.14), .bool(false)]
        for original in values {
            let decoded = try roundTrip(original)
            #expect(decoded == original)
        }
    }

    @Test("AnyCodableValue asDouble coerces Int")
    func anyCodableIntToDouble() {
        let value = AnyCodableValue.int(42)
        #expect(value.asDouble == 42.0)
    }

    @Test("AnyCodableValue accessors return nil for wrong type")
    func anyCodableAccessorNil() {
        let value = AnyCodableValue.string("hello")
        #expect(value.asInt == nil)
        #expect(value.asDouble == nil)
        #expect(value.asBool == nil)
    }

    // MARK: - OverlayLayout (enum-keyed dictionary)

    @Test("OverlayLayout stacks survive encode/decode with string keys")
    func overlayLayoutStacksCoding() throws {
        var layout = OverlayLayout.empty
        let i1 = OverlayInstance(
            id: UUID(), kind: .clock, position: .topLeft,
            fontName: "H", fontSize: 20, typeSettings: [:]
        )
        let i2 = OverlayInstance(
            id: UUID(), kind: .date, position: .bottomRight,
            fontName: "H", fontSize: 16, typeSettings: [:]
        )
        layout.addInstance(i1)
        layout.addInstance(i2)

        let decoded = try roundTrip(layout)
        #expect(decoded.instances(at: .topLeft).count == 1)
        #expect(decoded.instances(at: .bottomRight).count == 1)
        #expect(decoded.marginTop == 50)
        #expect(decoded.marginLeft == 50)
        #expect(decoded.marginBottom == 50)
        #expect(decoded.marginRight == 50)
        #expect(decoded.shadowOpacity == 1.0)
        #expect(decoded.textColorHex == "#FFFFFF")
        #expect(decoded.shadowColorHex == "#000000")
    }

    @Test("OverlayLayout missing textColorHex/shadowColorHex defaults to white/black")
    func overlayLayoutColorDefaults() throws {
        // Old config without textColorHex or shadowColorHex
        let json = """
        {
            "stacks": {},
            "marginTop": 50,
            "marginLeft": 50,
            "marginBottom": 50,
            "marginRight": 50,
            "shadowRadius": 6,
            "shadowOpacity": 1.0,
            "shadowOffsetX": 0,
            "shadowOffsetY": 3
        }
        """
        let decoded = try JSONDecoder().decode(OverlayLayout.self, from: json.data(using: .utf8)!)
        #expect(decoded.textColorHex == "#FFFFFF")
        #expect(decoded.shadowColorHex == "#000000")
    }

    // MARK: - ScreensaverSettings

    @Test("ScreensaverSettings default round-trip")
    func screensaverSettingsRoundTrip() throws {
        let original = ScreensaverSettings.default
        let decoded = try roundTrip(original)

        #expect(decoded.videos.intNewShouldPlay == original.videos.intNewShouldPlay)
        #expect(decoded.videos.allowSkips == original.videos.allowSkips)
        #expect(decoded.cache.enableManagement == original.cache.enableManagement)
        #expect(decoded.cache.cacheLimit == original.cache.cacheLimit)
        #expect(decoded.displays.intDisplayMode == original.displays.intDisplayMode)
        #expect(decoded.time.intTimeMode == original.time.intTimeMode)
        #expect(decoded.advanced.muteSound == original.advanced.muteSound)
        #expect(decoded.updatesPrefs.checkForUpdates == original.updatesPrefs.checkForUpdates)
    }

    @Test("VideoSettings timeOfDayOverride defaults to empty when missing")
    func videoSettingsTimeOfDayOverrideFallback() throws {
        // Build JSON without timeOfDayOverride
        let json = """
        {
            "intNewShouldPlay": 0,
            "newShouldPlayString": [],
            "intOnBatteryMode": 0,
            "intVideoFormat": 0,
            "intFadeMode": 2,
            "intRefreshPeriodicity": 1,
            "allowSkips": true,
            "sourcesEnabled": {},
            "favorites": [],
            "hidden": [],
            "vibrance": {},
            "globalVibrance": 0,
            "allowPerVideoVibrance": false,
            "durationCache": {},
            "playbackSpeed": {},
            "lastVideoCheck": "2024-01-01"
        }
        """
        let decoded = try JSONDecoder().decode(VideoSettings.self, from: json.data(using: .utf8)!)
        #expect(decoded.timeOfDayOverride.isEmpty)
    }

    @Test("TimeSettings nightShift fields default to 0 when missing")
    func timeSettingsNightShiftFallback() throws {
        let json = """
        {
            "intTimeMode": 0,
            "manualSunrise": "09:00",
            "manualSunset": "19:00",
            "latitude": "",
            "longitude": "",
            "intSolarMode": 1,
            "sunEventWindow": 10800,
            "darkModeNightOverride": false,
            "cachedLatitude": 0,
            "cachedLongitude": 0
        }
        """
        let decoded = try JSONDecoder().decode(TimeSettings.self, from: json.data(using: .utf8)!)
        #expect(decoded.cachedNightShiftSunrise == 0)
        #expect(decoded.cachedNightShiftSunset == 0)
    }

    // MARK: - UserPlaylistModels

    @Test("UserPlaylistIndex round-trip")
    func userPlaylistIndexRoundTrip() throws {
        let index = UserPlaylistIndex(
            version: 1,
            playlists: [
                UserPlaylistSummary(id: UUID(), name: "Favorites", entryCount: 5, order: 0),
                UserPlaylistSummary(id: UUID(), name: "Night", entryCount: 3, order: 1),
            ]
        )
        let decoded = try roundTrip(index)
        #expect(decoded.version == 1)
        #expect(decoded.playlists.count == 2)
        #expect(decoded.playlists[0].name == "Favorites")
        #expect(decoded.playlists[1].entryCount == 3)
    }

    @Test("UserPlaylistManifest round-trip")
    func userPlaylistManifestRoundTrip() throws {
        let manifest = UserPlaylistManifest(
            id: UUID(),
            name: "Test Playlist",
            createdAt: Date(timeIntervalSinceReferenceDate: 700000000),
            cycleMode: .shuffle,
            entries: [
                PlaylistEntry(videoId: "v1", videoName: "V1", secondaryName: "sub", duration: 60),
            ]
        )
        let decoded = try roundTrip(manifest)
        #expect(decoded.name == "Test Playlist")
        #expect(decoded.cycleMode == .shuffle)
        #expect(decoded.entries.count == 1)
        #expect(decoded.entries[0].videoId == "v1")
    }

    // MARK: - WeatherCacheIndex

    @Test("WeatherCacheIndex round-trip")
    func weatherCacheIndexRoundTrip() throws {
        var index = WeatherCacheIndex()
        index.entries["coords:48.86,2.35"] = WeatherCacheIndex.CacheEntry(
            weatherFileId: "abc-123",
            forecastFileId: "def-456",
            weatherFetchedAt: Date(timeIntervalSinceReferenceDate: 700000000),
            forecastFetchedAt: Date(timeIntervalSinceReferenceDate: 700000100)
        )
        let decoded = try roundTrip(index)
        let entry = decoded.entries["coords:48.86,2.35"]
        #expect(entry?.weatherFileId == "abc-123")
        #expect(entry?.forecastFileId == "def-456")
        #expect(entry?.weatherFetchedAt != nil)
    }

    // MARK: - OWeather API Model

    @Test("OWeather decodes from sample JSON")
    func oweatherDecode() throws {
        let json = """
        {
            "coord": {"lon": 2.35, "lat": 48.86},
            "weather": [{"id": 800, "main": "Clear", "description": "clear sky", "icon": "01d"}],
            "base": "stations",
            "main": {"temp": 15.2, "feels_like": 14.1, "temp_min": 13.0, "temp_max": 17.0, "pressure": 1013, "humidity": 72},
            "visibility": 10000,
            "wind": {"speed": 3.6, "deg": 220, "gust": 5.1},
            "clouds": {"all": 0},
            "dt": 1700000000,
            "sys": {"type": 2, "id": 2012208, "country": "FR", "sunrise": 1699949000, "sunset": 1699982000},
            "timezone": 3600,
            "id": 2988507,
            "name": "Paris",
            "cod": 200
        }
        """
        let weather = try JSONDecoder().decode(OWeather.self, from: json.data(using: .utf8)!)
        #expect(weather.name == "Paris")
        #expect(weather.main?.temp == 15.2)
        #expect(weather.wind?.speed == 3.6)
        #expect(weather.weather?.first?.main == "Clear")
        #expect(weather.sys?.country == "FR")
    }

    // MARK: - ForecastElement API Model

    @Test("ForecastElement decodes from sample JSON")
    func forecastDecode() throws {
        let json = """
        {
            "cod": "200",
            "message": 0,
            "cnt": 1,
            "list": [
                {
                    "dt": 1700000000,
                    "main": {
                        "temp": 15.2,
                        "feels_like": 14.1,
                        "temp_min": 13.0,
                        "temp_max": 17.0,
                        "pressure": 1013,
                        "sea_level": 1013,
                        "grnd_level": 1009,
                        "humidity": 72,
                        "temp_kf": 0.5
                    },
                    "weather": [{"id": 800, "main": "Clear", "description": "clear sky", "icon": "01d"}],
                    "clouds": {"all": 0},
                    "wind": {"speed": 3.6, "deg": 220, "gust": 5.1},
                    "visibility": 10000,
                    "pop": 0.1,
                    "sys": {"pod": "d"},
                    "dt_txt": "2023-11-14 12:00:00"
                }
            ],
            "city": {
                "id": 2988507,
                "name": "Paris",
                "coord": {"lat": 48.86, "lon": 2.35},
                "country": "FR",
                "population": 2138551,
                "timezone": 3600,
                "sunrise": 1699949000,
                "sunset": 1699982000
            }
        }
        """
        let forecast = try JSONDecoder().decode(ForecastElement.self, from: json.data(using: .utf8)!)
        #expect(forecast.cod == "200")
        #expect(forecast.list?.count == 1)
        #expect(forecast.list?.first?.main?.temp == 15.2)
        #expect(forecast.city?.name == "Paris")
    }
}

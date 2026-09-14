//
//  WeatherCache.swift
//  Aerial
//
//  Location-keyed weather cache with file-based storage.
//  Cache files live in /Users/Shared/Aerial/Weather/
//

import Foundation

/// Index mapping location keys to cache file UUIDs and timestamps
struct WeatherCacheIndex: Codable {
    var entries: [String: CacheEntry]

    struct CacheEntry: Codable {
        var weatherFileId: String?
        var forecastFileId: String?
        var weatherFetchedAt: Date?
        var forecastFetchedAt: Date?
    }

    init() {
        entries = [:]
    }
}

/// File-based weather cache keyed by location (not by overlay instance UUID)
enum WeatherCache {

    /// TTL for cache entries (15 minutes)
    static let ttl: TimeInterval = 60 * 15

    private static let cacheDir: URL = {
        URL(fileURLWithPath: AerialPaths.baseDirectory, isDirectory: true)
            .appendingPathComponent("Weather", isDirectory: true)
    }()

    private static let indexURL: URL = {
        cacheDir.appendingPathComponent("weathercache.json")
    }()

    // MARK: - Index I/O

    static func loadIndex() -> WeatherCacheIndex {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return WeatherCacheIndex()
        }
        do {
            let data = try Data(contentsOf: indexURL)
            return try JSONDecoder().decode(WeatherCacheIndex.self, from: data)
        } catch {
            errorLog("⛅🌡️ Failed to load index: \(error)")
            return WeatherCacheIndex()
        }
    }

    static func saveIndex(_ index: WeatherCacheIndex) {
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(index)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            errorLog("⛅🌡️ Failed to save index: \(error)")
        }
    }

    // MARK: - Weather Data I/O

    static func loadWeather(fileId: String) -> OWeather? {
        let url = cacheDir.appendingPathComponent("\(fileId).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OWeather.self, from: data)
    }

    static func saveWeather(_ weather: OWeather, fileId: String) {
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(weather)
            try data.write(to: cacheDir.appendingPathComponent("\(fileId).json"), options: .atomic)
        } catch {
            errorLog("⛅🌡️ Failed to save weather \(fileId): \(error)")
        }
    }

    static func loadForecast(fileId: String) -> ForecastElement? {
        let url = cacheDir.appendingPathComponent("\(fileId).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ForecastElement.self, from: data)
    }

    static func saveForecast(_ forecast: ForecastElement, fileId: String) {
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(forecast)
            try data.write(to: cacheDir.appendingPathComponent("\(fileId).json"), options: .atomic)
        } catch {
            errorLog("⛅🌡️ Failed to save forecast \(fileId): \(error)")
        }
    }

    // MARK: - High-Level Cache Access

    /// Pure freshness predicate, parameterised on `now` so tests can inject a clock.
    /// Boundary: an entry whose age equals `ttl` is considered stale (strict `<`).
    static func isFresh(fetchedAt: Date?, ttl: TimeInterval, now: Date = Date()) -> Bool {
        guard let fetchedAt = fetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) < ttl
    }

    /// Get cached weather for a location key, returning nil if stale or missing
    static func cachedWeather(for key: String) -> OWeather? {
        let index = loadIndex()
        guard let entry = index.entries[key],
              let fileId = entry.weatherFileId,
              isFresh(fetchedAt: entry.weatherFetchedAt, ttl: ttl) else {
            return nil
        }
        return loadWeather(fileId: fileId)
    }

    /// Get cached forecast for a location key, returning nil if stale or missing
    static func cachedForecast(for key: String) -> ForecastElement? {
        let index = loadIndex()
        guard let entry = index.entries[key],
              let fileId = entry.forecastFileId,
              isFresh(fetchedAt: entry.forecastFetchedAt, ttl: ttl) else {
            return nil
        }
        return loadForecast(fileId: fileId)
    }

    /// Age of cached weather data for a key, or nil if not cached
    static func weatherAge(for key: String) -> TimeInterval? {
        let index = loadIndex()
        guard let entry = index.entries[key],
              let fetchedAt = entry.weatherFetchedAt else { return nil }
        return Date().timeIntervalSince(fetchedAt)
    }

    /// Age of cached forecast data for a key, or nil if not cached
    static func forecastAge(for key: String) -> TimeInterval? {
        let index = loadIndex()
        guard let entry = index.entries[key],
              let fetchedAt = entry.forecastFetchedAt else { return nil }
        return Date().timeIntervalSince(fetchedAt)
    }

    /// Store weather data for a location key
    static func storeWeather(_ weather: OWeather, for key: String) {
        var index = loadIndex()
        var entry = index.entries[key] ?? WeatherCacheIndex.CacheEntry()

        // Reuse existing file ID or create new one
        let fileId = entry.weatherFileId ?? UUID().uuidString
        entry.weatherFileId = fileId
        entry.weatherFetchedAt = Date()
        index.entries[key] = entry

        saveWeather(weather, fileId: fileId)
        saveIndex(index)
    }

    /// Store forecast data for a location key
    static func storeForecast(_ forecast: ForecastElement, for key: String) {
        var index = loadIndex()
        var entry = index.entries[key] ?? WeatherCacheIndex.CacheEntry()

        let fileId = entry.forecastFileId ?? UUID().uuidString
        entry.forecastFileId = fileId
        entry.forecastFetchedAt = Date()
        index.entries[key] = entry

        saveForecast(forecast, fileId: fileId)
        saveIndex(index)
    }
}

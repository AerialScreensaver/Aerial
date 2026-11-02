//
//  WeatherProvider.swift
//  Aerial
//
//  Centralized weather data provider with location-keyed caching.
//  Singleton that handles fetching, caching, and periodic refresh
//  for all weather overlay instances.
//

import Foundation
import Combine

class WeatherProvider {
    static let shared = WeatherProvider()

    // MARK: - Combine Publishers

    /// Fires when weather data is fetched/updated for a location key
    let weatherUpdated = PassthroughSubject<(String, OWeather), Never>()

    /// Fires when forecast data is fetched/updated for a location key
    let forecastUpdated = PassthroughSubject<(String, ForecastElement), Never>()

    // MARK: - In-Memory Cache

    /// In-memory weather data keyed by location cache key
    private var weatherByKey: [String: OWeather] = [:]

    /// In-memory forecast data keyed by location cache key
    private var forecastByKey: [String: ForecastElement] = [:]

    /// Tracks in-flight fetches to avoid duplicate requests
    private var pendingWeatherKeys: Set<String> = []
    private var pendingForecastKeys: Set<String> = []

    // MARK: - Periodic Refresh

    private var refreshCancellable: AnyCancellable?

    /// Active location sources to refresh: the union over every registered
    /// subscriber (one `OverlayState` per display), so one display's
    /// teardown never drops another display's city.
    private var activeLocations: [(key: String, source: WeatherLocationSource, needsForecast: Bool)] = []
    private var locationsBySubscriber: [ObjectIdentifier: [(source: WeatherLocationSource, needsForecast: Bool)]] = [:]
    private var subscribers = Set<ObjectIdentifier>()

    private init() {}

    // MARK: - Public API

    /// Register the set of active locations that should be refreshed periodically
    /// on behalf of `subscriber`. Pass an empty list to clear that subscriber's share.
    func setActiveLocations(_ locations: [(source: WeatherLocationSource, needsForecast: Bool)], for subscriber: AnyObject) {
        let id = ObjectIdentifier(subscriber)
        if locations.isEmpty { locationsBySubscriber.removeValue(forKey: id) }
        else { locationsBySubscriber[id] = locations }
        rebuildActiveLocations()
    }

    /// Legacy single-owner registration. Kept for callers outside the overlay
    /// system; replaces the shared (nil-subscriber) share only.
    func setActiveLocations(_ locations: [(source: WeatherLocationSource, needsForecast: Bool)]) {
        setActiveLocations(locations, for: self)
    }

    private func rebuildActiveLocations() {
        // Deduplicate by cache key; a forecast request wins over current-only.
        var merged: [String: (key: String, source: WeatherLocationSource, needsForecast: Bool)] = [:]
        var order: [String] = []
        for loc in locationsBySubscriber.values.flatMap({ $0 }) {
            let key = loc.source.cacheKey
            if var existing = merged[key] {
                existing.needsForecast = existing.needsForecast || loc.needsForecast
                merged[key] = existing
            } else {
                merged[key] = (key: key, source: loc.source, needsForecast: loc.needsForecast)
                order.append(key)
            }
        }
        activeLocations = order.compactMap { merged[$0] }
        debugLog("⛅🌡️ Active locations: \(activeLocations.map { $0.key })")
    }

    /// Refresh all active locations (uses disk cache if fresh, else fetches from API)
    func refreshAll() {
        for loc in activeLocations {
            if let cached = WeatherCache.cachedWeather(for: loc.key) {
                weatherByKey[loc.key] = cached
                let age = WeatherCache.weatherAge(for: loc.key) ?? 0
                debugLog("⛅🌡️ Weather cache hit for \(loc.key) (fetched \(Int(age / 60)) mins ago)")
                weatherUpdated.send((loc.key, cached))
            } else {
                fetchWeather(for: loc.source, completion: nil)
            }

            if loc.needsForecast {
                if let cached = WeatherCache.cachedForecast(for: loc.key) {
                    forecastByKey[loc.key] = cached
                    let age = WeatherCache.forecastAge(for: loc.key) ?? 0
                    debugLog("⛅🌡️ Forecast cache hit for \(loc.key) (fetched \(Int(age / 60)) mins ago)")
                    forecastUpdated.send((loc.key, cached))
                } else {
                    fetchForecast(for: loc.source, completion: nil)
                }
            }
        }
    }

    /// Start periodic refresh on behalf of `subscriber`. The timer runs while at
    /// least one subscriber remains; every call refreshes immediately so a new
    /// display gets data without waiting for the next tick.
    func startPeriodicRefresh(interval: TimeInterval = WeatherCache.ttl, for subscriber: AnyObject? = nil) {
        subscribers.insert(ObjectIdentifier(subscriber ?? self))
        refreshAll()
        guard refreshCancellable == nil else { return }
        refreshCancellable = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshAll() }
    }

    /// Stop refreshing on behalf of `subscriber`; the timer stops only when no
    /// subscriber is left. The subscriber's locations are dropped as well.
    func stopPeriodicRefresh(for subscriber: AnyObject? = nil) {
        let id = ObjectIdentifier(subscriber ?? self)
        subscribers.remove(id)
        locationsBySubscriber.removeValue(forKey: id)
        rebuildActiveLocations()
        if subscribers.isEmpty { refreshCancellable = nil }
    }

    // MARK: - Fetching

    private func fetchWeather(for location: WeatherLocationSource,
                              completion: ((OWeather?) -> Void)?) {
        let key = location.cacheKey

        guard !pendingWeatherKeys.contains(key) else {
            debugLog("⛅🌡️ Weather fetch already in flight for \(key)")
            completion?(nil)
            return
        }

        pendingWeatherKeys.insert(key)
        debugLog("⛅🌡️ Fetching weather for \(key)")

        OpenWeather.fetch(location: location) { [weak self] result in
            guard let self = self else { return }
            self.pendingWeatherKeys.remove(key)

            switch result {
            case .success(let weather):
                self.weatherByKey[key] = weather
                WeatherCache.storeWeather(weather, for: key)
                infoLog("⛅🌡️ Weather fetched and cached for \(key)")
                self.weatherUpdated.send((key, weather))
                completion?(weather)
            case .failure(let error):
                errorLog("⛅🌡️ Weather fetch failed for \(key): \(error)")
                completion?(nil)
            }
        }
    }

    private func fetchForecast(for location: WeatherLocationSource,
                               completion: ((ForecastElement?) -> Void)?) {
        let key = location.cacheKey

        guard !pendingForecastKeys.contains(key) else {
            debugLog("⛅🌡️ Forecast fetch already in flight for \(key)")
            completion?(nil)
            return
        }

        pendingForecastKeys.insert(key)
        debugLog("⛅🌡️ Fetching forecast for \(key)")

        Forecast.fetch(location: location) { [weak self] result in
            guard let self = self else { return }
            self.pendingForecastKeys.remove(key)

            switch result {
            case .success(let forecast):
                self.forecastByKey[key] = forecast
                WeatherCache.storeForecast(forecast, for: key)
                infoLog("⛅🌡️ Forecast fetched and cached for \(key)")
                self.forecastUpdated.send((key, forecast))
                completion?(forecast)
            case .failure(let error):
                errorLog("⛅🌡️ Forecast fetch failed for \(key): \(error)")
                completion?(nil)
            }
        }
    }
}

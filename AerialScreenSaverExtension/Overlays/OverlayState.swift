//
//  OverlayState.swift
//  AerialScreenSaverExtension
//
//  Observable state for the config-based SwiftUI overlay system.
//  Manages overlay data, clock timer, and state mutations.
//

import Foundation
import Combine
import AVFoundation
import CoreMedia
import SwiftUI
#if COMPANION_APP
import AppKit
#endif

/// Observable state object that drives the SwiftUI overlay view
class OverlayState: ObservableObject {

    // MARK: - Published State

    @Published var weatherDataByInstance: [UUID: OWeather] = [:]
    @Published var forecastDataByInstance: [UUID: ForecastElement] = [:]
    @Published var songInfo: SongInfo?

    /// Location text from the current video's POI data
    @Published var locationText: String?
    @Published var locationVisible: Bool = false

    /// Config-based overlay instances
    @Published var configInstances: [OverlayInstance] = []

    /// Wall-clock-derived tick for visual rotation of overlay stacks.
    /// Bumped by `rotationTimer`; the renderer uses it to shift each screen
    /// position onto a source position one step earlier in its cycle per tick.
    @Published var rotationTick: Int = 0

    /// Extra inset to push overlays away from system UI (e.g. the macOS Dock).
    /// Set by Companion in desktop mode; the screensaver extension leaves it at zero.
    @Published var dockInset: EdgeInsets = EdgeInsets()

    /// Layout-level text color, derived from `configLayout?.textColorHex`.
    /// Defaults to white when no layout is loaded.
    var textColor: Color {
        Color(overlayHex: configLayout?.textColorHex ?? "#FFFFFF")
    }

    /// Version banner
    @Published var showVersionBanner = false
    var versionBannerText = ""

    /// The layout loaded from overlay-config.json (if any)
    private(set) var configLayout: OverlayLayout?

    // MARK: - Properties

    let isPreview: Bool
    let activationTime = Date()
    private var clockTimer: Timer?
    private var rotationTimer: Timer?
    private var configChangeObserver: NSObjectProtocol?

    /// Boundary time observer for POI updates
    private var poiTimeObserver: Any?

    /// Weak reference to current player (for removing observers)
    private weak var currentPlayer: AVPlayer?

    /// Combine subscriptions for WeatherProvider updates
    private var weatherSubs = Set<AnyCancellable>()

    /// Music subscription (Companion path via NowPlayingCoordinator)
    private var musicSub: AnyCancellable?

    // MARK: - Initialization

    init(isPreview: Bool) {
        self.isPreview = isPreview
    }

    deinit {
        cleanup()
    }

    // MARK: - Config-Based Rendering

    /// Start the overlay system from a new OverlayConfig layout
    func startFromConfig(layout: OverlayLayout) {
        configLayout = layout
        configInstances = layout.allInstances

        OverlayTypeRegistry.registerAll()

        // Setup timers for types that need per-second refresh
        let needsSecondTimer = configInstances.contains { [.clock, .timer, .countdown, .battery].contains($0.kind) }
        if needsSecondTimer {
            clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.objectWillChange.send()
            }
        }

        let hasWeather = configInstances.contains { $0.kind == .weather }
        if hasWeather {
            setupWeatherSubscriptions()
            registerActiveWeatherLocations()
            WeatherProvider.shared.startPeriodicRefresh()
        }

        let hasMusic = configInstances.contains { $0.kind == .music }
        if hasMusic {
            setupMusicSubscriptions()
        }

        applyRotationMode(OverlayConfigManager.shared.config.rotationMode)
        observeConfigChanges()
    }

    /// Replace the active layout (used when the view's screen changes
    /// after initial setup — see `AerialSaverView.windowDidChangeScreen`).
    /// Idempotent on every side-effect: `clockTimer` is gated on `nil`,
    /// `setupWeatherSubscriptions` / `setupMusicSubscriptions` are
    /// self-guarded, so calling this repeatedly never leaks timers or
    /// double-subscribes Combine sinks. We deliberately don't tear down
    /// resources when the new layout drops a category — the cost of an
    /// idle 1 Hz timer or unused weather pull is negligible, and the
    /// view's `cleanup()` handles teardown at the right moment anyway.
    func replaceLayout(_ layout: OverlayLayout) {
        configLayout = layout
        configInstances = layout.allInstances

        let needsSecondTimer = configInstances.contains {
            [.clock, .timer, .countdown, .battery].contains($0.kind)
        }
        if needsSecondTimer && clockTimer == nil {
            clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.objectWillChange.send()
            }
        }

        if configInstances.contains(where: { $0.kind == .weather }) {
            setupWeatherSubscriptions()
            registerActiveWeatherLocations()
            WeatherProvider.shared.startPeriodicRefresh()
        }
        if configInstances.contains(where: { $0.kind == .music }) {
            setupMusicSubscriptions()
        }

        applyRotationMode(OverlayConfigManager.shared.config.rotationMode)
    }

    // MARK: - Rotation Timer

    /// Start / stop the rotation timer according to the current mode.
    /// The tick is derived from wall-clock time so all screens stay in sync
    /// without cross-view coordination.
    private func applyRotationMode(_ mode: OverlayRotationMode) {
        rotationTimer?.invalidate()
        rotationTimer = nil

        guard let interval = mode.interval else {
            // Off: snap back to "home" positions.
            if rotationTick != 0 { rotationTick = 0 }
            return
        }

        rotationTick = Int(Date().timeIntervalSince1970 / interval)
        rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let tick = Int(Date().timeIntervalSince1970 / interval)
            if tick != self.rotationTick {
                self.rotationTick = tick
            }
        }
    }

    private func observeConfigChanges() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: OverlayConfigManager.configDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.applyRotationMode(OverlayConfigManager.shared.config.rotationMode)
        }
    }

    /// Get config instances at a given position
    func instancesInPosition(_ position: OverlayPosition) -> [OverlayInstance] {
        configLayout?.instances(at: position) ?? []
    }

    // MARK: - Lifecycle

    /// Called when a new video starts playing
    func setVideo(video: AerialVideo, player: AVPlayer) {
        updateLocationOverlay(video: video, player: player)
    }

    /// Clean up timers and state
    func cleanup() {
        clockTimer?.invalidate()
        clockTimer = nil
        rotationTimer?.invalidate()
        rotationTimer = nil
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        WeatherProvider.shared.stopPeriodicRefresh()
        weatherSubs.removeAll()
        musicSub?.cancel()
        musicSub = nil
        removePoiObserver()
    }

    // MARK: - Version Banner

    /// Shows version banner for the config-based rendering path.
    func showVersionIfNeeded() {
        guard OverlayConfigManager.shared.config.showVersionAtStartup else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        versionBannerText = "Version \(version) (\(build))"
        showVersionBanner = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            withAnimation(.easeOut(duration: 1.0)) { self?.showVersionBanner = false }
        }
    }

    // MARK: - Location Overlay

    /// Remove any existing POI boundary time observer
    private func removePoiObserver() {
        if let observer = poiTimeObserver, let player = currentPlayer {
            player.removeTimeObserver(observer)
        }
        poiTimeObserver = nil
        currentPlayer = nil
    }

    /// Show the location text with fade-in, optionally scheduling a fade-out
    private func showLocationText(_ text: String, fadeOutAfter: Double? = nil) {
        withAnimation(.easeIn(duration: 1.0)) {
            locationText = text
            locationVisible = true
        }

        if let delay = fadeOutAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                withAnimation(.easeOut(duration: 1.0)) {
                    self.locationVisible = false
                }
            }
        }
    }

    private func updateLocationOverlay(video: AerialVideo, player: AVPlayer) {
        // Only show location if there's a location overlay in the config
        let hasLocationOverlay = configInstances.contains { $0.kind == .location }
        guard hasLocationOverlay else {
            locationText = nil
            locationVisible = false
            return
        }

        // Clean up previous video's observer
        removePoiObserver()
        currentPlayer = player

        // Read time setting from the first location instance
        let locationInstance = configInstances.first { $0.kind == .location }
        let timeSetting = locationInstance?.typeSettings["time"]?.asString ?? "always"
        let fadeOutDuration: Double? = timeSetting == "tenSeconds" ? 10.0 : nil

        let poiStringProvider = PoiStringProvider.sharedInstance

        if !video.poi.isEmpty {
            // Video has POI data — show changing location descriptions at timestamps
            let keys = video.poi

            var times = [CMTime]()
            for pkv in keys {
                if let ts = Double(pkv.key) {
                    times.append(CMTime(seconds: ts, preferredTimescale: 1))
                }
            }
            times.sort { $0.seconds < $1.seconds }

            guard !times.isEmpty else {
                showFallbackLocation(video: video, fadeOutAfter: fadeOutDuration)
                return
            }

            // Show the first POI immediately
            var initialKey = keys["0"] ?? keys[String(format: "%.0f", times[0].seconds)] ?? ""
            // Apple workaround: Coit Tower Night reused a key
            if initialKey == "A004_C012_0" && video.id == "b6-4" {
                initialKey = "A004_C012_100"
            }
            let initialText = poiStringProvider.getString(initialKey)

            showLocationText(initialText, fadeOutAfter: fadeOutDuration)

            // Register boundary time observer for remaining timestamps
            let timeValues = times.map { NSValue(time: $0) }
            poiTimeObserver = player.addBoundaryTimeObserver(forTimes: timeValues, queue: .main) { [weak self] in
                guard let self = self else { return }

                // Find closest timestamp to current playback position
                let currentSeconds = player.currentTime().seconds
                var closestTime = CMTime.zero
                var closestDist = Double.greatestFiniteMagnitude
                for time in times {
                    let dist = abs(time.seconds - currentSeconds)
                    if dist < closestDist {
                        closestDist = dist
                        closestTime = time
                    }
                }

                let key = String(format: "%.0f", closestTime.seconds)
                guard let poiKey = keys[key] else { return }
                let text = poiStringProvider.getString(poiKey)

                self.showLocationText(text, fadeOutAfter: fadeOutDuration)
            }
        } else {
            // No POI data — use secondary name or video name
            showFallbackLocation(video: video, fadeOutAfter: fadeOutDuration)
        }
    }

    /// Show a static fallback location (secondaryName or name)
    private func showFallbackLocation(video: AerialVideo, fadeOutAfter: Double?) {
        let text = !video.secondaryName.isEmpty ? video.secondaryName : video.name
        guard !text.isEmpty else {
            withAnimation(.easeOut(duration: 0.5)) {
                locationText = nil
                locationVisible = false
            }
            return
        }

        showLocationText(text, fadeOutAfter: fadeOutAfter)
    }

    // MARK: - Music Subscriptions

    private func setupMusicSubscriptions() {
        guard musicSub == nil else { return }

        #if COMPANION_APP
        musicSub = NowPlayingCoordinator.shared.songUpdated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] song in
                guard let self = self else { return }
                self.songInfo = song
            }

        // Fetch initial state
        NowPlayingCoordinator.shared.fetchCurrentSong { [weak self] song in
            guard let self = self else { return }
            self.songInfo = song
        }
        #else
        Music.instance.setup()
        Music.instance.addCallback { [weak self] songInfo in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.songInfo = songInfo
            }
        }
        #endif
    }

    // MARK: - WeatherProvider Integration

    /// Subscribe to WeatherProvider's Combine publishers
    private func setupWeatherSubscriptions() {
        guard weatherSubs.isEmpty else { return }

        WeatherProvider.shared.weatherUpdated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] key, weather in
                self?.updateWeatherForKey(key, weather: weather)
            }
            .store(in: &weatherSubs)

        WeatherProvider.shared.forecastUpdated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] key, forecast in
                self?.updateForecastForKey(key, forecast: forecast)
            }
            .store(in: &weatherSubs)
    }

    /// Register active weather locations with WeatherProvider from config instances
    private func registerActiveWeatherLocations() {
        let weatherInstances = configInstances.filter { $0.kind == .weather }
        let locations: [(source: WeatherLocationSource, needsForecast: Bool)] = weatherInstances.compactMap { instance in
            let source = locationSource(for: instance)
            guard let source = source else { return nil }
            let mode = instance.typeSettings["mode"]?.asString ?? "current"
            return (source: source, needsForecast: mode != "current")
        }
        WeatherProvider.shared.setActiveLocations(locations)
    }

    /// Map a weather update to all overlay instances with matching location
    private func updateWeatherForKey(_ key: String, weather: OWeather) {
        for instance in configInstances where instance.kind == .weather {
            if let source = locationSource(for: instance), source.cacheKey == key {
                weatherDataByInstance[instance.id] = weather
            }
        }
    }

    /// Map a forecast update to all overlay instances with matching location
    private func updateForecastForKey(_ key: String, forecast: ForecastElement) {
        for instance in configInstances where instance.kind == .weather {
            if let source = locationSource(for: instance), source.cacheKey == key {
                forecastDataByInstance[instance.id] = forecast
            }
        }
    }

    /// Build a WeatherLocationSource from an overlay instance's typeSettings
    func locationSource(for instance: OverlayInstance) -> WeatherLocationSource? {
        let locationMode = instance.typeSettings["locationMode"]?.asString ?? "current"
        let locationString = instance.typeSettings["locationString"]?.asString ?? ""

        if locationMode == "manual" && !locationString.isEmpty {
            return .city(name: locationString)
        } else {
            let lat = PrefsTime.cachedLatitude
            let lon = PrefsTime.cachedLongitude
            guard lat != 0 || lon != 0 else { return nil }
            return .coordinates(lat: lat, lon: lon)
        }
    }

    // MARK: - On-Demand Preview Fetch

    /// Fetch weather for a single instance on demand (used by the overlay editor preview).
    /// Bypasses the per-instance cache so settings changes are reflected immediately.
    func fetchWeatherForPreview(instance: OverlayInstance) {
        guard instance.kind == .weather else { return }

        let source = locationSource(for: instance)
        guard let source = source else {
            debugLog("Weather preview[\(instance.id)]: no location available, skipping")
            return
        }
        let mode = instance.typeSettings["mode"]?.asString ?? "current"
        let instanceID = instance.id

        OpenWeather.fetch(location: source) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if case .success(let weather) = result {
                    self.weatherDataByInstance[instanceID] = weather
                }
            }
        }

        if mode != "current" {
            Forecast.fetch(location: source) { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if case .success(let forecast) = result {
                        self.forecastDataByInstance[instanceID] = forecast
                    }
                }
            }
        }
    }
}

// MARK: - Color Hex Helpers

extension Color {
    /// Initialize from a hex string like "#RRGGBB" or "#RRGGBBAA". Falls back to white on parse error.
    init(overlayHex: String) {
        let trimmed = overlayHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: trimmed).scanHexInt64(&v)
        let r, g, b, a: Double
        switch trimmed.count {
        case 6:
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
            a = 1
        case 8:
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255
            a = Double(v & 0xFF) / 255
        default:
            r = 1; g = 1; b = 1; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

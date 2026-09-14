//
//  OverlayState.swift
//  Aerial
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
    /// Set by the wallpaper extension to clear the macOS Dock; zero otherwise.
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

    /// Playback-position source for the location overlay, supplied by
    /// the host with the video (the wallpaper extension reads its
    /// renderer's shared CMTimebase). Replaces the old AVPlayer
    /// boundary observer — the AVPlayer-less engine can't provide one.
    private var positionProvider: (() -> Double)?

    /// 1 s poll that swaps POI text as playback crosses timeline
    /// entries. Position-based, so video loops reset the text and rate
    /// changes need nothing. Only runs while the current video has a
    /// multi-entry POI timeline.
    private var locationPollTimer: Timer?

    /// Sorted POI timeline for the current video (seconds → localized
    /// text) and the index last shown (avoid re-animating every poll).
    private var poiTimeline: [(time: Double, text: String)] = []
    private var lastShownPoiIndex: Int?

    /// The video currently being rendered. Kept so `replaceLayout`
    /// can re-evaluate per-video overlay state (Location, primarily)
    /// when the active layout changes mid-playback — without it, a
    /// late screen-detection layout swap only takes effect on the
    /// NEXT setVideo, leaving the first video missing overlays that
    /// only exist in the now-correct layout.
    private var currentVideo: AerialVideo?

    /// Combine subscriptions for WeatherProvider updates
    private var weatherSubs = Set<AnyCancellable>()

    /// Music subscription (Companion path via NowPlayingCoordinator)
    private var musicSub: AnyCancellable?

    // MARK: - Dynamic message content (shell script / text file)

    /// Published text per message-instance UUID, relayed by Companion's
    /// MessageContentProvider through message-content.json (the
    /// sandboxed extension can't run scripts or read arbitrary files
    /// itself). Re-read lazily when the file's mtime moves; renders are
    /// driven by the shared tick.
    private var messageContent: [String: String] = [:]
    private var messageContentMTime: Date?

    private struct MessageContentEntry: Codable {
        var text: String
        var updatedAt: Date
    }

    private static let messageContentPath = AerialPaths.baseDirectory + "/message-content.json"

    /// Text for a dynamic (shell/textfile) message instance; nil until
    /// Companion has published something for it.
    func messageText(for instance: OverlayInstance) -> String? {
        reloadMessageContentIfNeeded()
        return messageContent[instance.id.uuidString]
    }

    private func reloadMessageContentIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: Self.messageContentPath)
        let mtime = attributes?[.modificationDate] as? Date
        guard mtime != messageContentMTime else { return }
        messageContentMTime = mtime

        guard let data = FileManager.default.contents(atPath: Self.messageContentPath) else {
            messageContent = [:]
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = (try? decoder.decode([String: MessageContentEntry].self, from: data)) ?? [:]
        messageContent = entries.mapValues(\.text)
    }

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

        // Time-driven content invalidation at the cadence the layout
        // actually needs (1 s / minute-aligned / none).
        ensureTickTimer()

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

    /// Replace the active layout (used when the host's screen changes
    /// after initial setup, e.g. a late screen-detection swap).
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

        ensureTickTimer()

        if configInstances.contains(where: { $0.kind == .weather }) {
            setupWeatherSubscriptions()
            registerActiveWeatherLocations()
            WeatherProvider.shared.startPeriodicRefresh()
        }
        if configInstances.contains(where: { $0.kind == .music }) {
            setupMusicSubscriptions()
        }

        applyRotationMode(OverlayConfigManager.shared.config.rotationMode)

        // Re-evaluate per-video Location state for the currently-playing
        // video. Without this, a layout swap that adds (or removes) a
        // Location overlay only takes effect on the NEXT video — the
        // running video keeps whatever Location state was set at the
        // last setVideo, which for a multi-screen "screen detected
        // late" scenario means no location overlay on the first video.
        if currentVideo != nil {
            updateLocationOverlay()
        }
    }

    // MARK: - Tick Timer

    /// Cadence of the currently-installed `clockTimer`; nil when none.
    private var currentTickInterval: TimeInterval?

    /// Cadence the current layout needs for time-driven content.
    /// 1 s: timers/countdowns/battery, or a clock that shows seconds or
    /// flashes its separator. 60 s: clocks without seconds and date
    /// overlays — they only change at minute/day boundaries, and the old
    /// unconditional 1 s tick made every consumer (live SwiftUI in the
    /// saver, ImageRenderer bakes in the wallpaper extension) re-render
    /// 60× more often than the content changes. Date overlays previously
    /// got NO tick at all and went stale at midnight in long-lived hosts.
    private func desiredTickInterval() -> TimeInterval? {
        var needsSecond = false
        var needsMinute = false
        var needsMessagePoll = false
        for instance in configInstances {
            switch instance.kind {
            case .timer, .countdown, .battery:
                needsSecond = true
            case .clock:
                let showSeconds = instance.typeSettings["showSeconds"]?.asBool ?? true
                let flash = instance.typeSettings["flashSeparator"]?.asBool ?? false
                if showSeconds || flash { needsSecond = true } else { needsMinute = true }
            case .date:
                needsMinute = true
            case .message:
                // Dynamic (shell/textfile) messages poll Companion's
                // relay file — 10 s is the finest refresh option
                // offered. Static text messages need no tick.
                let type = instance.typeSettings["messageType"]?.asString ?? "text"
                if type == "shell" || type == "textfile" { needsMessagePoll = true }
            default:
                break
            }
        }
        if needsSecond { return 1 }
        if needsMessagePoll { return 10 }
        if needsMinute { return 60 }
        return nil
    }

    /// (Re)install `clockTimer` for the layout's needs. Idempotent —
    /// keeps the existing timer when the cadence is unchanged, so
    /// repeated `replaceLayout` calls never churn timers.
    private func ensureTickTimer() {
        let desired = desiredTickInterval()
        guard desired != currentTickInterval else { return }
        clockTimer?.invalidate()
        clockTimer = nil
        currentTickInterval = desired
        guard let interval = desired else { return }

        let firstFire: Date
        let tolerance: TimeInterval
        if interval >= 60 {
            // Minute cadence must fire AT minute boundaries — a
            // free-running 60 s timer started mid-minute would show the
            // old minute for up to 59 s. +0.05 s slack so the formatted
            // value has definitely rolled over when consumers render.
            let now = Date().timeIntervalSinceReferenceDate
            firstFire = Date(timeIntervalSinceReferenceDate: (now / 60).rounded(.down) * 60 + 60 + 0.05)
            tolerance = 1.0
        } else {
            // Small random phase so several OverlayStates (one per
            // display / acquire in the wallpaper extension) don't all
            // publish — and thus rasterize — on the same tick.
            firstFire = Date(timeIntervalSinceNow: interval + Double.random(in: 0...0.35))
            tolerance = 0.05
        }
        let timer = Timer(fire: firstFire, interval: interval, repeats: true) { [weak self] _ in
            self?.objectWillChange.send()
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
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

    /// Called when a new video starts playing. `positionProvider`
    /// returns the current in-asset playback position in seconds —
    /// the wallpaper extension passes a read of its renderer's
    /// CMTimebase-derived position.
    func setVideo(_ video: AerialVideo, positionProvider: @escaping () -> Double) {
        currentVideo = video
        self.positionProvider = positionProvider
        updateLocationOverlay()
    }

    /// Clean up timers and state
    func cleanup() {
        clockTimer?.invalidate()
        clockTimer = nil
        currentTickInterval = nil
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
        stopLocationPoll()
        positionProvider = nil
        currentVideo = nil
    }

    // MARK: - Version Banner

    /// Builds the "Version x (y)" string from the running bundle.
    private func makeVersionBannerText() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    /// Shows version banner for the config-based rendering path.
    func showVersionIfNeeded() {
        guard OverlayConfigManager.shared.config.showVersionAtStartup else { return }
        versionBannerText = makeVersionBannerText()
        showVersionBanner = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            withAnimation(.easeOut(duration: 1.0)) { self?.showVersionBanner = false }
        }
    }

    /// Pins the version banner permanently (debug "always show version"
    /// option). Unlike `showVersionIfNeeded()` it never auto-hides and is
    /// gated by the caller, not by `showVersionAtStartup`.
    func showVersionAlways() {
        versionBannerText = makeVersionBannerText()
        showVersionBanner = true
    }

    // MARK: - Location Overlay

    private func stopLocationPoll() {
        locationPollTimer?.invalidate()
        locationPollTimer = nil
        poiTimeline = []
        lastShownPoiIndex = nil
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

    private func updateLocationOverlay() {
        stopLocationPoll()

        // Only show location if there's a location overlay in the config
        let hasLocationOverlay = configInstances.contains { $0.kind == .location }
        guard hasLocationOverlay, let video = currentVideo else {
            locationText = nil
            locationVisible = false
            return
        }

        // Read time setting from the first location instance
        let locationInstance = configInstances.first { $0.kind == .location }
        let timeSetting = locationInstance?.typeSettings["time"]?.asString ?? "always"
        let fadeOutDuration: Double? = timeSetting == "tenSeconds" ? 10.0 : nil

        let poiStringProvider = PoiStringProvider.sharedInstance

        // Build the localized, sorted POI timeline for this video.
        poiTimeline = video.poi.compactMap { key, value in
            guard let ts = Double(key) else { return nil }
            var poiKey = value
            // Apple workaround: Coit Tower Night reused a key
            if poiKey == "A004_C012_0" && video.id == "b6-4" && ts == 0 {
                poiKey = "A004_C012_100"
            }
            return (time: ts, text: poiStringProvider.getString(poiKey))
        }.sorted { $0.time < $1.time }

        guard !poiTimeline.isEmpty else {
            // No POI data — use secondary name or video name
            showFallbackLocation(video: video, fadeOutAfter: fadeOutDuration)
            return
        }

        // Show the entry active at the current position now, then poll:
        // the position is the truth, so loops rewind the text and rate
        // changes shift the cadence for free.
        showCurrentPoiEntry(fadeOutAfter: fadeOutDuration)
        if poiTimeline.count > 1, positionProvider != nil {
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.showCurrentPoiEntry(fadeOutAfter: fadeOutDuration)
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            locationPollTimer = timer
        }
    }

    /// Show the timeline entry active at the current playback position
    /// (the last entry at or before it; the first entry when playback
    /// hasn't reached any). No-op while the entry hasn't changed.
    private func showCurrentPoiEntry(fadeOutAfter: Double?) {
        let position = positionProvider?() ?? 0
        let index = poiTimeline.lastIndex { $0.time <= position } ?? 0
        guard index != lastShownPoiIndex else { return }
        lastShownPoiIndex = index
        showLocationText(poiTimeline[index].text, fadeOutAfter: fadeOutAfter)
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
            guard lat != 0 || lon != 0 else {
                // Current-location weather depends on the Companion's
                // LocationProvider having cached coordinates — the
                // sandboxed extension can't obtain them itself. Without
                // this line the overlay just silently shows nothing
                // (2026-07-12 overlay-connections audit).
                debugLog("⛅ weather \(instance.id.uuidString.prefix(8)) is in current-location mode but no cached coordinates exist — is the Aerial app running with location permission?")
                return nil
            }
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

//
//  LocationProvider.swift
//  Aerial
//
//  Centralized location provider for the Companion app.
//  Pings CLLocationManager hourly and caches coordinates to
//  PrefsTime.cachedLatitude/cachedLongitude for the extension to read.
//

import Foundation
import CoreLocation

class LocationProvider: NSObject {
    static let shared = LocationProvider()

    private let locationManager = CLLocationManager()
    private var refreshTimer: Timer?
    private var isRunning = false

    private override init() {
        super.init()
        locationManager.delegate = self
    }

    // MARK: - Public API

    /// Call from AppDelegate at startup. Checks if location is needed and starts updates if so.
    func startIfNeeded() {
        cacheNightShiftTimes()

        guard isLocationNeeded() else {
            debugLog("LocationProvider: location not needed, skipping")
            return
        }

        debugLog("LocationProvider: location needed, requesting")
        isRunning = true
        // Only ask CLLocationManager for coordinates when we actually need them
        // (solar time / weather). NightShift caching piggybacks on the same
        // timer but doesn't need coordinates — corebrightnessdiag reads system
        // NightShift prefs directly.
        if needsCoordinates() {
            locationManager.requestLocation()
        }

        // Schedule hourly refresh
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            // Don't ping CoreLocation / NightShift during sleep — this hourly
            // Timer fires on Power Nap dark wakes too. Cached coords and solar
            // times are effectively static across a sleep; the next tick after
            // a real wake refreshes them.
            guard !SystemSleepState.shared.isAsleep else {
                debugLog("LocationProvider: hourly refresh skipped (system asleep)")
                return
            }
            debugLog("LocationProvider: hourly refresh")
            if self.needsCoordinates() {
                self.locationManager.requestLocation()
            }
            self.cacheNightShiftTimes()
        }
    }

    /// Re-evaluate after settings change (e.g. overlay editor save).
    func reevaluate() {
        cacheNightShiftTimes()
        if isLocationNeeded() {
            if !isRunning {
                startIfNeeded()
            }
        } else {
            stop()
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        isRunning = false
    }

    // MARK: - Need Detection

    /// True when coordinates (lat/lon) are consumed by some feature — solar time,
    /// weather overlays, etc. NightShift alone does not require coordinates.
    private func needsCoordinates() -> Bool {
        if PrefsTime.timeMode == .locationService {
            return true
        }

        let config = OverlayConfigManager.shared.config
        let allLayouts = [config.sharedLayout]
            + Array(config.screenLayouts.values)
            + [config.desktopSharedLayout].compactMap { $0 }
            + Array((config.desktopScreenLayouts ?? [:]).values)

        for layout in allLayouts {
            for instance in layout.allInstances where instance.kind == .weather {
                let locationMode = instance.typeSettings["locationMode"]?.asString ?? "current"
                if locationMode == "current" {
                    return true
                }
            }
        }

        return false
    }

    private func isLocationNeeded() -> Bool {
        // Solar time adaptation needs coordinates
        if PrefsTime.timeMode == .locationService {
            return true
        }

        // Night Shift mode: ensure hourly timer runs to refresh cached times
        if PrefsTime.timeMode == .nightShift {
            return true
        }

        // Check if any weather overlay uses "current" location
        let config = OverlayConfigManager.shared.config
        let allLayouts = [config.sharedLayout]
            + Array(config.screenLayouts.values)
            + [config.desktopSharedLayout].compactMap { $0 }
            + Array((config.desktopScreenLayouts ?? [:]).values)

        for layout in allLayouts {
            for instance in layout.allInstances where instance.kind == .weather {
                let locationMode = instance.typeSettings["locationMode"]?.asString ?? "current"
                if locationMode == "current" {
                    return true
                }
            }
        }

        // Wi-Fi-restricted downloads need to read the current SSID, and
        // on macOS 14+ `CWInterface.ssid()` is gated on Location auth.
        // We don't actually use the coordinates for this — just the
        // permission grant — but the simplest way to trigger the
        // prompt is to keep Location considered "needed" while the
        // user has Wi-Fi restriction enabled.
        if PrefsCache.restrictOnWiFi {
            return true
        }

        return false
    }

    /// Current Core Location authorization status. Exposed so UI can
    /// distinguish "permission denied / not granted" from "actually
    /// not on Wi-Fi" — both produce `Cache.ssid == ""`.
    var authorizationStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    // MARK: - NightShift Caching

    /// Cache NightShift sunrise/sunset times to PrefsTime so the extension can read them.
    /// Called at startup, hourly, and on settings changes.
    private func cacheNightShiftTimes() {
        guard PrefsTime.timeMode == .nightShift else { return }

        let (isCapable, sunrise, sunset, _) = NightShift.getInformation()
        guard isCapable, let sunrise = sunrise, let sunset = sunset else {
            debugLog("LocationProvider: NightShift not available, skipping cache")
            return
        }

        PrefsTime.cachedNightShiftSunrise = sunrise.timeIntervalSinceReferenceDate
        PrefsTime.cachedNightShiftSunset = sunset.timeIntervalSinceReferenceDate
        debugLog("LocationProvider: cached NightShift times (sunrise=\(sunrise), sunset=\(sunset))")
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationProvider: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        PrefsTime.cachedLatitude = lat
        PrefsTime.cachedLongitude = lon
        debugLog("LocationProvider: cached coordinates (\(lat), \(lon))")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorLog("LocationProvider: location failed: \(error.localizedDescription)")
        // Keep existing cached coordinates — they're still valid
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        debugLog("LocationProvider: auth status changed to \(status.rawValue)")
        if status == .authorized || status == .authorizedAlways {
            if isRunning {
                locationManager.requestLocation()
            }
        }
    }
}

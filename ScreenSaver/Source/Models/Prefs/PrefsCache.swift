//
//  PrefsCache.swift
//  Aerial
//
//  Created by Guillaume Louel on 03/06/2020.
//  Copyright © 2020 Guillaume Louel. All rights reserved.
//

import Foundation

enum CachePeriodicity: Int, Codable {
    case daily, weekly, monthly, never
}

struct PrefsCache {
    // MARK: - Settings Manager

    private static let manager = ScreensaverSettingsManager.shared

    // MARK: - Cache Settings

    static var enableManagement: Bool {
        get { manager.getValue(forKeyPath: \.cache.enableManagement) }
        set { manager.setValue(newValue, forKeyPath: \.cache.enableManagement) }
    }

    // Cache limit (in GiB). Ignored when `unlimitedCache` is true.
    static var cacheLimit: Double {
        get { manager.getValue(forKeyPath: \.cache.cacheLimit) }
        set { manager.setValue(newValue, forKeyPath: \.cache.cacheLimit) }
    }

    // When true, the cache has no size cap — `Cache.hasSomeFreeSpace()`
    // short-circuits to `true` and `freeCache()` becomes a no-op. Replaces
    // the legacy "cacheLimit > 60" sentinel that conflated a real GB budget
    // with an unlimited toggle.
    static var unlimitedCache: Bool {
        get { manager.getValue(forKeyPath: \.cache.unlimitedCache) }
        set { manager.setValue(newValue, forKeyPath: \.cache.unlimitedCache) }
    }

    // How often should cache gets refreshed
    static var intCachePeriodicity: Int {
        get { manager.getValue(forKeyPath: \.cache.intCachePeriodicity) }
        set { manager.setValue(newValue, forKeyPath: \.cache.intCachePeriodicity) }
    }

    static var cachePeriodicity: CachePeriodicity {
        get {
            return CachePeriodicity(rawValue: intCachePeriodicity)!
        }
        set(value) {
            intCachePeriodicity = value.rawValue
        }
    }

    // Do we restrict network traffic on Wi-Fi
    static var restrictOnWiFi: Bool {
        get { manager.getValue(forKeyPath: \.cache.restrictOnWiFi) }
        set { manager.setValue(newValue, forKeyPath: \.cache.restrictOnWiFi) }
    }

    // List of allowed networks (using SSID)
    static var allowedNetworks: [String] {
        get { manager.getValue(forKeyPath: \.cache.allowedNetworks) }
        set { manager.setValue(newValue, forKeyPath: \.cache.allowedNetworks) }
    }

    // Should we override the cache
    static var overrideCache: Bool {
        get { manager.getValue(forKeyPath: \.cache.overrideCache) }
        set { manager.setValue(newValue, forKeyPath: \.cache.overrideCache) }
    }

    // The custom cache path (used when overrideCache is true)
    static var cachePath: String? {
        get { manager.getValue(forKeyPath: \.cache.cachePath) }
        set { manager.setValue(newValue, forKeyPath: \.cache.cachePath) }
    }

    // Timestamp of the last rotation cycle run by DownloadCoordinator's hourly
    // scheduler. Used to gate proactive rotation on the `cachePeriodicity` cadence.
    static var lastRotationRun: Date? {
        get { manager.getValue(forKeyPath: \.cache.lastRotationRun) }
        set { manager.setValue(newValue, forKeyPath: \.cache.lastRotationRun) }
    }
}

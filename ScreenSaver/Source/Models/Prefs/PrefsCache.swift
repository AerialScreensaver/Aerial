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

    // Cache limit (in GiB)
    static var cacheLimit: Double {
        get { manager.getValue(forKeyPath: \.cache.cacheLimit) }
        set { manager.setValue(newValue, forKeyPath: \.cache.cacheLimit) }
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

    // Should we show the download indicator or not
    static var showBackgroundDownloads: Bool {
        get { manager.getValue(forKeyPath: \.cache.showBackgroundDownloads) }
        set { manager.setValue(newValue, forKeyPath: \.cache.showBackgroundDownloads) }
    }

    // Should we override the cache
    static var overrideCache: Bool {
        get { manager.getValue(forKeyPath: \.cache.overrideCache) }
        set { manager.setValue(newValue, forKeyPath: \.cache.overrideCache) }
    }

    // App-scoped bookmark to cache, in NSData form
    static var cacheBookmarkData: Data? {
        get { manager.getValue(forKeyPath: \.cache.cacheBookmarkData) }
        set { manager.setValue(newValue, forKeyPath: \.cache.cacheBookmarkData) }
    }

    // The raw path in string form
    static var cachePath: String? {
        get { manager.getValue(forKeyPath: \.cache.cachePath) }
        set { manager.setValue(newValue, forKeyPath: \.cache.cachePath) }
    }

    // App-scoped bookmark to support, in NSData form
    static var supportBookmarkData: Data? {
        get { manager.getValue(forKeyPath: \.cache.supportBookmarkData) }
        set { manager.setValue(newValue, forKeyPath: \.cache.supportBookmarkData) }
    }

    // The raw path in string form
    static var supportPath: String? {
        get { manager.getValue(forKeyPath: \.cache.supportPath) }
        set { manager.setValue(newValue, forKeyPath: \.cache.supportPath) }
    }
}

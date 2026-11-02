//
//  CompanionSettingsManager.swift
//  Aerial Companion
//

import Foundation

/// Thread-safe manager for Companion settings
/// Loads settings from JSON once, caches in memory, and writes immediately on changes
class CompanionSettingsManager {

    // MARK: - Singleton

    static let shared = CompanionSettingsManager()

    // MARK: - Private Properties

    private var cachedSettings: CompanionSettings
    private var hasLoaded = false
    private let queue = DispatchQueue(label: "com.glouel.companion.settings", attributes: .concurrent)
    private let store = JSONPreferencesStore.shared

    private init() {
        // Initialize with defaults only - no loading or migration during init
        // to avoid circular dependencies with Preferences
        cachedSettings = .default
    }

    // MARK: - Public API

    /// Get a value by key path
    func getValue<T>(forKeyPath keyPath: WritableKeyPath<CompanionSettings, T>) -> T {
        ensureLoaded()
        return queue.sync { cachedSettings[keyPath: keyPath] }
    }

    /// Set a value by key path and write to disk immediately. The cache only
    /// changes when the write succeeded.
    func setValue<T>(_ value: T, forKeyPath keyPath: WritableKeyPath<CompanionSettings, T>) {
        ensureLoaded()
        queue.sync(flags: .barrier) {
            var next = cachedSettings
            next[keyPath: keyPath] = value
            if save(next) { cachedSettings = next }
        }
    }

    // MARK: - Private Methods

    /// The lazy first load mutates the cache, so it runs under the barrier.
    private func ensureLoaded() {
        guard !queue.sync(execute: { hasLoaded }) else { return }
        queue.sync(flags: .barrier) {
            guard !hasLoaded else { return }
            loadSettingsInternal()
            hasLoaded = true
        }
    }

    /// Same contract as `ScreensaverSettingsManager`: an undecodable file
    /// is moved aside (`JSONPreferencesStore.quarantine`), never replaced
    /// with defaults; if even the move fails, writes stay off.
    private var refusingWrites = false

    /// Internal method for loading settings - does NOT access Preferences to avoid circular dependency
    private func loadSettingsInternal() {
        switch store.readChecked(CompanionSettings.self, from: CompanionSettings.fileURL) {
        case .value(let settings):
            cachedSettings = settings
            refusingWrites = false
        case .absent:
            // File doesn't exist - use defaults
            // Migration is handled explicitly by PathMigration, not automatically here
            cachedSettings = .default
            refusingWrites = false
        case .undecodable:
            cachedSettings = .default
            refusingWrites = store.quarantine(CompanionSettings.fileURL) == nil
            errorLog("⚠️ \(CompanionSettings.fileURL.lastPathComponent) undecodable — running on defaults\(refusingWrites ? ", writes refused" : ", file quarantined")")
        }
    }

    /// Returns true when the settings reached disk.
    private func save(_ settings: CompanionSettings) -> Bool {
        let name = CompanionSettings.fileURL.lastPathComponent
        guard !refusingWrites else {
            errorLog("⚠️ \(name) undecodable — refusing to overwrite it with in-memory defaults")
            ScreensaverSettingsManager.postWriteFailure("\(name) is unreadable and was left untouched")
            return false
        }
        guard store.write(settings, to: CompanionSettings.fileURL) else {
            errorLog("[CompanionSettingsManager] Settings were not saved")
            ScreensaverSettingsManager.postWriteFailure("\(name) could not be written")
            return false
        }
        return true
    }
}

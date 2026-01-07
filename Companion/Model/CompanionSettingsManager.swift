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
        return queue.sync {
            // Lazy load on first access
            if !hasLoaded {
                loadSettingsInternal()
                hasLoaded = true
            }
            return cachedSettings[keyPath: keyPath]
        }
    }

    /// Set a value by key path and write to disk immediately
    func setValue<T>(_ value: T, forKeyPath keyPath: WritableKeyPath<CompanionSettings, T>) {
        queue.async(flags: .barrier) {
            // Ensure settings are loaded before setting
            if !self.hasLoaded {
                self.loadSettingsInternal()
                self.hasLoaded = true
            }
            self.cachedSettings[keyPath: keyPath] = value
            self.saveSettings()
        }
    }

    /// Reload settings from disk (useful after migration)
    func reload() {
        queue.async(flags: .barrier) {
            self.loadSettingsInternal()
            self.hasLoaded = true
        }
    }

    /// Force save current settings to disk
    func forceSave() {
        queue.async(flags: .barrier) {
            self.saveSettings()
        }
    }

    // MARK: - Private Methods

    /// Internal method for loading settings - does NOT access Preferences to avoid circular dependency
    private func loadSettingsInternal() {
        // Try to read from JSON file
        if let settings = store.read(CompanionSettings.self, from: CompanionSettings.fileURL) {
            cachedSettings = settings
            print("[CompanionSettingsManager] Loaded settings from \(CompanionSettings.fileURL.path)")
        } else {
            // File doesn't exist - use defaults
            // Migration is handled explicitly by PathMigration, not automatically here
            cachedSettings = .default
            print("[CompanionSettingsManager] Using default settings (file not found)")
        }
    }

    private func saveSettings() {
        store.write(cachedSettings, to: CompanionSettings.fileURL)
    }
}

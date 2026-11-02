//
//  ScreensaverSettingsManager.swift
//  Aerial
//

import Foundation

/// Thread-safe manager for Screensaver settings
/// Loads settings from JSON once, caches in memory, and writes immediately on changes
class ScreensaverSettingsManager {

    // MARK: - Singleton

    static let shared = ScreensaverSettingsManager()

    /// Posted on main when a settings write fails, so the UI can say the change
    /// was not saved instead of silently diverging from disk. `userInfo["error"]`
    /// carries the description. Nothing listens yet (decided 2026-10-13: log +
    /// notification only); the error line already names the file.
    static let writeDidFailNotification = Notification.Name("com.glouel.aerial.settingsWriteDidFail")

    // MARK: - Private Properties

    private var cachedSettings: ScreensaverSettings
    private var hasLoaded = false
    private let queue = DispatchQueue(label: "com.glouel.screensaver.settings", attributes: .concurrent)
    private let store = JSONPreferencesStore.shared

    private init() {
        // Initialize with defaults only - no loading during init
        // to avoid any potential circular dependencies
        cachedSettings = .default
    }

    // MARK: - Public API

    /// Get a value by key path
    func getValue<T>(forKeyPath keyPath: WritableKeyPath<ScreensaverSettings, T>) -> T {
        ensureLoaded()
        return queue.sync { cachedSettings[keyPath: keyPath] }
    }

    /// Set a value by key path and write to disk immediately. The in-memory
    /// cache only changes when the write succeeded, so what the UI shows is
    /// what will be there after a relaunch.
    func setValue<T>(_ value: T, forKeyPath keyPath: WritableKeyPath<ScreensaverSettings, T>) {
        ensureLoaded()
        queue.sync(flags: .barrier) {
            var next = cachedSettings
            next[keyPath: keyPath] = value
            if save(next) { cachedSettings = next }
        }
    }

    /// Drop the in-memory cache and re-read screensaver.json. Needed by
    /// long-lived processes (the wallpaper extension) that must pick up
    /// settings written by Companion after their first lazy load — the
    /// cache is otherwise load-once for the process lifetime.
    func reloadFromDisk() {
        queue.sync(flags: .barrier) {
            self.loadSettingsInternal()
            self.hasLoaded = true
        }
    }

    // MARK: - Private Methods

    /// True while screensaver.json exists but could not be decoded. We then
    /// run on defaults in memory and REFUSE to write them back — a session
    /// on defaults beats silently replacing the user's settings. Companion
    /// moves the file aside (`JSONPreferencesStore.quarantine`) so its next
    /// write is a clean start; the extension never touches the file (an
    /// older build at loginwindow failing on a newer schema must not nuke
    /// it — see the stale-appex notes).
    private var refusingWrites = false

    /// The lazy first load mutates the cache, so it must run under the barrier;
    /// a plain concurrent read of `hasLoaded` decides whether that is needed.
    private func ensureLoaded() {
        guard !queue.sync(execute: { hasLoaded }) else { return }
        queue.sync(flags: .barrier) {
            guard !hasLoaded else { return }
            loadSettingsInternal()
            hasLoaded = true
        }
    }

    /// Internal method for loading settings - does NOT access other Prefs to avoid circular dependency
    private func loadSettingsInternal() {
        switch store.readChecked(ScreensaverSettings.self, from: ScreensaverSettings.fileURL) {
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
            #if COMPANION_APP
            refusingWrites = store.quarantine(ScreensaverSettings.fileURL) == nil
            #else
            refusingWrites = true
            #endif
            errorLog("⚠️ screensaver.json undecodable — running on defaults\(refusingWrites ? ", writes refused" : ", file quarantined")")
        }
    }

    /// Returns true when the settings reached disk.
    private func save(_ settings: ScreensaverSettings) -> Bool {
        guard !refusingWrites else {
            errorLog("⚠️ screensaver.json undecodable — refusing to overwrite it with in-memory defaults")
            Self.postWriteFailure("screensaver.json is unreadable and was left untouched")
            return false
        }
        guard store.write(settings, to: ScreensaverSettings.fileURL) else {
            errorLog("[ScreensaverSettingsManager] Settings were not saved")
            Self.postWriteFailure("screensaver.json could not be written")
            return false
        }
        return true
    }

    static func postWriteFailure(_ message: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: writeDidFailNotification, object: nil, userInfo: ["error": message])
        }
    }
}

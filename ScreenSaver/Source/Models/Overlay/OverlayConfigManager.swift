//
//  OverlayConfigManager.swift
//  Aerial
//
//  Thread-safe singleton for reading and writing overlay configurations.
//  Follows the ScreensaverSettingsManager pattern.
//

import Foundation

class OverlayConfigManager {

    // MARK: - Singleton

    static let shared = OverlayConfigManager()

    // MARK: - Notifications

    static let configDidChangeNotification = Notification.Name("com.glouel.aerial.overlayConfigDidChange")

    /// Distributed notification so the extension can reload when Companion writes
    static let distributedNotificationName = "com.glouel.aerial.overlayConfigChanged"

    // MARK: - Private Properties

    private var cachedConfig: OverlayConfig
    private var hasLoaded = false
    private let queue = DispatchQueue(label: "com.glouel.aerial.overlayconfig", attributes: .concurrent)
    private let store = JSONPreferencesStore.shared

    private init() {
        cachedConfig = .default
    }

    // MARK: - Config Access

    /// Get the full config
    var config: OverlayConfig {
        queue.sync {
            ensureLoaded()
            return cachedConfig
        }
    }

    /// Replace the full config
    func setConfig(_ config: OverlayConfig) {
        queue.sync(flags: .barrier) {
            self.cachedConfig = config
            self.save()
        }
        postNotifications()
    }

    // MARK: - Layout Resolution

    /// Resolve the appropriate layout for a given screen and context
    func layout(for screenUUID: String?, isDesktop: Bool) -> OverlayLayout {
        let cfg = config
        let key = screenUUID.map { resolveScreenKey($0) }
        return cfg.resolvedLayout(for: key, isDesktop: isDesktop)
    }

    /// Write a layout for a given screen and context
    func setLayout(_ layout: OverlayLayout, for screenUUID: String?, isDesktop: Bool) {
        queue.sync(flags: .barrier) {
            ensureLoaded()

            if isDesktop && cachedConfig.separateDesktopConfig {
                if cachedConfig.perScreen, let uuid = screenUUID {
                    let key = resolveScreenKey(uuid)
                    if cachedConfig.desktopScreenLayouts == nil {
                        cachedConfig.desktopScreenLayouts = [:]
                    }
                    cachedConfig.desktopScreenLayouts?[key] = layout
                } else {
                    cachedConfig.desktopSharedLayout = layout
                }
            } else {
                if cachedConfig.perScreen, let uuid = screenUUID {
                    let key = resolveScreenKey(uuid)
                    cachedConfig.screenLayouts[key] = layout
                } else {
                    cachedConfig.sharedLayout = layout
                }
            }

            save()
        }
        postNotifications()
    }

    // MARK: - Private

    private func ensureLoaded() {
        if !hasLoaded {
            loadFromDisk()
            hasLoaded = true
        }
    }

    private func loadFromDisk() {
        if let loaded = store.read(OverlayConfig.self, from: OverlayConfig.fileURL) {
            cachedConfig = loaded
        } else {
            cachedConfig = .default
        }
    }

    private func save() {
        store.write(cachedConfig, to: OverlayConfig.fileURL)
    }

    private func postNotifications() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.configDidChangeNotification, object: nil)
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(Self.distributedNotificationName),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Map a screen UUID to a storage key. "main" is a special key set by the caller.
    private func resolveScreenKey(_ uuid: String) -> String {
        return uuid
    }
}

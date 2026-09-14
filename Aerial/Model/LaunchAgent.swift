//
//  LaunchAgent.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 09/08/2020.
//

import ServiceManagement

struct LaunchAgent {
    /// Path to the legacy LaunchAgent plist (for cleanup only)
    private static let legacyPlistPath: String = {
        let library = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true)[0]
        return (library as NSString).appendingPathComponent("LaunchAgents/com.glouel.AerialUpdaterAgent.plist")
    }()

    /// Remove legacy LaunchAgent plist if it exists (one-time cleanup)
    static func removeLegacyAgentIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyPlistPath) else { return }
        do {
            try fm.removeItem(atPath: legacyPlistPath)
            debugLog("Removed legacy LaunchAgent plist")
        } catch {
            errorLog("Failed to remove legacy LaunchAgent: \(error)")
        }
    }

    /// Sync SMAppService registration with current Preferences.launchMode
    static func update() {
        let service = SMAppService.mainApp
        if Preferences.launchMode == .startup {
            do {
                try service.register()
                debugLog("Registered login item via SMAppService")
            } catch {
                errorLog("Failed to register login item: \(error)")
            }
        } else {
            // Only unregister if currently registered
            if service.status == .enabled {
                do {
                    try service.unregister()
                    debugLog("Unregistered login item via SMAppService")
                } catch {
                    errorLog("Failed to unregister login item: \(error)")
                }
            }
        }
    }

}

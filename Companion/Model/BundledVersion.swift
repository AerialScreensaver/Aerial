//
//  BundledVersion.swift
//  Aerial Companion
//

import Foundation

struct BundledVersion {
    /// Path to the bundled screensaver in the app's Resources
    static let bundledSaverPath: String = {
        if let resourcePath = Bundle.main.resourcePath {
            return (resourcePath as NSString).appendingPathComponent("Aerial.saver")
        }
        return ""
    }()

    /// Check if bundled screensaver exists
    static func exists() -> Bool {
        return FileManager.default.fileExists(atPath: bundledSaverPath)
    }

    /// Get the version of the bundled screensaver
    static func get() -> String {
        if !exists() {
            return "Not bundled"
        }

        let plistPath = (bundledSaverPath as NSString).appendingPathComponent("Contents/Info.plist")

        if let output = Helpers.shell(launchPath: "/usr/bin/defaults",
                                      arguments: ["read", "\(plistPath)", "CFBundleShortVersionString"]) {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // Fallback to Consts value
            return Consts.bundledVersion
        }
    }

    /// Compare bundled version with installed version
    /// Returns true if bundled version is newer than installed
    static func isNewerThanInstalled() -> Bool {
        guard LocalVersion.isInstalled() else {
            return true // If not installed, bundled is "newer"
        }

        let installedVersion = LocalVersion.get()
        let bundledVer = get()

        // Use string comparison with version extension
        return bundledVer.isVersion(greaterThan: installedVersion)
    }

    /// Get detailed version information
    static func getInfo() -> (bundled: String, installed: String, needsUpdate: Bool) {
        let bundledVer = get()
        let installedVer = LocalVersion.isInstalled() ? LocalVersion.get() : "Not installed"

        // Simple string comparison: update if versions don't match
        let needsUpdate = bundledVer != installedVer

        return (bundled: bundledVer, installed: installedVer, needsUpdate: needsUpdate)
    }
}

//
//  ScreensaverManager.swift
//  Aerial Companion
//
//  Created by Claude Code on 02/10/2024.
//

import Foundation
import PaperSaverKit

/// Wrapper for PaperSaver functionality to manage screensaver settings
class ScreensaverManager {
    static let shared = ScreensaverManager()
    private let paperSaver = PaperSaver()

    private init() {}

    // MARK: - Screensaver Status

    /// Check if Aerial is currently the active screensaver
    func isAerialActive() -> Bool {
        let active = paperSaver.getActiveScreensavers()
        return active.contains("Aerial")
    }

    /// Get all currently active screensavers
    func getActiveScreensavers() -> [String] {
        return paperSaver.getActiveScreensavers()
    }

    // MARK: - Screensaver Configuration

    /// Enable Aerial as the screensaver across all displays
    func enableAerial() async throws {
        CompanionLogging.debugLog("Enabling Aerial screensaver via PaperSaver...")
        try await paperSaver.setScreensaverEverywhere(module: "Aerial")
        CompanionLogging.debugLog("Aerial screensaver enabled successfully")
    }

    /// Set screensaver idle time in seconds
    /// - Parameter seconds: Number of seconds before screensaver activates
    func setIdleTime(seconds: Int) throws {
        CompanionLogging.debugLog("Setting screensaver idle time to \(seconds) seconds")
        try paperSaver.setIdleTime(seconds: seconds)
    }

    /// Set screensaver idle time in minutes (convenience method)
    /// - Parameter minutes: Number of minutes before screensaver activates
    func setIdleTime(minutes: Int) throws {
        try setIdleTime(seconds: minutes * 60)
    }

    // MARK: - Screensaver Discovery

    /// List all available screensavers on the system
    func listAvailableScreensavers() -> [ScreensaverModule] {
        return paperSaver.listAvailableScreensavers()
    }

    /// Check if Aerial screensaver is installed and available
    func isAerialAvailable() -> Bool {
        let available = listAvailableScreensavers()
        return available.contains(where: { $0.name == "Aerial" })
    }

    // MARK: - Convenience Methods

    /// Ensure Aerial is installed and enabled
    /// - Returns: True if Aerial is now active, false otherwise
    func ensureAerialEnabled() async -> Bool {
        // First check if installed
        guard LocalVersion.isInstalled() else {
            CompanionLogging.errorLog("Cannot enable Aerial - not installed")
            return false
        }

        // Check if already active
        if isAerialActive() {
            CompanionLogging.debugLog("Aerial already active")
            return true
        }

        // Try to enable it
        do {
            try await enableAerial()
            return isAerialActive()
        } catch {
            CompanionLogging.errorLog("Failed to enable Aerial: \(error.localizedDescription)")
            return false
        }
    }

    /// Get screensaver status for UI display
    func getStatus() -> String {
        if !LocalVersion.isInstalled() {
            return "Not installed"
        }

        if isAerialActive() {
            return "Active"
        }

        if isAerialAvailable() {
            return "Installed but not active"
        }

        return "Installed"
    }
}

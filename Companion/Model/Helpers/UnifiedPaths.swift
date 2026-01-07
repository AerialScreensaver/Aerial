//
//  UnifiedPaths.swift
//  AerialCompanion
//
//  Unified path management for Aerial Companion
//  All Aerial data now lives in /Users/Shared/Aerial/
//

import Foundation
import AppKit

/// Companion-specific path initialization and management
/// Uses shared AerialPaths constants for path locations
/// Contains UI and initialization logic specific to the Companion app
struct UnifiedPaths {

    // MARK: - Initialization

    /// Ensures the base Aerial directory exists and is properly configured
    /// This should be called VERY EARLY during app startup, before any file operations
    ///
    /// - Returns: true if successful, false if there was an error
    static func ensureBaseDirectory() -> Bool {
        let fileManager = FileManager.default
        let basePath = AerialPaths.baseDirectory
        let markerPath = basePath + "/" + AerialPaths.companionMarker

        CompanionLogging.debugLog("🚀 UnifiedPaths: Starting initialization")

        // Step 1: Check if base directory exists
        var alreadyInitialized = false

        if fileManager.fileExists(atPath: basePath) {
            CompanionLogging.debugLog("🚀 UnifiedPaths: Base directory exists, checking for companion.json")

            // Check for companion.json marker
            if fileManager.fileExists(atPath: markerPath) {
                CompanionLogging.debugLog("🚀 UnifiedPaths: Already initialized, ensuring subdirectories exist")
                alreadyInitialized = true
                // Don't return - continue to subdirectory creation below
            } else {
                // Directory exists but no companion.json - user might have created it
                // Rename it to preserve any user data
                CompanionLogging.debugLog("🚀 UnifiedPaths: Pre-existing folder found without companion.json, renaming")
                let renamedPath = "/Users/Shared/Aerial-user"
                var finalRenamedPath = renamedPath

                do {
                    // Check if Aerial-user already exists
                    if fileManager.fileExists(atPath: renamedPath) {
                        // Add timestamp to make it unique
                        let timestamp = Int(Date().timeIntervalSince1970)
                        finalRenamedPath = "/Users/Shared/Aerial-user-\(timestamp)"
                        try fileManager.moveItem(atPath: basePath, toPath: finalRenamedPath)
                        CompanionLogging.debugLog("🚀 UnifiedPaths: Renamed to \(finalRenamedPath)")
                    } else {
                        try fileManager.moveItem(atPath: basePath, toPath: renamedPath)
                        CompanionLogging.debugLog("🚀 UnifiedPaths: Renamed to Aerial-user")
                    }

                    // Inform user about the rename
                    showRenameNotification(newPath: finalRenamedPath)
                } catch {
                    CompanionLogging.errorLog("🚀 UnifiedPaths: Failed to rename pre-existing folder: \(error.localizedDescription)")
                    showPermissionError(details: "Could not rename existing /Users/Shared/Aerial/ folder.\n\nError: \(error.localizedDescription)")
                    return false
                }
            }
        }

        // Step 2: Create base directory (skip if already initialized)
        if !alreadyInitialized {
            CompanionLogging.debugLog("🚀 UnifiedPaths: Creating base directory")
            do {
                try fileManager.createDirectory(
                    atPath: basePath,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                CompanionLogging.errorLog("🚀 UnifiedPaths: Failed to create base directory: \(error.localizedDescription)")
                showPermissionError(details: "Could not create /Users/Shared/Aerial/ directory.\n\nError: \(error.localizedDescription)")
                return false
            }

            // Step 3: Create companion.json marker (empty file)
            CompanionLogging.debugLog("🚀 UnifiedPaths: Creating companion.json marker")
            do {
                try "".write(toFile: markerPath, atomically: true, encoding: .utf8)
            } catch {
                CompanionLogging.errorLog("🚀 UnifiedPaths: Failed to create companion.json: \(error.localizedDescription)")
                showPermissionError(details: "Could not create companion.json marker file.\n\nError: \(error.localizedDescription)")
                return false
            }
        }

        // Step 4: ALWAYS ensure subdirectories exist (even if already initialized)
        // This ensures Logs, My Videos, etc. exist regardless of init state
        CompanionLogging.debugLog("🚀 UnifiedPaths: Ensuring subdirectories exist")

        // Create Logs subdirectory
        let logsPath = AerialPaths.logsPath()
        do {
            try fileManager.createDirectory(
                atPath: logsPath,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            CompanionLogging.errorLog("🚀 UnifiedPaths: Failed to create Logs directory: \(error.localizedDescription)")
            // Non-fatal, but log it
        }

        // Create "My Videos" directory for user's personal videos
        let myVideosPath = AerialPaths.myVideosPath()
        do {
            try fileManager.createDirectory(
                atPath: myVideosPath,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            CompanionLogging.errorLog("🚀 UnifiedPaths: Failed to create My Videos directory: \(error.localizedDescription)")
            // Non-fatal, but log it
        }

        CompanionLogging.debugLog("🚀 UnifiedPaths: Initialization complete!")
        return true
    }

    // MARK: - Helper Methods (Delegate to AerialPaths)

    /// Check if the base directory is already initialized
    static func isInitialized() -> Bool {
        return AerialPaths.isInitialized()
    }

    /// Get the full path for the Logs directory
    static func logsPath() -> String {
        return AerialPaths.logsPath()
    }

    /// Get the full path for the Cache directory
    static func cachePath() -> String {
        return AerialPaths.cachePath()
    }

    /// Get the full path for the Thumbnails directory
    static func thumbnailsPath() -> String {
        return AerialPaths.thumbnailsPath()
    }

    /// Get the full path for the Sources directory
    static func sourcesPath() -> String {
        return AerialPaths.sourcesPath()
    }

    // MARK: - User Notifications

    /// Show a notification that we renamed the user's pre-existing folder
    private static func showRenameNotification(newPath: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Existing Folder Renamed"
            alert.informativeText = """
            We found an existing /Users/Shared/Aerial/ folder that wasn't created by Aerial Companion.

            To preserve your data, we've renamed it to:
            \(newPath)

            Aerial will now use /Users/Shared/Aerial/ for its data.
            """
            alert.alertStyle = .informational
            alert.icon = NSImage(named: NSImage.infoName)
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Error Handling

    /// Show a permission error dialog to the user
    private static func showPermissionError(details: String) {
        DispatchQueue.main.async {
            Helpers.showErrorAlert(
                question: "Cannot Initialize Aerial Directory",
                text: """
                Aerial needs to create /Users/Shared/Aerial/ but doesn't have permission.

                This may happen if:
                • Permissions are misconfigured
                • Parental controls are active
                • System Integrity Protection is blocking access

                \(details)

                Please check permissions and try again, or contact support.
                """,
                button: "Quit"
            )
        }
    }
}

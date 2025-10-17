//
//  PathMigration.swift
//  Aerial Companion
//
//  Container to unified path migration system
//  Moves data from legacy container path to /Users/Shared/Aerial/
//

import Foundation
import AppKit

/// Migration result type
enum MigrationResult {
    case success(summary: String)
    case failure(error: String, log: String)
    case skipped
}

/// Type of migration the user wants
enum MigrationType {
    case moveData      // Move existing data to unified path
    case startFresh    // Don't migrate, start with empty unified path
    case keepCustom    // Keep using custom cache location
}

struct PathMigration {

    // MARK: - Detection

    /// Check if migration is needed
    /// Returns true if we should show the migration UI
    static func needsMigration() -> Bool {
        // Already on new system?
        let companionJsonPath = "/Users/Shared/Aerial/companion.json"
        if FileManager.default.fileExists(atPath: companionJsonPath) {
            CompanionLogging.debugLog("🚚 Migration: companion.json exists, already on new system")
            return false
        }

        // Check if old data exists
        let hasContainerData = containerDataExists()
        let hasCustomCache = PrefsCache.overrideCache

        CompanionLogging.debugLog("🚚 Migration: hasContainerData=\(hasContainerData), hasCustomCache=\(hasCustomCache)")

        return hasContainerData || hasCustomCache
    }

    /// Check if container data exists
    static func containerDataExists() -> Bool {
        let containerPath = getContainerPath()
        return FileManager.default.fileExists(atPath: containerPath)
    }

    /// Get the legacy container path
    static func getContainerPath() -> String {
        let home = NSHomeDirectory()
        return home + "/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/Aerial"
    }

    /// Calculate size of container data in GB
    static func getContainerDataSize() -> Double {
        let path = getContainerPath()
        return Cache.getDirectorySize(directory: path)
    }

    // MARK: - Migration Operations

    /// Perform the actual migration (MOVE operation)
    /// This runs on a background thread and calls progress callback
    static func performMigration(
        type: MigrationType,
        progressCallback: @escaping (String) -> Void,
        completion: @escaping (MigrationResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            switch type {
            case .moveData:
                migrateContainerData(progressCallback: progressCallback, completion: completion)
            case .startFresh:
                markAsFresh(completion: completion)
            case .keepCustom:
                markAsCustom(completion: completion)
            }
        }
    }

    /// Move data from container to unified path
    private static func migrateContainerData(
        progressCallback: @escaping (String) -> Void,
        completion: @escaping (MigrationResult) -> Void
    ) {
        let fileManager = FileManager.default
        let containerPath = getContainerPath()
        let targetPath = "/Users/Shared/Aerial"
        var migrationLog: [String] = []

        CompanionLogging.debugLog("🚚 Migration: Starting move from \(containerPath)")
        migrationLog.append("Migration started: \(Date())")

        do {
            // Create subdirectories
            progressCallback("Creating directory structure...")
            try fileManager.createDirectory(atPath: targetPath + "/Sources", withIntermediateDirectories: true, attributes: nil)
            migrationLog.append("✓ Created Sources/ directory")

            try fileManager.createDirectory(atPath: targetPath + "/Logs", withIntermediateDirectories: true, attributes: nil)
            migrationLog.append("✓ Created Logs/ directory")

            // MOVE Cache/ directory
            let cachePath = containerPath + "/Cache"
            if fileManager.fileExists(atPath: cachePath) {
                progressCallback("Moving Cache directory...")
                CompanionLogging.debugLog("🚚 Migration: Moving Cache/")

                let targetCachePath = targetPath + "/Cache"
                // Remove target if it exists (shouldn't happen, but be safe)
                if fileManager.fileExists(atPath: targetCachePath) {
                    try fileManager.removeItem(atPath: targetCachePath)
                }

                try fileManager.moveItem(atPath: cachePath, toPath: targetCachePath)
                migrationLog.append("✓ Moved Cache/")
                CompanionLogging.debugLog("🚚 Migration: Cache/ moved successfully")
            }

            // MOVE Thumbnails/ directory
            let thumbnailsPath = containerPath + "/Thumbnails"
            if fileManager.fileExists(atPath: thumbnailsPath) {
                progressCallback("Moving Thumbnails directory...")
                CompanionLogging.debugLog("🚚 Migration: Moving Thumbnails/")

                let targetThumbnailsPath = targetPath + "/Thumbnails"
                if fileManager.fileExists(atPath: targetThumbnailsPath) {
                    try fileManager.removeItem(atPath: targetThumbnailsPath)
                }

                try fileManager.moveItem(atPath: thumbnailsPath, toPath: targetThumbnailsPath)
                migrationLog.append("✓ Moved Thumbnails/")
                CompanionLogging.debugLog("🚚 Migration: Thumbnails/ moved successfully")
            }

            // MOVE all source directories to Sources/
            progressCallback("Moving source directories...")
            let contents = try fileManager.contentsOfDirectory(atPath: containerPath)

            for item in contents {
                let itemPath = containerPath + "/" + item
                var isDirectory: ObjCBool = false

                if fileManager.fileExists(atPath: itemPath, isDirectory: &isDirectory),
                   isDirectory.boolValue,
                   !["Cache", "Thumbnails"].contains(item) {

                    CompanionLogging.debugLog("🚚 Migration: Moving source \(item)")
                    progressCallback("Moving source: \(item)...")

                    let targetSourcePath = targetPath + "/Sources/" + item
                    if fileManager.fileExists(atPath: targetSourcePath) {
                        try fileManager.removeItem(atPath: targetSourcePath)
                    }

                    try fileManager.moveItem(atPath: itemPath, toPath: targetSourcePath)
                    migrationLog.append("✓ Moved source: \(item)")
                }
            }

            // Create companion.json marker to indicate migration complete
            let companionJsonPath = targetPath + "/companion.json"
            try "".write(toFile: companionJsonPath, atomically: true, encoding: .utf8)
            migrationLog.append("✓ Created companion.json marker")

            // Save migration log
            let logPath = targetPath + "/Logs/migration.log"
            let logContent = migrationLog.joined(separator: "\n")
            try logContent.write(toFile: logPath, atomically: true, encoding: .utf8)

            CompanionLogging.debugLog("🚚 Migration: Complete!")

            let summary = """
            Migration completed successfully!

            Moved \(migrationLog.count - 1) items to /Users/Shared/Aerial/

            Your old container directory at:
            \(containerPath)

            can now be safely deleted if desired.
            """

            completion(.success(summary: summary))

        } catch {
            CompanionLogging.errorLog("🚚 Migration: Failed - \(error.localizedDescription)")
            migrationLog.append("✗ Migration failed: \(error.localizedDescription)")

            // Save error log
            let logPath = targetPath + "/Logs/migration-error.log"
            let logContent = migrationLog.joined(separator: "\n")
            try? logContent.write(toFile: logPath, atomically: true, encoding: .utf8)

            let errorMessage = """
            Migration failed with error:
            \(error.localizedDescription)

            Error log saved to:
            \(logPath)

            Some files may have been moved. Please check the log for details.
            """

            completion(.failure(error: errorMessage, log: logContent))
        }
    }

    /// Mark as starting fresh (no migration)
    private static func markAsFresh(completion: @escaping (MigrationResult) -> Void) {
        CompanionLogging.debugLog("🚚 Migration: Marked as fresh start")

        let targetPath = "/Users/Shared/Aerial"
        let fileManager = FileManager.default

        // Create base directory if needed
        try? fileManager.createDirectory(atPath: targetPath, withIntermediateDirectories: true, attributes: nil)

        // Create companion.json marker
        let companionJsonPath = targetPath + "/companion.json"
        try? "".write(toFile: companionJsonPath, atomically: true, encoding: .utf8)

        DispatchQueue.main.async {
            completion(.success(summary: "Starting fresh! Your old data has been left untouched in the container."))
        }
    }

    /// Mark as keeping custom cache location
    private static func markAsCustom(completion: @escaping (MigrationResult) -> Void) {
        CompanionLogging.debugLog("🚚 Migration: Keeping custom cache location")

        let targetPath = "/Users/Shared/Aerial"
        let fileManager = FileManager.default

        // Create base directory if needed
        try? fileManager.createDirectory(atPath: targetPath, withIntermediateDirectories: true, attributes: nil)

        // Create companion.json marker
        let companionJsonPath = targetPath + "/companion.json"
        try? "".write(toFile: companionJsonPath, atomically: true, encoding: .utf8)

        DispatchQueue.main.async {
            completion(.success(summary: "Continuing with your custom cache location."))
        }
    }

    // MARK: - User Type Detection

    /// Determine if this is a custom cache user
    static func isCustomCacheUser() -> Bool {
        return PrefsCache.overrideCache
    }

    /// Get custom cache path if user has one
    static func getCustomCachePath() -> String? {
        if PrefsCache.overrideCache {
            return PrefsCache.supportPath
        }
        return nil
    }

    // MARK: - UI Helpers

    /// Get a user-friendly description of what will be migrated
    static func getMigrationDescription() -> String {
        let size = getContainerDataSize()
        let sizeString = String(format: "%.1f GB", size)

        if isCustomCacheUser() {
            if let customPath = getCustomCachePath() {
                return """
                You're using a custom cache location at:
                \(customPath)

                Would you like to migrate to the new standard location (/Users/Shared/Aerial/)?
                """
            }
        }

        return """
        We found \(sizeString) of Aerial data in the legacy container.

        Aerial now uses a unified data directory at /Users/Shared/Aerial/ that is easier to access.

        What would you like to do?
        """
    }

    /// Open Finder at the old container location
    static func showOldContainerInFinder() {
        let path = getContainerPath()
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
    }

    /// Open Finder at the new unified location
    static func showNewLocationInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: "/Users/Shared/Aerial")
    }
}

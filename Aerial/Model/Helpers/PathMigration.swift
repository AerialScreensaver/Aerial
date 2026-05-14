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
    case moveData              // Move existing data to unified path
    case startFresh            // Don't migrate, start with empty unified path
    case startFreshAndReclaim  // Don't migrate, AND delete the legacy container to reclaim disk space
    case keepCustom            // Keep using custom cache location
}

struct PathMigration {

    // MARK: - Detection

    /// Check if migration is needed
    /// Returns true if we should show the migration UI
    static func needsMigration() -> Bool {
        // Already on new system?
        let companionJsonPath = "/Users/Shared/Aerial/companion.json"
        if FileManager.default.fileExists(atPath: companionJsonPath) {
            debugLog("🚚 Migration: companion.json exists, already on new system")
            return false
        }

        // Check if old data exists
        let hasContainerData = containerDataExists()
        let hasCustomCache = PrefsCache.overrideCache

        debugLog("🚚 Migration: hasContainerData=\(hasContainerData), hasCustomCache=\(hasCustomCache)")

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
            case .startFreshAndReclaim:
                markAsFreshAndReclaim(progressCallback: progressCallback, completion: completion)
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

        debugLog("🚚 Migration: Starting move from \(containerPath)")
        migrationLog.append("Migration started: \(Date())")

        do {
            // Create subdirectories
            progressCallback("Creating directory structure...")
            try fileManager.createDirectory(atPath: targetPath + "/Sources", withIntermediateDirectories: true, attributes: nil)
            migrationLog.append("✓ Created Sources/ directory")

            try fileManager.createDirectory(atPath: targetPath + "/Logs", withIntermediateDirectories: true, attributes: nil)
            migrationLog.append("✓ Created Logs/ directory")

            try fileManager.createDirectory(atPath: targetPath + "/My Videos", withIntermediateDirectories: true, attributes: nil)
            migrationLog.append("✓ Created My Videos/ directory")

            // MOVE Cache/ directory
            let cachePath = containerPath + "/Cache"
            if fileManager.fileExists(atPath: cachePath) {
                progressCallback("Moving Cache directory...")
                debugLog("🚚 Migration: Moving Cache/")

                let targetCachePath = targetPath + "/Cache"
                // Remove target if it exists (shouldn't happen, but be safe)
                if fileManager.fileExists(atPath: targetCachePath) {
                    try fileManager.removeItem(atPath: targetCachePath)
                }

                try fileManager.moveItem(atPath: cachePath, toPath: targetCachePath)
                migrationLog.append("✓ Moved Cache/")
                debugLog("🚚 Migration: Cache/ moved successfully")
            }

            // MOVE Thumbnails/ directory
            let thumbnailsPath = containerPath + "/Thumbnails"
            if fileManager.fileExists(atPath: thumbnailsPath) {
                progressCallback("Moving Thumbnails directory...")
                debugLog("🚚 Migration: Moving Thumbnails/")

                let targetThumbnailsPath = targetPath + "/Thumbnails"
                if fileManager.fileExists(atPath: targetThumbnailsPath) {
                    try fileManager.removeItem(atPath: targetThumbnailsPath)
                }

                try fileManager.moveItem(atPath: thumbnailsPath, toPath: targetThumbnailsPath)
                migrationLog.append("✓ Moved Thumbnails/")
                debugLog("🚚 Migration: Thumbnails/ moved successfully")
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

                    debugLog("🚚 Migration: Moving source \(item)")
                    progressCallback("Moving source: \(item)...")

                    let targetSourcePath = targetPath + "/Sources/" + item
                    if fileManager.fileExists(atPath: targetSourcePath) {
                        try fileManager.removeItem(atPath: targetSourcePath)
                    }

                    try fileManager.moveItem(atPath: itemPath, toPath: targetSourcePath)
                    migrationLog.append("✓ Moved source: \(item)")
                }
            }

            // Migrate Companion settings from UserDefaults to companion.json
            progressCallback("Migrating Aerial settings...")
            let settingsMigrated = migrateCompanionSettings(targetPath: targetPath, migrationLog: &migrationLog, shouldMigrate: true)
            if settingsMigrated {
                migrationLog.append("✓ Migrated Aerial settings to companion.json")
            } else {
                migrationLog.append("✓ Created default Aerial settings")
            }

            // Save migration log
            let logPath = targetPath + "/Logs/migration.log"
            let logContent = migrationLog.joined(separator: "\n")
            try logContent.write(toFile: logPath, atomically: true, encoding: .utf8)

            debugLog("🚚 Migration: Complete!")

            let summary = """
            Migration completed successfully!

            Moved \(migrationLog.count - 1) items to /Users/Shared/Aerial/

            Your old container directory at:
            \(containerPath)

            can now be safely deleted if desired.
            """

            completion(.success(summary: summary))

        } catch {
            errorLog("🚚 Migration: Failed - \(error.localizedDescription)")
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

    // MARK: - Settings Migration

    /// Migrate Companion settings from UserDefaults to companion.json
    /// - Parameters:
    ///   - targetPath: Base path for Aerial data
    ///   - migrationLog: Log array to append messages
    ///   - shouldMigrate: If true, migrate from UserDefaults; if false, always use defaults
    /// - Returns: true if settings were migrated, false if defaults were used
    @discardableResult
    private static func migrateCompanionSettings(targetPath: String, migrationLog: inout [String], shouldMigrate: Bool) -> Bool {
        let companionJsonPath = targetPath + "/companion.json"
        let companionJsonURL = URL(fileURLWithPath: companionJsonPath)

        let settings: CompanionSettings
        var wasMigrated = false

        if shouldMigrate {
            // Check if any UserDefaults settings exist
            let hasUserDefaultsSettings = UserDefaults.standard.object(forKey: "intDesiredVersion") != nil ||
                                          UserDefaults.standard.object(forKey: "intLaunchMode") != nil ||
                                          UserDefaults.standard.object(forKey: "firstTimeSetup") != nil

            if hasUserDefaultsSettings {
                // Migrate from UserDefaults
                settings = CompanionSettings.fromUserDefaults()
                debugLog("🚚 Migration: Migrating settings from UserDefaults")
                migrationLog.append("  - Migrated \(12) settings from UserDefaults")
                wasMigrated = true
            } else {
                // Use defaults
                settings = .default
                debugLog("🚚 Migration: Using default settings (no existing settings found)")
                migrationLog.append("  - Using default settings (no existing settings found)")
            }
        } else {
            // Always use defaults when not migrating
            settings = .default
            debugLog("🚚 Migration: Using default settings (migration disabled)")
            migrationLog.append("  - Using default settings (start fresh)")
        }

        // Write settings to JSON
        let success = JSONPreferencesStore.shared.write(settings, to: companionJsonURL)
        if success {
            debugLog("🚚 Migration: Settings written to \(companionJsonPath)")
        } else {
            errorLog("🚚 Migration: Failed to write settings to \(companionJsonPath)")
            migrationLog.append("  ✗ Warning: Failed to write settings file")
        }

        return wasMigrated && success
    }

    /// Mark as starting fresh (no migration)
    private static func markAsFresh(completion: @escaping (MigrationResult) -> Void) {
        debugLog("🚚 Migration: Marked as fresh start")

        let targetPath = "/Users/Shared/Aerial"
        let fileManager = FileManager.default

        // Create base directory if needed
        try? fileManager.createDirectory(atPath: targetPath, withIntermediateDirectories: true, attributes: nil)

        // Create companion.json with DEFAULT settings (no migration)
        var migrationLog: [String] = []
        migrateCompanionSettings(targetPath: targetPath, migrationLog: &migrationLog, shouldMigrate: false)

        // Create My Videos directory
        try? fileManager.createDirectory(atPath: targetPath + "/My Videos", withIntermediateDirectories: true, attributes: nil)

        DispatchQueue.main.async {
            completion(.success(summary: "Starting fresh! Your old data has been left untouched in the container."))
        }
    }

    /// Start fresh AND remove the legacy container directory to
    /// reclaim disk space. Used by the first-launch migration step
    /// when the user picks "Start fresh" with the reclaim toggle ON.
    /// Defensive: only deletes the exact `getContainerPath()`; logs
    /// failure but never throws — the migration is best-effort and
    /// the wizard must always advance regardless.
    private static func markAsFreshAndReclaim(
        progressCallback: @escaping (String) -> Void,
        completion: @escaping (MigrationResult) -> Void
    ) {
        // Step 1: standard fresh-start setup (companion.json defaults,
        // My Videos dir). We do this BEFORE the deletion so the new
        // unified path is in place even if the cleanup fails.
        let targetPath = "/Users/Shared/Aerial"
        let fileManager = FileManager.default
        try? fileManager.createDirectory(atPath: targetPath, withIntermediateDirectories: true, attributes: nil)
        var migrationLog: [String] = []
        migrateCompanionSettings(targetPath: targetPath, migrationLog: &migrationLog, shouldMigrate: false)
        try? fileManager.createDirectory(atPath: targetPath + "/My Videos", withIntermediateDirectories: true, attributes: nil)

        // Step 2: delete the legacy container if it exists.
        DispatchQueue.main.async { progressCallback("Reclaiming disk space…") }
        let containerPath = getContainerPath()
        if fileManager.fileExists(atPath: containerPath) {
            do {
                try fileManager.removeItem(atPath: containerPath)
                debugLog("🚚 Migration: legacy container removed at \(containerPath)")
            } catch {
                errorLog("🚚 Migration: failed to remove legacy container at \(containerPath): \(error.localizedDescription)")
            }
        } else {
            debugLog("🚚 Migration: legacy container not found at \(containerPath) — nothing to reclaim")
        }

        DispatchQueue.main.async {
            completion(.success(summary: "Starting fresh — old Aerial data has been removed to reclaim disk space."))
        }
    }

    /// Mark as keeping custom cache location
    private static func markAsCustom(completion: @escaping (MigrationResult) -> Void) {
        debugLog("🚚 Migration: Keeping custom cache location")

        let targetPath = "/Users/Shared/Aerial"
        let fileManager = FileManager.default

        // Create base directory if needed
        try? fileManager.createDirectory(atPath: targetPath, withIntermediateDirectories: true, attributes: nil)

        // Create companion.json with settings (migrate if they exist, otherwise use defaults)
        var migrationLog: [String] = []
        migrateCompanionSettings(targetPath: targetPath, migrationLog: &migrationLog, shouldMigrate: true)

        // Create My Videos directory
        try? fileManager.createDirectory(atPath: targetPath + "/My Videos", withIntermediateDirectories: true, attributes: nil)

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
            return PrefsCache.cachePath
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

    /// Open Finder at the old My Videosntainer location
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

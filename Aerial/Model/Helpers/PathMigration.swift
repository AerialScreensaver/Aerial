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

        // Behind the wizard's "Go ahead" (the TCC boundary), before any
        // branch writes companion.json.
        probeLegacyData()
        return legacyDataFound
    }

    // MARK: - Legacy data probe

    /// Results of the last `probeLegacyData()` (main thread). The wizard
    /// probes on "Go ahead"; the upgrade prompt re-probes at launch for
    /// users who skipped because Aerial could not read the data.
    nonisolated(unsafe) private(set) static var legacyDataFound = false
    /// False when 3.x data exists but this process may not read it. On
    /// macOS 26 and later the legacy screen saver engine is an appex with
    /// no app record, so tccd cannot show the "access data from other
    /// apps" prompt for its container: only Full Disk Access opens it, and
    /// without it every read is refused silently. Existence checks
    /// (metadata) still work, which is how the data is found at all.
    nonisolated(unsafe) private(set) static var legacyDataReadable = true
    /// The 3.x saver prefs, when they could be read.
    nonisolated(unsafe) private(set) static var legacyPrefs: LegacySaverPrefs.Loaded?
    nonisolated(unsafe) private static var legacyPrefsDenied = false
    /// The 3.x video cache to import (`<supportPath>/Aerial/Cache`), when it
    /// passes `LegacySaverPrefs.isImportable`. Drives the wizard's custom-cache
    /// step; read on every render, so it is a plain static.
    nonisolated(unsafe) private(set) static var legacyCustomCacheFolder: String?

    /// Looks for 3.x data — the container and the saver prefs — and whether
    /// it can be read; reads the prefs when it can.
    static func probeLegacyData() {
        let fm = FileManager.default
        let containerPath = getContainerPath()
        let containerFound = fm.fileExists(atPath: containerPath)
        var readable = true
        if containerFound {
            do {
                _ = try fm.contentsOfDirectory(atPath: containerPath)
            } catch {
                readable = false
                errorLog("🚚 Migration: cannot read the legacy container \(containerPath): \(error.localizedDescription) — Full Disk Access needed")
            }
        }
        probeLegacyPrefs()
        if legacyPrefsDenied { readable = false }
        // Unreadable prefs count as "found": the container's Preferences
        // folder exists, so a previous Aerial ran here.
        legacyDataFound = containerFound || legacyCustomCacheFolder != nil || legacyPrefsDenied
        legacyDataReadable = readable
        debugLog("🚚 Migration: hasContainerData=\(containerFound), hasCustomCache=\(legacyCustomCacheFolder != nil), readable=\(readable)")
    }

    private static func probeLegacyPrefs() {
        legacyPrefs = nil
        legacyCustomCacheFolder = nil
        legacyPrefsDenied = false
        switch LegacySaverPrefs.load() {
        case .none:
            debugLog("🚚 Migration: no 3.x saver prefs found")
        case .denied:
            legacyPrefsDenied = true
        case .found(let loaded):
            legacyPrefs = loaded
            let prefs = loaded.prefs
            debugLog("🚚 Migration: 3.x saver prefs at \(loaded.path): overrideCache=\(prefs.overrideCache) root=\(prefs.customRoot ?? "none")")
            legacyCustomCacheFolder = prefs.importableCacheFolder()
            if let folder = legacyCustomCacheFolder {
                debugLog("🚚 Migration: 3.x custom cache \(folder) (exists=\(FileManager.default.fileExists(atPath: folder)))")
            }
        }
    }

    /// System Settings › Privacy & Security › Full Disk Access.
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The 4.x prefs for a 3.x cache folder. Each setter writes
    /// screensaver.json synchronously (the store creates /Users/Shared/Aerial
    /// when needed). `Cache.classify` then decides what the folder is: readable
    /// by the extension (under /Users/Shared) or a legacy folder that gets the
    /// Move / Convert offer right after the wizard.
    static func importLegacyCustomCache(folder: String) {
        PrefsCache.overrideCache = true
        PrefsCache.cachePath = folder
        PrefsCache.externalCacheImagePath = nil
        PrefsCache.expansionsAtCacheLocation = false
        Cache.invalidateCachePath()
        debugLog("🚚 Migration: imported 3.x custom cache \(folder)")
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
    /// This runs on a background thread and calls progress callback.
    /// `completion` may arrive on any queue — callers hop to main.
    static func performMigration(
        type: MigrationType,
        progressCallback: @escaping (String) -> Void,
        completion: @escaping (MigrationResult) -> Void
    ) {
        // A finished migration of any kind settles the question: no
        // re-offer from the upgrade prompt.
        let settle: (MigrationResult) -> Void = { result in
            if case .success = result {
                Preferences.legacyMigrationPending = false
            }
            completion(result)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            switch type {
            case .moveData:
                if let folder = legacyCustomCacheFolder {
                    migrateCustomCache(folder: folder, progressCallback: progressCallback, completion: settle)
                } else {
                    migrateContainerData(progressCallback: progressCallback, completion: settle)
                }
            case .startFresh:
                markAsFresh(completion: settle)
            case .startFreshAndReclaim:
                markAsFreshAndReclaim(progressCallback: progressCallback, completion: settle)
            case .keepCustom:
                markAsCustom(completion: settle)
            }
        }
    }

    /// The unified layout's folders (idempotent).
    private static func ensureUnifiedLayout(targetPath: String, log: inout [String]) throws {
        let fileManager = FileManager.default
        for folder in ["Sources", "Logs", "My Videos"] {
            try fileManager.createDirectory(atPath: targetPath + "/" + folder, withIntermediateDirectories: true, attributes: nil)
            log.append("✓ Created \(folder)/ directory")
        }
    }

    /// Move the container's Cache/, Thumbnails/ and source folders into the
    /// unified layout. Replaces whatever the target already holds.
    private static func moveContainerContents(from containerPath: String, to targetPath: String,
                                              log: inout [String], progress: (String) -> Void) throws {
        let fileManager = FileManager.default

        // MOVE Cache/ directory
        let cachePath = containerPath + "/Cache"
        if fileManager.fileExists(atPath: cachePath) {
            progress("Moving Cache directory...")
            debugLog("🚚 Migration: Moving Cache/")

            let targetCachePath = targetPath + "/Cache"
            // Remove target if it exists (shouldn't happen, but be safe)
            if fileManager.fileExists(atPath: targetCachePath) {
                try fileManager.removeItem(atPath: targetCachePath)
            }

            try fileManager.moveItem(atPath: cachePath, toPath: targetCachePath)
            log.append("✓ Moved Cache/")
            debugLog("🚚 Migration: Cache/ moved successfully")
        }

        // MOVE Thumbnails/ directory
        let thumbnailsPath = containerPath + "/Thumbnails"
        if fileManager.fileExists(atPath: thumbnailsPath) {
            progress("Moving Thumbnails directory...")
            debugLog("🚚 Migration: Moving Thumbnails/")

            let targetThumbnailsPath = targetPath + "/Thumbnails"
            if fileManager.fileExists(atPath: targetThumbnailsPath) {
                try fileManager.removeItem(atPath: targetThumbnailsPath)
            }

            try fileManager.moveItem(atPath: thumbnailsPath, toPath: targetThumbnailsPath)
            log.append("✓ Moved Thumbnails/")
            debugLog("🚚 Migration: Thumbnails/ moved successfully")
        }

        // MOVE all source directories to Sources/
        progress("Moving source directories...")
        let contents = try fileManager.contentsOfDirectory(atPath: containerPath)

        for item in contents {
            let itemPath = containerPath + "/" + item
            var isDirectory: ObjCBool = false

            if fileManager.fileExists(atPath: itemPath, isDirectory: &isDirectory),
               isDirectory.boolValue,
               !["Cache", "Thumbnails"].contains(item) {

                debugLog("🚚 Migration: Moving source \(item)")
                progress("Moving source: \(item)...")

                let targetSourcePath = targetPath + "/Sources/" + item
                if fileManager.fileExists(atPath: targetSourcePath) {
                    try fileManager.removeItem(atPath: targetSourcePath)
                }

                try fileManager.moveItem(atPath: itemPath, toPath: targetSourcePath)
                log.append("✓ Moved source: \(item)")
            }
        }
    }

    /// A 3.x custom cache the user wants back at the default location.
    /// Whatever the container still holds moves first (its Cache/ replaces
    /// an existing default cache, so it must precede the merge); then the
    /// 3.x prefs are imported and `moveToDefaultLocation` merges the
    /// folder's videos into the default cache — skipping files already
    /// there, carrying the Time Machine exclusion over, never deleting —
    /// and leaves the prefs at the default. Thumbnails and source folders
    /// stay in the 3.x root; the summary says so. Completion on main.
    private static func migrateCustomCache(
        folder: String,
        progressCallback: @escaping (String) -> Void,
        completion: @escaping (MigrationResult) -> Void
    ) {
        let fileManager = FileManager.default
        let targetPath = "/Users/Shared/Aerial"
        let root = (folder as NSString).deletingLastPathComponent
        var migrationLog: [String] = []
        debugLog("🚚 Migration: 3.x custom cache \(folder) → default location")
        migrationLog.append("Migration started: \(Date())")

        do {
            progressCallback("Creating directory structure...")
            try ensureUnifiedLayout(targetPath: targetPath, log: &migrationLog)
            if containerDataExists() {
                try moveContainerContents(from: getContainerPath(), to: targetPath, log: &migrationLog, progress: progressCallback)
            }
        } catch {
            errorLog("🚚 Migration: Failed - \(error.localizedDescription)")
            migrationLog.append("✗ Migration failed: \(error.localizedDescription)")
            let logPath = targetPath + "/Logs/migration-error.log"
            let logContent = migrationLog.joined(separator: "\n")
            try? logContent.write(toFile: logPath, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                completion(.failure(error: "Migration failed with error:\n\(error.localizedDescription)\n\nError log saved to:\n\(logPath)", log: logContent))
            }
            return
        }

        importLegacyCustomCache(folder: folder)
        let present = fileManager.fileExists(atPath: folder)
        progressCallback(present ? "Moving videos from \(folder)…" : "Drive not connected — nothing to move")
        let logSoFar = migrationLog
        Task {
            let outcome = await LegacyExternalCacheMigration.moveToDefaultLocation(folder: folder, notifyConsumers: false) { step in
                if case .moving(let done, let total) = step, total > 0 {
                    progressCallback("Moving videos… \(done)/\(total)")
                }
            }
            var log = logSoFar
            log.append("✓ Moved \(outcome.moved) video(s) from \(folder) (\(outcome.alreadyInImage) already there, \(outcome.failed) failed)")
            migrateCompanionSettings(targetPath: targetPath, migrationLog: &log, shouldMigrate: true)
            let logContent = log.joined(separator: "\n")
            try? logContent.write(toFile: targetPath + "/Logs/migration.log", atomically: true, encoding: .utf8)
            debugLog("🚚 Migration: 3.x custom cache merged — moved \(outcome.moved), already there \(outcome.alreadyInImage), failed \(outcome.failed)")

            let result: MigrationResult
            if outcome.failed > 0 {
                result = .failure(error: "\(outcome.failed) video(s) could not be moved and stay in \(folder) — see Logs/migration.log.", log: logContent)
            } else if !present {
                result = .success(summary: "The drive holding \(folder) isn't connected — nothing was moved. Aerial 4 uses the default cache and downloads videos again as needed.")
            } else {
                var summary = "Moved \(outcome.moved) video\(outcome.moved == 1 ? "" : "s") from\n\(folder)\nto \(Cache.defaultCachePath)."
                if outcome.alreadyInImage > 0 {
                    summary += " \(outcome.alreadyInImage) were already there."
                }
                summary += "\n\nThumbnails and source folders were left in \(root); delete that folder once you're happy with Aerial 4."
                result = .success(summary: summary)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Move data from container to unified path
    private static func migrateContainerData(
        progressCallback: @escaping (String) -> Void,
        completion: @escaping (MigrationResult) -> Void
    ) {
        let containerPath = getContainerPath()
        let targetPath = "/Users/Shared/Aerial"
        var migrationLog: [String] = []

        debugLog("🚚 Migration: Starting move from \(containerPath)")
        migrationLog.append("Migration started: \(Date())")

        do {
            progressCallback("Creating directory structure...")
            try ensureUnifiedLayout(targetPath: targetPath, log: &migrationLog)
            try moveContainerContents(from: containerPath, to: targetPath, log: &migrationLog, progress: progressCallback)

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

        // The 3.x cache folder becomes the 4.x custom location; the rest of
        // the 3.x root (and the container, if any) is left alone.
        var summary = "Continuing with your custom cache location."
        if let folder = legacyCustomCacheFolder {
            importLegacyCustomCache(folder: folder)
            summary = "Aerial keeps playing from\n\(folder)."
        }

        // Create companion.json with settings (migrate if they exist, otherwise use defaults)
        var migrationLog: [String] = []
        migrateCompanionSettings(targetPath: targetPath, migrationLog: &migrationLog, shouldMigrate: true)

        // Create My Videos directory
        try? fileManager.createDirectory(atPath: targetPath + "/My Videos", withIntermediateDirectories: true, attributes: nil)

        DispatchQueue.main.async {
            completion(.success(summary: summary))
        }
    }

    // MARK: - User Type Detection

    /// A 3.x install with an importable custom cache (see `probeLegacyPrefs`).
    static func isCustomCacheUser() -> Bool {
        legacyCustomCacheFolder != nil
    }

    /// The 3.x cache folder, when there is one to import.
    static func getCustomCachePath() -> String? {
        legacyCustomCacheFolder
    }

    // MARK: - UI Helpers

    /// Get a user-friendly description of what will be migrated
    static func getMigrationDescription() -> String {
        if let folder = legacyCustomCacheFolder {
            let inventory: String
            if FileManager.default.fileExists(atPath: folder) {
                let found = LegacyExternalCacheMigration.inventory(folder: folder)
                inventory = "\(found.count) video\(found.count == 1 ? "" : "s") (\(found.formattedBytes))"
            } else {
                inventory = "drive not connected"
            }
            return """
            Aerial 3 kept its videos in a custom location:
            \(folder) — \(inventory)

            Migrate to Standard Location moves those videos to \(Cache.defaultCachePath), the folder Aerial 4 uses by default.
            Keep Custom Location keeps playing from that folder; if the wallpaper extension can't read it, Aerial offers to move or convert it right after this setup.
            """
        }

        let size = getContainerDataSize()
        let sizeString = String(format: "%.1f GB", size)

        return """
        We found \(sizeString) of Aerial data in the legacy container.

        Aerial now uses a unified data directory at /Users/Shared/Aerial/ that is easier to access.

        What would you like to do?
        """
    }

    /// Open Finder at the old location: the 3.x root for custom-cache users
    /// (it still holds their Thumbnails and sources), else the container.
    static func showOldContainerInFinder() {
        let path = (isCustomCacheUser() ? legacyPrefs?.prefs.customRoot : nil) ?? getContainerPath()
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
    }

    /// Open Finder at the new unified location
    static func showNewLocationInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: "/Users/Shared/Aerial")
    }
}

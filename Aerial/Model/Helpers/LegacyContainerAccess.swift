//
//  LegacyContainerAccess.swift
//  Aerial Companion
//
//  Getting at Aerial 3's data when macOS refuses to let Aerial read it.
//
//  3.x lived in the legacy screen saver engine's sandbox container. Since
//  macOS 26 that container is "App Data" protected, and tccd can never show
//  its "access data from other apps" prompt for it: legacyScreenSaver is an
//  appex inside ScreenSaver.framework with no app record (tccd logs `access
//  requires indirect object have an associated app bundle`), so every read
//  fails silently and only Full Disk Access would open it — which nothing
//  asks for on its own.
//
//  What does work is user intent. When the user picks a folder in an
//  NSOpenPanel, tccd writes a `com.apple.macl` xattr on that folder which
//  lets this app — sandboxed or not — read and write the folder and
//  everything below it: no prompt, no Full Disk Access (verified on macOS
//  27.2 on 2026-10-05; `WallpaperCacheCleaner` relies on the same
//  mechanism for the wallpaper agent's container). One grant on the
//  container's Data/Library covers both Application Support/Aerial and
//  Preferences/com.glouel.Aerial.plist, so `PathMigration` then runs the
//  ordinary migration unchanged.
//
//  When the user would rather not, or the grant does not take, Plan B is a
//  Finder-driven staging folder: Aerial opens the old folder and
//  /Users/Shared/Aerial-migrate side by side, the user drags the files
//  over, and `PathMigration` lays them out from there (`.moveStaged`).
//

import AppKit

enum LegacyContainerAccess {
    /// The folder the Open panel is pre-pointed at. One level above the
    /// data folder so the same grant covers the 3.x prefs plist.
    static let grantFolderPath = NSHomeDirectory()
        + "/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library"
    static var grantFolderURL: URL { URL(fileURLWithPath: grantFolderPath, isDirectory: true) }

    /// Plan B: the folder the user moves the old files into.
    static let stagingPath = "/Users/Shared/Aerial-migrate"

    /// The copy names the OS where the restriction is a known one.
    static var isMacOS27OrLater: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    // MARK: - Tier 1: user-intent grant

    enum GrantOutcome: Equatable {
        /// The data is readable now.
        case granted
        /// The user cancelled the panel.
        case cancelled
        /// The panel returned, but the probe still cannot read the data.
        /// `selectedPath` is what the user picked — a subfolder when they
        /// selected something instead of just clicking the button.
        case refused(selectedPath: String)
    }

    /// Presents the Open panel on the container's Data/Library and asks the
    /// user to click "Grant Access" with nothing selected, then re-probes.
    /// Synchronous (`runModal`), like the cleaner's: both hosts already run
    /// inside a modal session and the panel nests fine. No bookmark is kept:
    /// the app is not sandboxed and the migration runs in this same launch.
    @MainActor
    static func requestAccess() -> GrantOutcome {
        debugLog("🚚 Migration: user-intent grant requested for \(grantFolderPath)")
        let panel = NSOpenPanel()
        panel.message = "Click \"Grant Access\" to let Aerial read the old screen saver's data folder — nothing to select."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = grantFolderURL

        guard panel.runModal() == .OK, let url = panel.url else {
            warnLog("🚚 Migration: grant panel cancelled")
            return .cancelled
        }
        PathMigration.probeLegacyData()
        let readable = PathMigration.legacyDataReadable
        infoLog("🚚 Migration: grant result url=\(url.path) readable=\(readable) macl=\(hasUserIntentGrant(atPath: url.path))")
        return readable ? .granted : .refused(selectedPath: url.path)
    }

    /// Whether a user-intent grant is recorded on `path` (diagnostics only:
    /// the xattr's value is opaque, its presence is what matters).
    static func hasUserIntentGrant(atPath path: String = grantFolderPath) -> Bool {
        getxattr(path, "com.apple.macl", nil, 0, 0, XATTR_NOFOLLOW) > 0
    }

    /// A read attempt on the data folder that leaves `PathMigration`'s probe
    /// results alone (diagnostics only).
    static func canReadContainer() -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: PathMigration.getContainerPath())) != nil
    }

    // MARK: - Plan B: Finder + staging folder

    static func prepareStaging() throws {
        try FileManager.default.createDirectory(atPath: stagingPath, withIntermediateDirectories: true, attributes: nil)
    }

    static func revealStaging() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: stagingPath)
    }

    /// Finder on the old data folder. Finder lists it fine even while this
    /// process may not. `selectAerialFolder` shows the folder selected in
    /// its parent (ready for ⌘⌫); otherwise Finder opens inside it, ready
    /// for dragging its contents out.
    static func revealContainer(selectAerialFolder: Bool) {
        let path = PathMigration.getContainerPath()
        if selectAerialFolder {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
    }

    static func stagingHasContent() -> Bool {
        stagingHasContent(entries: entries(of: stagingPath))
    }

    /// Items that never count as "something to migrate" (or as leftovers):
    /// Finder droppings and the 3.x files that have no 4.x equivalent.
    static let ignorableNames: Set<String> = [".DS_Store", ".localized", "AerialLog.txt", "Weather.json"]

    static func stagingHasContent(entries: [String]) -> Bool {
        !stagingLeftovers(entries: entries).isEmpty
    }

    static func stagingLeftovers(entries: [String]) -> [String] {
        entries.filter { !ignorableNames.contains($0) }.sorted()
    }

    /// Where the 3.x layout starts inside the staging folder: the folder
    /// itself when Cache/ or Thumbnails/ sit at its root, else a single
    /// `Aerial` folder when the user dragged the whole folder over instead
    /// of its contents.
    static func stagedSourceRoot(in staging: String, fm: FileManager = .default) -> String {
        var isDirectory: ObjCBool = false
        for folder in ["Cache", "Thumbnails"] where fm.fileExists(atPath: staging + "/" + folder, isDirectory: &isDirectory) && isDirectory.boolValue {
            return staging
        }
        let nested = staging + "/Aerial"
        if fm.fileExists(atPath: nested, isDirectory: &isDirectory), isDirectory.boolValue {
            return nested
        }
        return staging
    }

    /// Where a dropped 3.x prefs plist may be: at the staging root, or still
    /// inside the `Preferences` folder it came from.
    static func stagedPrefsCandidates(for staging: String = stagingPath) -> [String] {
        [staging + "/com.glouel.Aerial.plist", staging + "/Preferences/com.glouel.Aerial.plist"]
    }

    /// Removes the staging folder when only ignorable items remain; leaves it
    /// (and says what is left) otherwise.
    @discardableResult
    static func removeStagingIfEmpty(path: String = stagingPath) -> Bool {
        let leftovers = stagingLeftovers(entries: entries(of: path))
        guard leftovers.isEmpty else {
            warnLog("🚚 Migration: staging folder \(path) still holds \(leftovers.joined(separator: ", ")) — left in place")
            return false
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            debugLog("🚚 Migration: staging folder removed")
            return true
        } catch {
            errorLog("🚚 Migration: could not remove the staging folder \(path): \(error.localizedDescription)")
            return false
        }
    }

    private static func entries(of path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}

//
//  LegacyExternalCacheMigration.swift
//  Aerial
//
//  The 4.0 → 4.1 bridge for a video cache kept on an external drive.
//  Aerial 4.0 pointed `cachePath` at a plain folder under /Volumes and
//  that worked: its saver could read `/`, and the desktop wallpaper ran
//  inside the unsandboxed Companion. Aerial 4.1's wallpaper extension can
//  read /Users/Shared/ only, so an external cache has to be a disk image
//  attached at `Cache.externalCacheMountPoint` (see ExternalCacheImage).
//
//  A 4.0 user arriving on 4.1 therefore has `Cache.locationKind ==
//  .legacyExternalFolder`: Companion still works (it reads /Volumes), the
//  extension shows "No videos found" forever. This type detects that,
//  drives the offer in the "Welcome to Aerial 4.1" prompt, and converts
//  IN PLACE: the image is created inside the folder the user chose in
//  4.0 and the videos are moved into it. Prefs change only in
//  `ExternalCacheImage.adopt`, after the attach succeeded — a failure
//  leaves the 4.0 configuration untouched. Nothing is ever deleted.
//
//  Companion only. All logging is prefixed 💽 like the image helper.
//

import AppKit
import Foundation

enum LegacyExternalCacheMigration {

    /// The 4.0-style folder, when its drive is mounted right now. Nil when
    /// the configuration is anything else or the drive is unplugged (the
    /// prompt waits for the drive; the mount observer re-checks).
    static var pendingFolder: String? {
        guard let folder = Cache.legacyExternalFolderPath,
              FileManager.default.fileExists(atPath: folder) else { return nil }
        return folder
    }

    /// Set when the user chose "Decide later": no re-prompt on a remount
    /// within this session. The prompt comes back at the next launch.
    nonisolated(unsafe) static var deferredThisSession = false   // main thread only

    struct Inventory: Equatable {
        let count: Int
        let bytes: Int64

        var formattedBytes: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    /// Root-level `.mov` files in `folder` (what 4.0 cached there).
    static func inventory(folder: String) -> Inventory {
        let fm = FileManager.default
        var bytes: Int64 = 0
        let files = ExternalCacheImage.siblingVideos(inFolder: folder)
        for file in files {
            let path = (folder as NSString).appendingPathComponent(file)
            if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                bytes += size.int64Value
            }
        }
        return Inventory(count: files.count, bytes: bytes)
    }

    /// Whether `folder` lives on the volume of an NSWorkspace mount
    /// notification (`volumeURL` is the volume root).
    static func folder(_ folder: String, isOn volumeURL: URL) -> Bool {
        let volume = volumeURL.path
        let root = volume.hasSuffix("/") ? volume : volume + "/"
        return folder == volume || folder.hasPrefix(root)
    }

    /// Whether `folder` is on an external volume — path-based on purpose
    /// (a volume query would wake a sleeping drive). Decides which way out
    /// is offered: a folder on the boot volume can simply move to the
    /// default location (a rename), a /Volumes folder gets the disk image.
    static func isOnExternalVolume(_ folder: String) -> Bool {
        folder.hasPrefix("/Volumes/")
    }

    struct MoveJob: Equatable {
        let src: String
        let dst: String
    }

    /// What `moveToDefaultLocation` will do: root-level `.mov` files of
    /// `folder` → `cacheDir`, pack folders of `<folder>/Expansions` →
    /// `sourcesDir`. Only reads `folder` (no prefs) so it is unit-tested;
    /// destination collisions are decided per item at move time.
    static func plan(folder: String, cacheDir: String, sourcesDir: String) -> [MoveJob] {
        let packsSource = (folder as NSString).appendingPathComponent("Expansions")
        let videos = ExternalCacheImage.siblingVideos(inFolder: folder).map {
            MoveJob(src: (folder as NSString).appendingPathComponent($0),
                    dst: (cacheDir as NSString).appendingPathComponent($0))
        }
        let packs = ExternalCacheImage.siblingPacks(inFolder: folder).map {
            MoveJob(src: (packsSource as NSString).appendingPathComponent($0),
                    dst: (sourcesDir as NSString).appendingPathComponent($0))
        }
        return videos + packs
    }

    enum Step: Equatable {
        case creatingImage
        case attaching
        case moving(done: Int, total: Int)
    }

    /// `alreadyInImage`: items already at the destination (the image for
    /// `convert`, the default location for `moveToDefaultLocation`).
    struct Outcome: Equatable {
        let moved: Int
        let alreadyInImage: Int
        let failed: Int
    }

    /// Convert in place: `Aerial Cache.sparsebundle` inside `folder`,
    /// attached, adopted, then the folder's videos moved into it. `step`
    /// is delivered on main. Throws before any pref changes when the image
    /// can't be created or attached.
    static func convert(folder: String, step: @escaping (Step) -> Void) async throws -> Outcome {
        let image = ExternalCacheImage.shared
        debugLog("💽 legacy external cache: converting \(folder) in place")

        await MainActor.run { step(.creatingImage) }
        // Was the 4.0 folder excluded from Time Machine? Then the image
        // should be too. Read BEFORE adopt (the helper targets the current
        // cache location), applied after — tmutil takes seconds, never on
        // main.
        let wasExcluded = await Task.detached(priority: .utility) { TimeMachine.isExcluded() }.value
        let bundle = try await Task.detached(priority: .userInitiated) { try image.create(inFolder: folder) }.value

        debugLog("💽 legacy external cache: image ready at \(bundle), attaching")
        await MainActor.run { step(.attaching) }
        let device = try await Task.detached(priority: .userInitiated) { try image.attachCandidate(image: bundle) }.value
        await MainActor.run { image.adopt(image: bundle, device: device) }
        debugLog("💽 legacy external cache: adopted (\(device)), moving videos")
        if wasExcluded {
            Task.detached(priority: .utility) { TimeMachine.exclude() }
        }

        await MainActor.run { step(.moving(done: 0, total: 0)) }
        let adoption = await image.adoptSiblingVideos(inFolder: folder) { done, total in
            step(.moving(done: done, total: total))
        }
        await MainActor.run {
            ExternalCacheImage.refreshConsumers(reason: "legacy external cache converted")
        }
        debugLog("💽 converted legacy external cache \(folder): \(adoption.moved) item(s) moved, \(adoption.alreadyInImage) already in the image, \(adoption.failed) failed")
        return Outcome(moved: adoption.moved, alreadyInImage: adoption.alreadyInImage, failed: adoption.failed)
    }

    /// Back to the default location, prefs only. Shared by
    /// `useInternalCache` and `moveToDefaultLocation`.
    private static func applyDefaultLocationPrefs() {
        PrefsCache.overrideCache = false
        PrefsCache.cachePath = nil
        PrefsCache.expansionsAtCacheLocation = false
        Cache.invalidateCachePath()
    }

    /// The other way out for a drive folder: back to the internal cache.
    /// The videos stay on the drive untouched (Settings › Cache can still
    /// convert the folder later); the internal cache fills up again as
    /// needed.
    static func useInternalCache() {
        // Read before the flip — nil once the prefs point at the default.
        let folder = Cache.legacyExternalFolderPath ?? "the folder"
        applyDefaultLocationPrefs()
        ExternalCacheImage.refreshConsumers(reason: "legacy external cache: internal cache chosen")
        debugLog("💽 legacy external cache: user chose the internal cache — videos left in \(folder)")
    }

    /// The other real way out for a folder on the boot volume: the videos
    /// and packs move to the default location (a rename on the same
    /// volume) and the custom location is switched off. Prefs FIRST:
    /// downloads resolve their destination when they finish, so after the
    /// flip nothing new can land in `folder` and the plan enumerated next
    /// is complete (same order as the Settings panel's plain-folder path).
    /// Mirrors `ExternalCacheImage.adoptSiblingVideos`: items already at
    /// the destination are left in place and counted separately, per-item
    /// failures are logged and skipped, nothing is ever deleted. Never
    /// throws and is idempotent, so "Retry" just picks up the leftovers.
    /// `step` is delivered on main. `notifyConsumers: false` skips the
    /// consumer refresh — the first-launch wizard calls this before
    /// `continueStartup()` has brought the consumers up on the final prefs.
    static func moveToDefaultLocation(folder: String, notifyConsumers: Bool = true,
                                      step: @escaping (Step) -> Void) async -> Outcome {
        debugLog("💽 legacy cache: moving \(folder) to the default location")
        await MainActor.run { step(.moving(done: 0, total: 0)) }

        // Was the folder excluded from Time Machine? `tmutil addexclusion`
        // is an xattr on the folder, so the renamed files lose it — carry
        // it over to the default cache. Read BEFORE the prefs flip (the
        // helper targets the current cache location), applied after.
        let wasExcluded = await Task.detached(priority: .utility) { TimeMachine.isExcluded() }.value
        await MainActor.run { applyDefaultLocationPrefs() }

        let cacheDir = Cache.defaultCachePath
        let sourcesDir = Cache.defaultSourcesRoot
        let jobs = plan(folder: folder, cacheDir: cacheDir, sourcesDir: sourcesDir)
        let packCount = jobs.filter { $0.dst.hasPrefix(sourcesDir + "/") }.count
        let videoCount = jobs.count - packCount

        let outcome: Outcome = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try? fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            if packCount > 0 {
                try? fm.createDirectory(atPath: sourcesDir, withIntermediateDirectories: true)
            }
            // tmutil needs the destination to exist. Awaited here (sub-second
            // on a plain folder, unlike a sparsebundle) because Settings
            // re-reads the checkbox as soon as this returns.
            if wasExcluded {
                TimeMachine.exclude()
            }
            var moved = 0
            var already = 0
            var failed = 0
            for (index, job) in jobs.enumerated() {
                if fm.fileExists(atPath: job.dst) {
                    already += 1
                } else {
                    do {
                        try fm.moveItem(atPath: job.src, toPath: job.dst)
                        moved += 1
                    } catch {
                        failed += 1
                        errorLog("💽 legacy cache: could not move \((job.src as NSString).lastPathComponent) to \((job.dst as NSString).deletingLastPathComponent): \(error.localizedDescription)")
                    }
                }
                let done = index + 1
                DispatchQueue.main.async { step(.moving(done: done, total: jobs.count)) }
            }
            return Outcome(moved: moved, alreadyInImage: already, failed: failed)
        }.value

        if notifyConsumers {
            await MainActor.run {
                ExternalCacheImage.refreshConsumers(reason: "legacy cache moved to the default location")
            }
        }
        debugLog("💽 legacy cache: moved \(outcome.moved) of \(videoCount) video(s) and \(packCount) pack(s) from \(folder) into the default cache (\(outcome.alreadyInImage) already there, \(outcome.failed) failed)")
        return outcome
    }
}

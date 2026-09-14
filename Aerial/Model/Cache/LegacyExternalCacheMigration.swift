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

    enum Step: Equatable {
        case creatingImage
        case attaching
        case moving(done: Int, total: Int)
    }

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
        debugLog("💽 converted legacy external cache \(folder): \(adoption.moved) video(s) moved, \(adoption.alreadyInImage) already in the image, \(adoption.failed) failed")
        return Outcome(moved: adoption.moved, alreadyInImage: adoption.alreadyInImage, failed: adoption.failed)
    }

    /// The other way out: back to the internal cache. The videos stay on
    /// the drive untouched (Settings › Cache can still convert the folder
    /// later); the internal cache fills up again as needed.
    static func useInternalCache() {
        PrefsCache.overrideCache = false
        PrefsCache.cachePath = nil
        PrefsCache.expansionsAtCacheLocation = false
        Cache.invalidateCachePath()
        ExternalCacheImage.refreshConsumers(reason: "legacy external cache: internal cache chosen")
        debugLog("💽 legacy external cache: user chose the internal cache — videos left on the drive")
    }
}

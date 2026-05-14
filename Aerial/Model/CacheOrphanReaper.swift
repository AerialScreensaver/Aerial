//
//  CacheOrphanReaper.swift
//  Aerial Companion
//
//  Two-pass reaper for `.mov` files that no `entries.json` references:
//
//   1. **Cache pass** — walks `/Users/Shared/Aerial/Cache/` and deletes
//      `.mov` files whose filename isn't referenced by any video in a
//      cacheable source.
//
//   2. **Pack pass** — for every non-cacheable network source (paid
//      expansion packs), walks `/Users/Shared/Aerial/Sources/<name>/`
//      and deletes `.mov` files not referenced by that source's
//      videos. `manifest.json` / `entries.json` are never touched.
//      A source with **zero** videos in `VideoList` is skipped
//      entirely — refuses to wipe a folder when our view of the
//      manifest looks empty (parse anomaly, fetch race, etc.).
//
//  Triggered by `VideoList` readiness callbacks at launch and after
//  every successful manifest refresh. Idempotent: a process-local
//  snapshot of the previous referenced sets short-circuits
//  consecutive invocations when nothing has changed.
//

import Foundation

final class CacheOrphanReaper {
    static let shared = CacheOrphanReaper()

    private let queue = DispatchQueue(label: "com.glouel.aerial.cache-orphan-reaper", qos: .utility)
    private var previousSnapshot: ReferencedSnapshot? = nil

    private init() {}

    /// What the reaper is told to keep, this session, across both
    /// passes. Equatable so consecutive callbacks can short-circuit
    /// when nothing has changed since the last reap.
    private struct ReferencedSnapshot: Equatable {
        /// Filenames referenced by any cacheable-source video — the
        /// keep-set for `/Users/Shared/Aerial/Cache/`.
        let cache: Set<String>
        /// Filenames referenced per non-cacheable source — the keep-set
        /// for `/Users/Shared/Aerial/Sources/<name>/`. A source key is
        /// only present when `VideoList` had at least one video for it.
        let packs: [String: Set<String>]
    }

    /// One non-cacheable source to walk on the pack pass.
    private struct PackTarget {
        let name: String
        let folderPath: String
        let keep: Set<String>
    }

    /// Entry point — called from the `VideoList.instance.callbacks`
    /// channel. Performs safety guards and the snapshot on the calling
    /// thread (main, per VideoList's callback contract), then
    /// dispatches the directory walk and deletion off-main.
    ///
    /// Marked `@MainActor` because the guards read `DownloadTracker.shared`
    /// (itself main-isolated). The actual filesystem work runs on
    /// `queue` and is nonisolated.
    @MainActor
    func maybeReap() {
        // Guard 1: no downloads in flight (active or queued).
        if DownloadTracker.shared.isDownloading {
            debugLog("[reaper] skip: download in progress")
            return
        }
        let queued = VideoManager.sharedInstance.queuedVideoIds
        if !queued.isEmpty {
            debugLog("[reaper] skip: \(queued.count) download(s) queued")
            return
        }

        // Guard 2: every enabled non-local / non-live source has its
        // manifest cached on disk. If any are missing, our view of the
        // referenced URLs is incomplete and reaping would delete
        // legitimate files.
        for source in SourceList.list {
            guard source.type != .local, source.type != .live else { continue }
            guard source.isEnabled() else { continue }
            guard source.isCached() else {
                debugLog("[reaper] skip: source '\(source.name)' is not cached")
                return
            }
        }

        // Snapshot videos on the calling thread (the addCallback
        // contract delivers on main). Build both keep-sets in the
        // same loop — fast, no extra passes over the array.
        let videosSnapshot = VideoList.instance.videos
        var cacheReferenced: Set<String> = []
        var packReferenced: [String: Set<String>] = [:]
        for video in videosSnapshot {
            for urlString in video.urls.values where !urlString.isEmpty {
                guard let filename = URL(string: urlString)?.lastPathComponent,
                      !filename.isEmpty else { continue }
                if video.source.isCachable {
                    cacheReferenced.insert(filename)
                } else {
                    packReferenced[video.source.name, default: []].insert(filename)
                }
            }
        }

        // Build pack targets — only non-cacheable, enabled, cached
        // sources with at least one referenced filename. The empty-set
        // guard is the critical one: a parse anomaly or a stale fetch
        // can yield a source with no videos in `VideoList`, and we
        // refuse to wipe a folder in that state.
        var packTargets: [PackTarget] = []
        for source in SourceList.list {
            guard source.type != .local, source.type != .live else { continue }
            guard !source.isCachable else { continue }
            guard source.isEnabled() else { continue }
            guard source.isCached() else { continue }
            guard let keep = packReferenced[source.name], !keep.isEmpty else {
                debugLog("[reaper] skip pack '\(source.name)': 0 referenced videos in VideoList")
                continue
            }
            let folder = Cache.supportPath.appending("/Sources/").appending(source.name)
            packTargets.append(PackTarget(name: source.name, folderPath: folder, keep: keep))
        }

        // Idempotency: if both the cache set and each pack set are
        // identical to the previous run, skip the directory walks.
        let snapshot = ReferencedSnapshot(
            cache: cacheReferenced,
            packs: Dictionary(uniqueKeysWithValues: packTargets.map { ($0.name, $0.keep) })
        )
        if let prev = previousSnapshot, prev == snapshot {
            debugLog("[reaper] skip: referenced set unchanged "
                     + "(\(cacheReferenced.count) cache + \(packTargets.count) pack(s))")
            return
        }
        previousSnapshot = snapshot

        let cachePath = Cache.path
        queue.async { [weak self] in
            self?.performCacheReap(in: cachePath, referenced: cacheReferenced)
            self?.performPackReap(targets: packTargets)
        }
    }

    private func performCacheReap(in cachePath: String, referenced: Set<String>) {
        let result = reapFolder(
            label: "cache",
            path: cachePath,
            keep: referenced
        )
        if result.deleted == 0 {
            debugLog("[reaper] cache: no orphans (\(referenced.count) referenced filenames)")
        } else {
            let mb = Double(result.bytes) / 1_000_000.0
            infoLog("[reaper] cache: reaped \(result.deleted) orphan(s), reclaimed \(String(format: "%.1f", mb)) MB")
        }
    }

    private func performPackReap(targets: [PackTarget]) {
        if targets.isEmpty {
            debugLog("[reaper] pack scan: no eligible non-cacheable sources")
            return
        }
        var grandTotalDeleted = 0
        var grandTotalBytes: Int64 = 0
        for target in targets {
            let result = reapFolder(
                label: "pack '\(target.name)'",
                path: target.folderPath,
                keep: target.keep
            )
            if result.deleted > 0 {
                let mb = Double(result.bytes) / 1_000_000.0
                infoLog("[reaper] pack '\(target.name)': reaped \(result.deleted) orphan(s), reclaimed \(String(format: "%.1f", mb)) MB")
            }
            grandTotalDeleted += result.deleted
            grandTotalBytes += result.bytes
        }
        if grandTotalDeleted == 0 {
            debugLog("[reaper] pack scan: no orphans across \(targets.count) source(s)")
        }
    }

    /// Shared per-folder reap step. Lists the directory, skips hidden
    /// entries, subdirectories, and non-`.mov` files (`manifest.json`,
    /// `entries.json`, anything else) — only `.mov` files not in
    /// `keep` are deleted.
    private func reapFolder(label: String, path: String, keep: Set<String>) -> (deleted: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else {
            debugLog("[reaper] cannot list \(label) at \(path) — skipping")
            return (0, 0)
        }
        var deleted = 0
        var bytes: Int64 = 0
        for entry in entries {
            if entry.hasPrefix(".") { continue }
            if !entry.hasSuffix(".mov") { continue }
            if keep.contains(entry) { continue }

            let fullPath = (path as NSString).appendingPathComponent(entry)

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }

            let size = ((try? fm.attributesOfItem(atPath: fullPath)[.size]) as? Int64) ?? 0
            do {
                try fm.removeItem(atPath: fullPath)
                deleted += 1
                bytes += size
                debugLog("[reaper] removed \(label)/\(entry) (\(size) bytes)")
            } catch {
                errorLog("[reaper] failed to remove \(label)/\(entry): \(error.localizedDescription)")
            }
        }
        return (deleted, bytes)
    }
}

//
//  WallpaperContinuity.swift
//  Aerial Companion
//
//  Replaces the desktop wallpaper with a still frame of the currently
//  playing video at key moments (new desktop video, system about to
//  sleep) to keep the wake/login transition visually continuous and
//  let the menubar tint follow the video.
//
//  Gated by `Preferences.replaceWallpaper`. Companion-only module —
//  the .appex extension does no wallpaper work.
//
//  WallpaperAgent caches by URL path (verified empirically — see
//  Scripts/wallpaper_hotreload_test.swift), so every refresh writes
//  to a brand-new file:
//      /Users/Shared/Aerial/WallpaperFrames/wallpaper-<UUID>-<seq>.jpg
//

import AppKit
import AVFoundation
import CoreImage
import PaperSaverKit

/// Identity of a wallpaper we wrote: video + frozen playhead. Two
/// passes with equal identity render the same image, so the second
/// is a guaranteed no-op and can be skipped.
private struct WallpaperIdentity: Equatable {
    let videoID: String
    let timestampMs: Int64
}

/// Cache key for `lastWritten`. Per (screen, space) so each Space
/// gets filled once when content first lands there, and is then
/// skipped on return visits while the content is unchanged.
private struct WallpaperCacheKey: Hashable {
    let screenUUID: String
    let spaceUUID: String
}

final class WallpaperContinuity {
    static let shared = WallpaperContinuity()

    private let frameDirURL: URL = {
        URL(fileURLWithPath: AerialPaths.baseDirectory)
            .appendingPathComponent("WallpaperFrames")
    }()

    /// Monotonic per-screen counter used to mint fresh URLs. Loaded
    /// from disk at start() so numbers don't reset across launches.
    private var sequenceByScreen: [String: Int] = [:]
    private let sequenceLock = NSLock()

    private var started = false

    /// Coalesces rapid Space swipes so we don't fire a wallpaper
    /// capture+write per intermediate Space the user passes through.
    /// Cancelled and rescheduled on every `activeSpaceDidChange`.
    private var spaceChangeWorkItem: DispatchWorkItem?

    /// What we last wrote per (screen, space). Strictly in-memory;
    /// resets on relaunch. A cache hit short-circuits the whole
    /// capture → encode → setDesktopImageURL pipeline.
    private var lastWritten: [WallpaperCacheKey: WallpaperIdentity] = [:]

    /// Used only to query the system space tree for resolving each
    /// screen's current Space UUID. We don't use it to set anything;
    /// `NSWorkspace.setDesktopImageURL` does the actual write.
    private let paperSaver = PaperSaver()

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        try? FileManager.default.createDirectory(at: frameDirURL,
                                                 withIntermediateDirectories: true)
        loadSequenceState()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil)

        // Activate the wallpaper-agent cache cleaner if the user has
        // already opted in and granted folder access in a prior
        // session. Silent at launch — never re-prompts here.
        WallpaperCacheCleaner.shared.bootstrap()
    }

    // MARK: - Trigger 1: new desktop video

    /// Called from `AerialSaverView.coordinatorDidStartVideo` when running
    /// under Companion. Captures a frame and refreshes the wallpaper for
    /// that view's screen.
    func handleNewDesktopVideo(view: AerialSaverView) {
        guard Preferences.replaceWallpaper else { return }

        // Give the player layer a moment to actually display the new video
        // before we ask its output for a buffer; copyPixelBuffer can return
        // nil if no frame has been decoded yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            let tree = self.paperSaver.getNativeSpaceTree()
            self.captureAndWrite(view: view, spaceTree: tree)
        }
    }

    // MARK: - Trigger 2: system about to sleep

    @objc private func handleWillSleep() {
        guard Preferences.replaceWallpaper else { return }
        debugLog("WallpaperContinuity: willSleep — refreshing wallpaper(s)")

        // One tree fetch for both the live-capture loop and the
        // extension-fallback loop below.
        let tree = paperSaver.getNativeSpaceTree()
        let coveredUUIDs = captureAllLiveDesktopViews(spaceTree: tree)

        // Screens not covered by a live Companion view are most likely
        // being driven by the screensaver extension. Reconstruct a frame
        // from the latest playlist-progress sidecar via AVAssetImageGenerator.
        let progress = readProgressSidecar()
        let playlists = readPlaylistSidecar()
        for screen in NSScreen.screens {
            let uuid = screen.screenUuid
            if coveredUUIDs.contains(uuid) { continue }
            applyExtractedFrame(screenUUID: uuid,
                                screen: screen,
                                progress: progress,
                                playlists: playlists,
                                spaceTree: tree)
        }
    }

    // MARK: - Trigger 3: desktop pause (per-view, synchronous)

    /// Refresh the wallpaper for a single desktop view, immediately. Used
    /// from pause hooks (user-pause, occlusion auto-pause) where the player
    /// layer is still showing the frame we want to capture and we don't
    /// want a deferred dispatch to race the pause itself.
    func refreshDesktopWallpaper(view: AerialSaverView) {
        guard Preferences.replaceWallpaper else { return }
        let tree = paperSaver.getNativeSpaceTree()
        captureAndWrite(view: view, spaceTree: tree)
    }

    // MARK: - Trigger 4: desktop mode about to stop (all views, synchronous)

    /// Refresh the wallpaper for every active desktop view, immediately.
    /// Called from `DesktopLauncher` just before the AVPlayer is torn
    /// down so the captured frame is the last thing the user saw.
    func refreshAllActiveDesktopWallpapers() {
        guard Preferences.replaceWallpaper else { return }
        _ = captureAllLiveDesktopViews()
    }

    // MARK: - Trigger 5: user switched Space

    /// macOS stores a wallpaper per Space, so after the user swipes to
    /// a different Space the wallpaper there is whatever was last
    /// applied — likely a macOS default or an old frame. Re-apply on
    /// every Space change while the wallpaper mode is playing so the
    /// frame the user is looking at stays in sync. Scoped to live
    /// playback because we capture from `AerialSaverView`'s player; if
    /// only the screensaver extension is driving the screens there's
    /// no live AVPlayer here to read from.
    @MainActor @objc private func handleActiveSpaceDidChange() {
        guard Preferences.replaceWallpaper else { return }
        guard PlaybackManager.shared.playbackMode == .desktop else { return }

        // Coalesce rapid swipes — each capture+write is a pixel buffer
        // copy, JPEG encode, and `setDesktopImageURL` round-trip.
        spaceChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshAllActiveDesktopWallpapers()
        }
        spaceChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    /// Iterates every Companion-driven AerialSaverView, captures + applies
    /// each in turn, and returns the set of screen UUIDs that produced a
    /// frame (used by willSleep to skip extension-fallback for those).
    /// A screen counts as "covered" whenever a live view exists for it —
    /// even if the cache short-circuited the write, the extension fallback
    /// would just write a stale frame.
    @discardableResult
    private func captureAllLiveDesktopViews(spaceTree: [String: Any]? = nil) -> Set<String> {
        let tree = spaceTree ?? paperSaver.getNativeSpaceTree()
        var covered: Set<String> = []
        for view in AerialSaverView.liveViews() {
            if let uuid = captureAndWrite(view: view, spaceTree: tree) {
                covered.insert(uuid)
            }
        }
        return covered
    }

    // MARK: - Cache-aware capture orchestrator

    /// Resolves the view's identity + current space, checks the
    /// `lastWritten` cache, and either skips the write entirely or
    /// performs the snapshot + capture + write pipeline. Returns the
    /// screen UUID covered by the live view (regardless of skip vs.
    /// write), or `nil` if the view has no usable identity yet.
    @discardableResult
    private func captureAndWrite(view: AerialSaverView,
                                 spaceTree: [String: Any]) -> String? {
        guard let id = view.wallpaperContinuityIdentity() else { return nil }
        let identity = WallpaperIdentity(videoID: id.videoID, timestampMs: id.timestampMs)

        let cacheKey = currentSpaceUUID(for: id.screen, tree: spaceTree)
            .map { WallpaperCacheKey(screenUUID: id.screenUUID, spaceUUID: $0) }

        if let key = cacheKey, lastWritten[key] == identity {
            return id.screenUUID
        }

        guard let snapshot = view.wallpaperContinuitySnapshot() else {
            return id.screenUUID
        }
        if applyLiveCapture(buffer: snapshot.buffer,
                            screenUUID: snapshot.screenUUID,
                            screen: snapshot.screen),
           let key = cacheKey {
            lastWritten[key] = identity
        }
        return snapshot.screenUUID
    }

    /// Walks the PaperSaverKit `getNativeSpaceTree()` output to find the
    /// Space currently active on the given screen. Tree is fetched once
    /// per evaluation pass and passed in to avoid re-walking it per view
    /// in multi-screen setups. Returns nil if the screen isn't present
    /// in the tree (e.g. mid hot-plug) — callers treat nil as "skip the
    /// cache, just write".
    ///
    /// PaperSaverKit stores each monitor under a real Core Graphics
    /// display UUID (e.g. "37D8832A-…"), not the numeric `CGDirectDisplayID`,
    /// so we resolve the screen via `paperSaver.getDisplayUUID(for:)`
    /// rather than stringifying the display ID directly.
    private func currentSpaceUUID(for screen: NSScreen,
                                  tree: [String: Any]) -> String? {
        guard let monitors = tree["monitors"] as? [[String: Any]] else { return nil }
        // Resolve the screen's UUID in the same format PaperSaverKit
        // stores in `monitor["uuid"]` — go through its `listDisplays`
        // so we always match whatever WindowServerDisplayManager uses.
        guard let scrID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID,
              let displayInfo = paperSaver.listDisplays().first(where: { $0.displayID == scrID }) else {
            return nil
        }
        let screenDisplayUUID = displayInfo.uuid
        for monitor in monitors {
            guard let displayUUID = monitor["uuid"] as? String,
                  displayUUID == screenDisplayUUID,
                  let spaces = monitor["spaces"] as? [[String: Any]] else { continue }
            for space in spaces where (space["is_current"] as? Bool) == true {
                if let spaceUUID = space["uuid"] as? String { return spaceUUID }
            }
            return nil
        }
        return nil
    }

    // MARK: - Apply (live capture path)

    /// Returns true iff both the JPEG encode and the system
    /// `setDesktopImageURL` call succeeded — caller uses that signal
    /// to decide whether to populate the `lastWritten` cache.
    private func applyLiveCapture(buffer: CVPixelBuffer,
                                  screenUUID: String,
                                  screen: NSScreen) -> Bool {
        guard let jpeg = encodeJPEG(buffer: buffer) else {
            debugLog("WallpaperContinuity: JPEG encode failed for \(screenUUID)")
            return false
        }
        return writeAndSet(jpeg: jpeg, screenUUID: screenUUID, screen: screen)
    }

    // MARK: - Apply (AVAssetImageGenerator path)

    private func applyExtractedFrame(screenUUID: String,
                                     screen: NSScreen,
                                     progress: PlaylistProgressState?,
                                     playlists: PlaylistState?,
                                     spaceTree: [String: Any]) {
        guard let progress = progress, let playlists = playlists else { return }

        let progEntry = progress.screenProgress[screenUUID] ?? progress.sharedProgress
        let playEntry = playlists.screenPlaylists[screenUUID] ?? playlists.sharedPlaylist
        guard let progEntry = progEntry, let playEntry = playEntry else { return }

        let idx = progEntry.currentIndex
        guard idx >= 0, idx < playEntry.entries.count else { return }
        let videoId = playEntry.entries[idx].videoId
        let timestamp = progEntry.playbackTimestamp ?? 0
        let identity = WallpaperIdentity(
            videoID: videoId,
            timestampMs: Int64(timestamp * 1000)
        )

        // Cache check up front — skip the AVAssetImageGenerator
        // extraction and downstream JPEG encode if the (screen, space)
        // already holds this exact (video, timestamp).
        let cacheKey = currentSpaceUUID(for: screen, tree: spaceTree)
            .map { WallpaperCacheKey(screenUUID: screenUUID, spaceUUID: $0) }
        if let key = cacheKey, lastWritten[key] == identity {
            return
        }

        guard let video = VideoList.instance.videos.first(where: { $0.id == videoId }) else {
            debugLog("WallpaperContinuity: video \(videoId) not in catalog")
            return
        }
        let path = VideoList.instance.localPathFor(video: video)
        guard FileManager.default.fileExists(atPath: path) else {
            debugLog("WallpaperContinuity: no cached file for \(videoId) — skipping")
            return
        }

        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let time = CMTime(seconds: timestamp, preferredTimescale: 600)

        do {
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let jpeg = rep.representation(using: .jpeg,
                                                properties: [.compressionFactor: 0.85]) else {
                debugLog("WallpaperContinuity: extracted-frame JPEG encode failed for \(screenUUID)")
                return
            }
            if writeAndSet(jpeg: jpeg, screenUUID: screenUUID, screen: screen),
               let key = cacheKey {
                lastWritten[key] = identity
            }
        } catch {
            debugLog("WallpaperContinuity: AVAssetImageGenerator failed for \(videoId): \(error.localizedDescription)")
        }
    }

    // MARK: - Apply (shared tail)

    /// Returns true iff both the JPEG write to disk and the system
    /// `setDesktopImageURL` call succeeded. False on any throw.
    private func writeAndSet(jpeg: Data, screenUUID: String, screen: NSScreen) -> Bool {
        let url = nextURL(for: screenUUID)
        do {
            try jpeg.write(to: url, options: .atomic)
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            cleanupOldFiles(for: screenUUID, keep: 3)
            return true
        } catch {
            debugLog("WallpaperContinuity: failed to set wallpaper for \(screenUUID): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - JPEG encoding

    private func encodeJPEG(buffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    // MARK: - Sequence + filesystem

    private func nextURL(for screenUUID: String) -> URL {
        sequenceLock.lock()
        let next = (sequenceByScreen[screenUUID] ?? 0) + 1
        sequenceByScreen[screenUUID] = next
        sequenceLock.unlock()
        return frameDirURL.appendingPathComponent("wallpaper-\(screenUUID)-\(next).jpg")
    }

    private func loadSequenceState() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: frameDirURL, includingPropertiesForKeys: nil) else { return }
        for url in files {
            guard let (uuid, seq) = parseFilename(url) else { continue }
            if (sequenceByScreen[uuid] ?? -1) < seq {
                sequenceByScreen[uuid] = seq
            }
        }
    }

    /// Parses `wallpaper-<UUID>-<seq>.jpg` → (UUID, seq). UUIDs themselves
    /// contain hyphens (8-4-4-4-12), so the sequence is the trailing
    /// integer component after the last dash.
    private func parseFilename(_ url: URL) -> (uuid: String, seq: Int)? {
        guard url.pathExtension == "jpg" else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("wallpaper-") else { return nil }
        let body = String(stem.dropFirst("wallpaper-".count))
        guard let lastDash = body.lastIndex(of: "-") else { return nil }
        let uuid = String(body[..<lastDash])
        let seqStr = body[body.index(after: lastDash)...]
        guard let seq = Int(seqStr) else { return nil }
        return (uuid, seq)
    }

    private func cleanupOldFiles(for screenUUID: String, keep: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: frameDirURL, includingPropertiesForKeys: nil) else { return }
        let matching = files.compactMap { url -> (URL, Int)? in
            guard let (uuid, seq) = parseFilename(url), uuid == screenUUID else { return nil }
            return (url, seq)
        }
        let sorted = matching.sorted { $0.1 > $1.1 }
        for (oldURL, _) in sorted.dropFirst(keep) {
            try? FileManager.default.removeItem(at: oldURL)
        }
    }

    // MARK: - Sidecar reads

    private func readProgressSidecar() -> PlaylistProgressState? {
        guard let data = try? Data(contentsOf: PlaylistProgressState.fileURL) else { return nil }
        return try? JSONDecoder().decode(PlaylistProgressState.self, from: data)
    }

    private func readPlaylistSidecar() -> PlaylistState? {
        guard let data = try? Data(contentsOf: PlaylistState.fileURL) else { return nil }
        return try? JSONDecoder().decode(PlaylistState.self, from: data)
    }
}

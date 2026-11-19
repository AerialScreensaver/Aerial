//
//  LiveFeedResolver.swift
//  Aerial
//
//  Resolves YouTube live URLs to a concrete HLS URL by invoking
//  `yt-dlp -g`. Caches the result in each feed's `resolvedURL` with a
//  TTL so we don't spawn yt-dlp on every playlist rotation.
//  Companion-only.
//

import Foundation

final class LiveFeedResolver {

    // MARK: - Singleton

    static let shared = LiveFeedResolver()

    // MARK: - Config

    /// Feeds with a yt-dlp run in flight — one at a time per feed.
    /// Main-thread only (`resolveYouTube` is called from main).
    private var resolving: Set<UUID> = []
    /// Last `refreshPlaylistFeedsIfNeeded` pass.
    private var lastPlaylistRefresh: Date = .distantPast

    private let resolveQueue = DispatchQueue(label: "com.glouel.aerial.livefeed.resolve", qos: .userInitiated)

    private init() {}

    // MARK: - Public API

    /// Resolve `feed` if needed. Returns immediately if a fresh cached URL
    /// is already on file. Calls `LiveFeedManager.updateResolution` with
    /// the result so the source manifest is refreshed automatically.
    func resolveIfNeeded(_ feed: LiveFeed, force: Bool = false) {
        switch feed.kind {
        case .hls:
            return
        case .youtube:
            resolveYouTube(feed, force: force)
        case .rtsp:
            // The caller's copy may predate the last failure — read the
            // stored feed for the backoff. A forced resolve (Restart
            // button, add/edit) always goes through.
            let lastFailedAt = LiveFeedManager.shared.feed(id: feed.id)?.lastResolveFailedAt
            guard force || LiveFeedResolvePolicy.shouldStartTransmuxer(lastFailedAt: lastFailedAt, now: Date()) else {
                return
            }
            resolveRTSP(feed, force: force)
        }
    }

    // MARK: - Kind-specific paths

    private func resolveYouTube(_ feed: LiveFeed, force: Bool) {
        // Callers arrive on main (UI, status monitor, playlist pop,
        // launch); the in-flight set relies on it.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.resolveYouTube(feed, force: force) }
            return
        }
        if !force, !LiveFeedResolvePolicy.shouldResolve(resolvedURL: feed.resolvedURL,
                                                        resolvedAt: feed.resolvedAt,
                                                        lastFailedAt: feed.lastResolveFailedAt,
                                                        failureCount: feed.resolveFailureCount,
                                                        now: Date()) {
            return
        }

        guard let ytDlp = LiveFeedsTooling.shared.ytDlpPath else {
            debugLog("🎥 yt-dlp not installed — skipping resolve for \(feed.displayName)")
            // Visible on the feed, not only in the log (and subject to the
            // same backoff, so this is not rewritten on every tick).
            LiveFeedManager.shared.recordResolveFailure(id: feed.id, error: Self.ytDlpMissingError)
            return
        }
        guard resolving.insert(feed.id).inserted else { return }

        resolveQueue.async { [feedId = feed.id, sourceURL = feed.sourceURL, displayName = feed.displayName] in
            let result = Self.runYtDlp(ytDlpPath: ytDlp, url: sourceURL)
            if let url = result.url {
                debugLog("🎥 Resolved YouTube feed \(displayName) → \(url)")
            } else {
                debugLog("🎥 Failed to resolve YouTube feed \(displayName)")
            }
            DispatchQueue.main.async {
                self.resolving.remove(feedId)
                if let url = result.url {
                    LiveFeedManager.shared.updateResolution(id: feedId, resolvedURL: url, resolvedAt: Date())
                } else {
                    LiveFeedManager.shared.recordResolveFailure(
                        id: feedId, error: result.error ?? "yt-dlp returned no stream URL"
                    )
                }
            }
        }
    }

    /// Keep every YouTube feed that sits in a playlist resolved, not just
    /// the one on screen: a feed whose turn comes hours later used to
    /// start on an expired URL and fail. Cheap to call often — it runs at
    /// most once per `passInterval`, and each feed is gated by the
    /// policy's refresh age and failure backoff. Never on a dark wake.
    func refreshPlaylistFeedsIfNeeded() {
        let passInterval: TimeInterval = 5 * 60
        let now = Date()
        guard now.timeIntervalSince(lastPlaylistRefresh) >= passInterval,
              !SystemSleepState.shared.isAsleep else { return }
        lastPlaylistRefresh = now
        let inPlaylists = PlaylistManager.shared.videoIDsInPlaylists()
        for feed in LiveFeedManager.shared.allFeeds()
        where feed.kind == .youtube && inPlaylists.contains(feed.id.uuidString) {
            resolveIfNeeded(feed)
        }
    }

    /// Spin up the gateway + an ffmpeg transmuxer for this feed, and
    /// write the loopback URL the extension should play. Idempotent:
    /// calling it again while the transmuxer is alive is a no-op.
    private func resolveRTSP(_ feed: LiveFeed, force: Bool) {
        resolveQueue.async {
            debugLog("🎥 RTSP resolve start for \(feed.displayName): \(feed.sourceURL)")
            do {
                let url = try LiveFeedTransmuxerManager.shared.ensureRunning(for: feed, automatic: !force)
                debugLog("🎥 RTSP feed \(feed.displayName) ready → \(url.absoluteString)")
                DispatchQueue.main.async {
                    LiveFeedManager.shared.updateResolution(
                        id: feed.id,
                        resolvedURL: url.absoluteString,
                        resolvedAt: Date()
                    )
                }
            } catch {
                // An automatic refresh inside the failure backoff started
                // nothing: no new failure to report.
                if LiveFeedTransmuxerManager.isBackoff(error) { return }
                let message = error.localizedDescription
                errorLog("🎥 RTSP transmuxer for \(feed.displayName) failed: \(message)")
                // Clean up any partially-started ffmpeg so the next attempt
                // starts from scratch rather than re-using a dead process.
                LiveFeedTransmuxerManager.shared.stop(feedID: feed.id)
                DispatchQueue.main.async {
                    // The feed keeps its loopback URL and stays in the
                    // extension's manifest: wiping it here took a feed
                    // whose camera blinked out of every playlist until a
                    // manual Restart. The gateway restarts ffmpeg when
                    // the stream is next requested.
                    self.publishRTSPFeeds()
                    // First line only for the panel: the transmuxer appends a
                    // raw tail of ffmpeg's stderr (mostly its version banner).
                    let summary = message.split(separator: "\n").first.map(String.init) ?? message
                    LiveFeedManager.shared.recordResolveFailure(id: feed.id, error: summary)
                    NotificationCenter.default.post(
                        name: LiveFeedManager.resolutionFailedNotification,
                        object: nil,
                        userInfo: [
                            "feedID": feed.id.uuidString,
                            "error": message,
                        ]
                    )
                }
            }
        }
    }

    /// Bring the gateway listener up (no ffmpeg) and give every RTSP feed
    /// its loopback URL, so the feeds are in the extension's manifest and
    /// start on demand. Called at launch — the port changes every launch,
    /// so last session's URLs are wiped by `LiveFeedManager.init` — and
    /// after a failed start. No-op without RTSP feeds or without ffmpeg.
    func publishRTSPFeeds() {
        guard LiveFeedManager.shared.allFeeds().contains(where: { $0.kind == .rtsp }) else { return }
        guard LiveFeedsTooling.shared.ffmpegPath != nil else {
            debugLog("🎥 ffmpeg not installed — RTSP feeds stay unpublished")
            return
        }
        resolveQueue.async {
            do {
                try LiveFeedsGateway.shared.ensureRunning()
            } catch {
                errorLog("🎥 gateway failed to start — RTSP feeds stay unpublished: \(error.localizedDescription)")
                return
            }
            DispatchQueue.main.async {
                LiveFeedManager.shared.publishRTSPURLs { LiveFeedsGateway.shared.playbackURL(for: $0)?.absoluteString }
            }
        }
    }

    /// Walk every feed that needs periodic background refresh and
    /// resolve it. Called at app launch by `AppDelegate`.
    ///
    /// Only YouTube feeds are touched here — their HLS tokens expire
    /// within a couple of hours so we refresh them eagerly. RTSP feeds
    /// are deliberately skipped: spinning up ffmpeg against every
    /// configured camera at launch (including ones not in the current
    /// playlist) would hold live connections to offline cameras and
    /// surface noisy errors. RTSP transmuxers start lazily from the
    /// playlist pre-warm, preview clicks, or the reload button.
    func resolveAllIfNeeded() {
        for feed in LiveFeedManager.shared.allFeeds() where feed.kind == .youtube {
            resolveIfNeeded(feed)
        }
    }

    // MARK: - Private

    /// `url` on success; otherwise `error` carries yt-dlp's own message
    /// (its last `ERROR:` line), shown in the Live Feeds panel.
    private static func runYtDlp(ytDlpPath: String, url: String) -> (url: String?, error: String?) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: ytDlpPath)
        // YouTube only serves demuxed HLS streams these days (video-only +
        // audio-only), so `best` alone matches nothing. Select any m3u8 format
        // and print its master manifest URL, which gives AVPlayer the full
        // adaptive playlist with audio renditions. Falls back to the format's
        // direct URL for sources without a manifest.
        process.arguments = [
            "-f", "best[protocol^=m3u8]/bestvideo*[protocol^=m3u8]/best/bestvideo*",
            "--print", "%(manifest_url,url)s",
            "--no-warnings",
            url,
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            errorLog("🎥 yt-dlp launch failed: \(error.localizedDescription)")
            return (nil, "yt-dlp could not be launched: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? ""
            errorLog("🎥 yt-dlp exited \(process.terminationStatus): \(msg.prefix(400))")
            return (nil, summarize(ytDlpError: msg, status: process.terminationStatus))
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        // --print emits a single line; keep first-non-empty parsing as a guard.
        let first = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return (first, first == nil ? "yt-dlp returned no stream URL" : nil)
    }

    static let ytDlpMissingError = "yt-dlp is not installed"

    /// The actionable hint for a stored resolve error, with this Mac's
    /// package-manager commands.
    static func hint(for error: String) -> String {
        LiveFeedResolveHint.classify(error).text(
            installCommand: LiveFeedsTooling.installCommand("yt-dlp"),
            upgradeCommand: LiveFeedsTooling.installCommand("yt-dlp").replacingOccurrences(of: " install ", with: " upgrade ")
        )
    }

    /// yt-dlp's last `ERROR:` line, without the prefix and the trailing
    /// help text, short enough for one row of the panel.
    static func summarize(ytDlpError stderr: String, status: Int32) -> String {
        let line = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { $0.hasPrefix("ERROR:") }
        guard var text = line.map({ String($0.dropFirst("ERROR:".count)) })?
            .trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return "yt-dlp exited with status \(status)"
        }
        // "[youtube] <id>: message. Use --cookies… See https://…"
        if let cut = text.range(of: ". Use --") ?? text.range(of: " See  https") ?? text.range(of: " See https") {
            text = String(text[..<cut.lowerBound]) + "."
        }
        return String(text.prefix(200))
    }
}

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

    /// YouTube's stream tokens typically expire within a few hours.
    /// Re-resolve once the cached URL is older than this.
    private static let youtubeTTL: TimeInterval = 2 * 60 * 60

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
            resolveRTSP(feed)
        }
    }

    // MARK: - Kind-specific paths

    private func resolveYouTube(_ feed: LiveFeed, force: Bool) {
        if !force,
           let resolved = feed.resolvedURL, !resolved.isEmpty,
           let resolvedAt = feed.resolvedAt,
           Date().timeIntervalSince(resolvedAt) < Self.youtubeTTL {
            return
        }

        guard let ytDlp = LiveFeedsTooling.shared.ytDlpPath else {
            debugLog("🎥 yt-dlp not installed — skipping resolve for \(feed.displayName)")
            return
        }

        resolveQueue.async { [feedId = feed.id, sourceURL = feed.sourceURL, displayName = feed.displayName] in
            let resolved = Self.runYtDlp(ytDlpPath: ytDlp, url: sourceURL)
            if let url = resolved {
                debugLog("🎥 Resolved YouTube feed \(displayName) → \(url)")
            } else {
                debugLog("🎥 Failed to resolve YouTube feed \(displayName)")
            }
            DispatchQueue.main.async {
                LiveFeedManager.shared.updateResolution(
                    id: feedId,
                    resolvedURL: resolved,
                    resolvedAt: resolved == nil ? nil : Date()
                )
            }
        }
    }

    /// Spin up the gateway + an ffmpeg transmuxer for this feed, and
    /// write the loopback URL the extension should play. Idempotent:
    /// calling it again while the transmuxer is alive is a no-op.
    private func resolveRTSP(_ feed: LiveFeed) {
        resolveQueue.async {
            debugLog("🎥 RTSP resolve start for \(feed.displayName): \(feed.sourceURL)")
            do {
                let url = try LiveFeedTransmuxerManager.shared.ensureRunning(for: feed)
                debugLog("🎥 RTSP feed \(feed.displayName) ready → \(url.absoluteString)")
                DispatchQueue.main.async {
                    LiveFeedManager.shared.updateResolution(
                        id: feed.id,
                        resolvedURL: url.absoluteString,
                        resolvedAt: Date()
                    )
                }
            } catch {
                let message = error.localizedDescription
                errorLog("🎥 RTSP transmuxer for \(feed.displayName) failed: \(message)")
                // Clean up any partially-started ffmpeg so the next attempt
                // starts from scratch rather than re-using a dead process.
                LiveFeedTransmuxerManager.shared.stop(feedID: feed.id)
                DispatchQueue.main.async {
                    LiveFeedManager.shared.updateResolution(
                        id: feed.id,
                        resolvedURL: nil,
                        resolvedAt: nil
                    )
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

    private static func runYtDlp(ytDlpPath: String, url: String) -> String? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: ytDlpPath)
        // -g prints the direct stream URL. Prefer an m3u8 format for AVPlayer.
        process.arguments = [
            "-g",
            "-f", "best[protocol^=m3u8]/best",
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
            return nil
        }

        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? ""
            errorLog("🎥 yt-dlp exited \(process.terminationStatus): \(msg.prefix(400))")
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        // yt-dlp can print multiple URLs for combined streams; take the first.
        let first = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return first
    }
}

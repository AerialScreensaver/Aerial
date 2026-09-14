//
//  LiveFeedThumbnailer.swift
//  Aerial
//
//  Generates a single preview frame for each live feed so the Live
//  Feeds library can show something meaningful instead of a generic
//  icon. HLS/RTSP use an off-band ffmpeg probe; YouTube uses
//  `yt-dlp --get-thumbnail` + a URLSession download (avoids running
//  ffmpeg through a remote video stream). Companion-only.
//

import Foundation
import AppKit

final class LiveFeedThumbnailer {

    static let shared = LiveFeedThumbnailer()

    private let queue = DispatchQueue(label: "com.glouel.aerial.livefeed.thumbnailer", qos: .utility)

    private init() {}

    // MARK: - Paths

    /// Thumbnails live alongside the Live Feeds source so they're
    /// wiped when the source folder is regenerated from scratch.
    static var directory: URL {
        URL(fileURLWithPath: Cache.supportPath, isDirectory: true)
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("Live Feeds", isDirectory: true)
            .appendingPathComponent("thumbs", isDirectory: true)
    }

    static func thumbnailURL(for feed: LiveFeed) -> URL {
        directory.appendingPathComponent("\(feed.id.uuidString).jpg")
    }

    static func thumbnailPath(for feed: LiveFeed) -> String? {
        let url = thumbnailURL(for: feed)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    // MARK: - Public API

    /// Generate a thumbnail if one isn't already on disk (or `force`
    /// is true). Idempotent; safe to call on every feed add/update.
    func ensureThumbnail(for feed: LiveFeed, force: Bool = false) {
        let target = Self.thumbnailURL(for: feed)
        if !force, FileManager.default.fileExists(atPath: target.path) {
            return
        }
        queue.async { [weak self] in
            self?.generate(for: feed, target: target)
        }
    }

    /// Drop the thumbnail for `feed` (e.g. when the feed is removed).
    func remove(for feed: LiveFeed) {
        try? FileManager.default.removeItem(at: Self.thumbnailURL(for: feed))
    }

    // MARK: - Private

    private func generate(for feed: LiveFeed, target: URL) {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)

        switch feed.kind {
        case .youtube:
            guard let ytDlp = LiveFeedsTooling.shared.ytDlpPath else {
                debugLog("🎥 thumbnail: yt-dlp missing, skipping \(feed.displayName)")
                return
            }
            if let url = resolveYouTubeThumbnailURL(using: ytDlp, sourceURL: feed.sourceURL) {
                download(url: url, to: target, feed: feed)
            }
        case .hls, .rtsp:
            guard let ffmpeg = LiveFeedsTooling.shared.ffmpegPath else {
                debugLog("🎥 thumbnail: ffmpeg missing, skipping \(feed.displayName)")
                return
            }
            grabFrame(using: ffmpeg, feed: feed, target: target)
        }
    }

    private func grabFrame(using ffmpeg: String, feed: LiveFeed, target: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        var args: [String] = ["-y", "-loglevel", "error"]
        if feed.kind == .rtsp {
            args += ["-rtsp_transport", "tcp"]
        }
        // Re-inject any Keychain-stored credentials for RTSP feeds —
        // the stored URL has them stripped.
        let creds = LiveFeedCredentialStore.load(for: feed.id)
        let effectiveURL = LiveFeedCredentialStore.inject(credentials: creds, into: feed.sourceURL)
        // Seek 2 s in — the first keyframe of an HLS stream is often
        // a black slate, and for RTSP we want ffmpeg past any initial
        // setup handshake.
        args += [
            "-ss", "2",
            "-i", effectiveURL,
            "-frames:v", "1",
            "-q:v", "4",
            target.path,
        ]
        proc.arguments = args
        let stderrPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = stderrPipe

        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: target.path) else {
                let tail = (try? stderrPipe.fileHandleForReading.readToEnd())
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                errorLog("🎥 thumbnail grab failed for \(feed.displayName): \(tail.suffix(300))")
                return
            }
            debugLog("🎥 thumbnail generated for \(feed.displayName)")
            notifyUpdated()
        } catch {
            errorLog("🎥 thumbnail grab launch failed: \(error.localizedDescription)")
        }
    }

    private func resolveYouTubeThumbnailURL(using ytDlp: String, sourceURL: String) -> URL? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ytDlp)
        proc.arguments = ["--get-thumbnail", "--no-warnings", sourceURL]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            errorLog("🎥 yt-dlp thumbnail launch failed: \(error.localizedDescription)")
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let trimmed = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        return URL(string: trimmed)
    }

    /// Downloads the thumbnail URL yt-dlp printed. NSImage handles webp,
    /// png, jpg, etc., so whatever yt-dlp points to we can render — we
    /// just save the raw bytes at `<uuid>.jpg` regardless of extension.
    private func download(url: URL, to target: URL, feed: LiveFeed) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            if let error = error {
                errorLog("🎥 thumbnail download failed for \(feed.displayName): \(error.localizedDescription)")
                return
            }
            guard let data = data, !data.isEmpty else { return }
            do {
                try data.write(to: target, options: .atomic)
                debugLog("🎥 thumbnail saved for \(feed.displayName)")
                self?.notifyUpdated()
            } catch {
                errorLog("🎥 thumbnail write failed: \(error.localizedDescription)")
            }
        }.resume()
    }

    private func notifyUpdated() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: LiveFeedManager.didChangeNotification, object: nil)
        }
    }
}

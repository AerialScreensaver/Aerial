//
//  LiveFeedTransmuxer.swift
//  Aerial
//
//  One per RTSP live feed. Spawns `ffmpeg` on demand to transmux the
//  remote RTSP stream into HLS segments in the gateway's directory, so
//  AVPlayer can consume a 127.0.0.1:PORT/<uuid>/index.m3u8 URL.
//  Companion-only.
//

import Foundation

final class LiveFeedTransmuxer {

    // MARK: - State

    let feedID: UUID
    let sourceURL: String

    private let ffmpegPath: String
    private let outputDir: URL
    private let queue: DispatchQueue
    private var process: Process?
    private var stderrHandle: FileHandle?
    private var stderrBuffer = ""
    private let stderrLock = NSLock()

    /// Latest stderr tail, useful for surfacing errors in the preview window.
    var recentStderr: String {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        return stderrBuffer
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    // MARK: - Init

    init(feedID: UUID, sourceURL: String, ffmpegPath: String, outputDir: URL) {
        self.feedID = feedID
        self.sourceURL = sourceURL
        self.ffmpegPath = ffmpegPath
        self.outputDir = outputDir
        self.queue = DispatchQueue(label: "com.glouel.aerial.transmuxer.\(feedID.uuidString)")
    }

    // MARK: - Control

    /// Spawn ffmpeg. Safe to call repeatedly — returns early if already
    /// running. Throws if the output directory can't be prepared.
    func start() throws {
        if isRunning { return }

        // Clean any stale segments from a previous run so AVPlayer doesn't
        // see an out-of-date playlist.
        try? FileManager.default.removeItem(at: outputDir)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let playlist = outputDir.appendingPathComponent("index.m3u8")
        let segmentPattern = outputDir.appendingPathComponent("seg_%03d.ts")

        // Re-inject any Keychain-stored credentials that `LiveFeedManager`
        // stripped from the persisted URL. Non-RTSP URLs or feeds with
        // no stored credentials come back unchanged.
        let storedCreds = LiveFeedCredentialStore.load(for: feedID)
        let effectiveURL = LiveFeedCredentialStore.inject(credentials: storedCreds, into: sourceURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            // -y: overwrite existing files without prompting
            "-y",
            // Keep stderr at the default info level so the stderr tail
            // captures connection / codec messages, not just warnings.
            // This is what surfaces "Connection refused", "No route to
            // host", "Non-monotonous DTS", etc. into the preview log.
            "-loglevel", "info",
            // RTSP transport — TCP is more reliable than UDP across home
            // networks with NAT / QoS quirks.
            "-rtsp_transport", "tcp",
            "-i", effectiveURL,
            // Copy codec — fast, no transcoding. Most cameras emit
            // H.264 + AAC which AVPlayer accepts directly via HLS.
            "-c", "copy",
            "-f", "hls",
            "-hls_time", "2",
            "-hls_list_size", "5",
            "-hls_flags", "delete_segments+append_list+omit_endlist",
            "-hls_segment_filename", segmentPattern.path,
            playlist.path,
        ]

        let stderrPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = stderrPipe
        stderrHandle = stderrPipe.fileHandleForReading
        let feedPrefix = feedID.uuidString.prefix(8)
        stderrHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.appendStderr(text)
            // Mirror every stderr line into the debug log so we can
            // trace exactly where ffmpeg is stuck when a preview never
            // reaches ready state.
            for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
                debugLog("🎥[\(feedPrefix)] \(line)")
            }
        }

        proc.terminationHandler = { [weak self] p in
            guard let self = self else { return }
            debugLog("🎥 ffmpeg[\(self.feedID.uuidString.prefix(8))] exited code=\(p.terminationStatus)")
            self.stderrHandle?.readabilityHandler = nil
            self.stderrHandle = nil
        }

        debugLog("🎥 ffmpeg[\(feedID.uuidString.prefix(8))] spawning: \(sourceURL)")
        try proc.run()
        process = proc
    }

    /// Block until ffmpeg has written an HLS playlist that references at
    /// least one `.ts` segment, or until the timeout elapses. Throws if
    /// ffmpeg exits before the playlist is ready, including its captured
    /// stderr tail for diagnostics.
    func waitForReady(timeout: TimeInterval = 12.0) throws {
        let playlistPath = outputDir.appendingPathComponent("index.m3u8").path
        let deadline = Date().addingTimeInterval(timeout)
        let fm = FileManager.default
        while Date() < deadline {
            if fm.fileExists(atPath: playlistPath),
               let content = try? String(contentsOfFile: playlistPath, encoding: .utf8),
               content.contains(".ts") {
                return
            }
            // If ffmpeg already died (unreachable source, bad credentials,
            // codec mismatch…) surface the real reason rather than timing
            // out uselessly.
            if let proc = process, !proc.isRunning {
                let tail = String(recentStderr.suffix(500))
                throw NSError(
                    domain: "com.glouel.aerial.transmuxer",
                    code: -10,
                    userInfo: [NSLocalizedDescriptionKey:
                        "ffmpeg exited (code \(proc.terminationStatus)) before producing a playlist. Last stderr:\n\(tail)"]
                )
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let tail = String(recentStderr.suffix(500))
        throw NSError(
            domain: "com.glouel.aerial.transmuxer",
            code: -11,
            userInfo: [NSLocalizedDescriptionKey:
                "ffmpeg did not produce a playable playlist within \(Int(timeout))s. Last stderr:\n\(tail)"]
        )
    }

    /// Terminate ffmpeg (SIGTERM). Idempotent.
    func stop() {
        guard let proc = process, proc.isRunning else {
            process = nil
            return
        }
        debugLog("🎥 ffmpeg[\(feedID.uuidString.prefix(8))] stopping")
        proc.terminate()
        queue.asyncAfter(deadline: .now() + 1.0) { [weak proc] in
            if proc?.isRunning == true {
                // TODO: SIGKILL would be proc.interrupt() — ffmpeg usually
                // responds to SIGTERM within a second, but be gentle here.
                proc?.interrupt()
            }
        }
        process = nil
    }

    // MARK: - Stderr buffer

    private func appendStderr(_ text: String) {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        stderrBuffer.append(text)
        // Keep the buffer bounded to the last ~16 KB.
        if stderrBuffer.count > 16_384 {
            stderrBuffer.removeFirst(stderrBuffer.count - 16_384)
        }
    }
}

// MARK: - Manager

/// Tracks the set of active transmuxers. Exposes a single `ensureRunning`
/// entry point so callers don't have to know about the gateway, ffmpeg
/// path lookup, or whether the feed already has a process.
final class LiveFeedTransmuxerManager {

    static let shared = LiveFeedTransmuxerManager()

    /// A running transmuxer is considered idle — and shut down to save
    /// network/disk bandwidth — if the gateway hasn't served any HTTP
    /// request for it in this long. Five minutes is a generous cushion:
    /// a pre-warmed feed that never gets played won't sit forever, but a
    /// briefly-paused playback won't yank the stream out from under a
    /// user who resumes.
    private static let idleTimeout: TimeInterval = 5 * 60

    private let lock = NSLock()
    private var transmuxers: [UUID: LiveFeedTransmuxer] = [:]
    private var reaperTimer: DispatchSourceTimer?
    /// One start at a time per feed: the gateway (on-demand start), the
    /// resolver (on-screen refresh, Restart button) and the preview can
    /// all ask for the same feed at once, and two concurrent starts
    /// spawned two ffmpeg processes writing the same directory.
    private var startLocks: [UUID: NSLock] = [:]
    /// When each feed's last start failed (guarded by `lock`). Written
    /// and read while holding that feed's start lock, so a caller that
    /// waited behind a failing start sees the failure — the persisted timestamp in live-feeds.json is
    /// written later, on the main queue, and let a second ffmpeg launch
    /// through 400 ms after the first (2026-11-17).
    private var lastStartFailure: [UUID: Date] = [:]

    /// Thrown to an automatic caller inside the failure backoff. Not a
    /// new failure: nothing was started.
    static let backoffErrorCode = -20
    static func isBackoff(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "com.glouel.aerial.transmuxer" && ns.code == backoffErrorCode
    }

    private func startLock(for feedID: UUID) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let existing = startLocks[feedID] { return existing }
        let created = NSLock()
        startLocks[feedID] = created
        return created
    }

    private func startFailure(for feedID: UUID) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastStartFailure[feedID]
    }

    private func setStartFailure(_ date: Date?, for feedID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        lastStartFailure[feedID] = date
    }

    /// Whether ffmpeg is currently running for this feed.
    func isRunning(feedID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return transmuxers[feedID]?.isRunning == true
    }

    /// On-demand start, called by the gateway when a player asks for a
    /// feed's playlist and no transmuxer is running (never started this
    /// session, idle-reaped, or its camera went away). Blocks until the
    /// stream is ready or has failed — call it OFF the gateway queue.
    ///
    /// This is what lets an RTSP feed stay in the playlist: the
    /// extension's own attempt to play it is the retry. A camera that is
    /// still down fails fast, and the failure backoff keeps a player that
    /// retries every 2 s from respawning ffmpeg each time.
    func startOnDemand(feedID: UUID) -> Bool {
        guard let feed = LiveFeedManager.shared.feed(id: feedID), feed.kind == .rtsp else { return false }
        do {
            let url = try ensureRunning(for: feed, automatic: true)
            debugLog("🎥 RTSP feed \(feed.displayName) started on demand")
            DispatchQueue.main.async {
                LiveFeedManager.shared.updateResolution(id: feedID, resolvedURL: url.absoluteString, resolvedAt: Date())
            }
            return true
        } catch {
            // Inside the backoff nothing was started — not a new failure.
            if Self.isBackoff(error) { return false }
            let message = error.localizedDescription
            errorLog("🎥 RTSP on-demand start for \(feed.displayName) failed: \(message)")
            stop(feedID: feedID)
            let summary = message.split(separator: "\n").first.map(String.init) ?? message
            DispatchQueue.main.async {
                LiveFeedManager.shared.recordResolveFailure(id: feedID, error: summary)
            }
            return false
        }
    }

    private init() {}

    /// Ensure a transmuxer is running for the given RTSP feed. Returns
    /// the loopback playback URL the extension / preview should use.
    /// Throws if ffmpeg is missing, the gateway can't bind, or ffmpeg
    /// fails to launch.
    ///
    /// `automatic`: the caller is not a user action (gateway on-demand
    /// start, on-screen refresh, playlist pre-warm). Such a call does not
    /// respawn ffmpeg within the failure backoff — it throws the backoff
    /// error instead. The Restart button, the preview and add/edit always
    /// start.
    @discardableResult
    func ensureRunning(for feed: LiveFeed, automatic: Bool = false) throws -> URL {
        guard feed.kind == .rtsp else {
            throw NSError(domain: "com.glouel.aerial.transmuxer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "feed is not RTSP"])
        }
        guard let ffmpeg = LiveFeedsTooling.shared.ffmpegPath else {
            throw NSError(domain: "com.glouel.aerial.transmuxer", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "ffmpeg not found — install via `\(LiveFeedsTooling.installCommand("ffmpeg"))`"])
        }

        try LiveFeedsGateway.shared.ensureRunning()
        let outputDir = LiveFeedsGateway.shared.outputDirectory(for: feed.id)

        // Single-flight: a second caller waits here and then finds the
        // transmuxer running (or gets its own attempt if the first failed).
        let starting = startLock(for: feed.id)
        starting.lock()
        defer { starting.unlock() }

        lock.lock()
        var transmuxer = transmuxers[feed.id]
        let wasAlreadyRunning = transmuxer?.isRunning == true
        if transmuxer == nil || !wasAlreadyRunning {
            let t = LiveFeedTransmuxer(
                feedID: feed.id,
                sourceURL: feed.sourceURL,
                ffmpegPath: ffmpeg,
                outputDir: outputDir
            )
            transmuxers[feed.id] = t
            transmuxer = t
        }
        lock.unlock()

        if !wasAlreadyRunning {
            // Checked here, under the start lock: a caller that queued
            // behind a start that just failed must not launch its own.
            if automatic, !LiveFeedResolvePolicy.shouldStartTransmuxer(lastFailedAt: startFailure(for: feed.id), now: Date()) {
                throw NSError(domain: "com.glouel.aerial.transmuxer", code: Self.backoffErrorCode,
                              userInfo: [NSLocalizedDescriptionKey: "not restarting ffmpeg yet — the last start just failed"])
            }
            do {
                try transmuxer?.start()
                // ffmpeg needs a few seconds to connect to the RTSP source
                // and emit the first HLS segment. Block here so the caller
                // never hands AVPlayer a URL that 404s — if the playlist
                // doesn't appear (bad URL, unreachable source, codec issue…)
                // the thrown error carries ffmpeg's stderr tail.
                try transmuxer?.waitForReady()
            } catch {
                setStartFailure(Date(), for: feed.id)
                throw error
            }
            setStartFailure(nil, for: feed.id)
            // Seed the idle reaper so a pre-warmed feed gets a full
            // timeout window to attract a consumer before being reaped.
            LiveFeedsGateway.shared.recordAccess(for: feed.id)
            startReaperIfNeeded()
        }

        guard let playbackURL = LiveFeedsGateway.shared.playbackURL(for: feed.id) else {
            throw NSError(domain: "com.glouel.aerial.transmuxer", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "gateway has no base URL"])
        }
        return playbackURL
    }

    func stop(feedID: UUID) {
        lock.lock()
        let t = transmuxers.removeValue(forKey: feedID)
        lock.unlock()
        t?.stop()
        LiveFeedsGateway.shared.removeOutputDirectory(for: feedID)
    }

    /// Called from `AppDelegate` on quit so we don't leave orphan ffmpeg
    /// processes behind.
    func stopAll() {
        lock.lock()
        let all = transmuxers
        transmuxers.removeAll()
        reaperTimer?.cancel()
        reaperTimer = nil
        lock.unlock()
        for (_, t) in all { t.stop() }
        LiveFeedsGateway.shared.stop()
    }

    // MARK: - Idle reaper

    /// Install a once-per-minute timer that stops transmuxers the
    /// gateway hasn't seen HTTP traffic for in at least `idleTimeout`
    /// seconds. Callers shouldn't invoke this directly — `ensureRunning`
    /// kicks it off the first time a transmuxer spins up.
    private func startReaperIfNeeded() {
        lock.lock()
        if reaperTimer != nil {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.reapIdle()
        }
        reaperTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func reapIdle() {
        let now = Date()
        var toStop: [(UUID, LiveFeedTransmuxer)] = []
        lock.lock()
        for (id, t) in transmuxers {
            guard t.isRunning else { continue }
            // The gateway gets a start-time entry right after we spawn
            // ffmpeg, so `last` is always non-nil for a healthy feed.
            // If somehow we never recorded one, err on the side of
            // keeping the process alive rather than reaping prematurely.
            guard let last = LiveFeedsGateway.shared.lastAccess(for: id) else { continue }
            if now.timeIntervalSince(last) >= Self.idleTimeout {
                toStop.append((id, t))
            }
        }
        for (id, _) in toStop {
            transmuxers.removeValue(forKey: id)
        }
        if transmuxers.isEmpty {
            reaperTimer?.cancel()
            reaperTimer = nil
        }
        lock.unlock()

        for (id, t) in toStop {
            debugLog("🎥 reaping idle transmuxer for \(id.uuidString.prefix(8))")
            t.stop()
            LiveFeedsGateway.shared.removeOutputDirectory(for: id)
        }
    }
}

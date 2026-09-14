//
//  LivePlaybackDiagnostics.swift
//  AerialScreenSaverExtension
//
//  Attaches KVO + NotificationCenter observers to an AVPlayer / AVPlayerItem
//  pair and routes human-readable state transitions and errors to a sink
//  closure. Used by PlayerCoordinator for screensaver live playback and by
//  the Companion's Live Feed preview window. Shared across both targets.
//

import Foundation
import AVFoundation

/// Events emitted by `LivePlaybackDiagnostics`. All strings are already
/// human-readable with a short prefix — callers typically just print or
/// append to a log view.
final class LivePlaybackDiagnostics: NSObject {

    // MARK: - Sink

    /// Human-readable log line. Call on the queue the observers fire from
    /// (main for KVO on AVPlayerItem, main for NotificationCenter with
    /// `.main` queue). Caller is responsible for hopping to its own queue
    /// if needed.
    typealias Sink = (_ line: String) -> Void

    /// Structured events — a subset of what gets logged, in a form
    /// callers can act on (e.g. advance the playlist on unrecoverable
    /// failure, arm a stall watchdog on waiting/stalled). Additive to
    /// the string sink; set only when a caller actually needs to react.
    enum Event {
        case statusReady
        case statusFailed(Error?)
        case timeControlPlaying
        case timeControlWaiting(reason: String?)
        case playbackStalled
        case failedToPlayToEnd(Error?)
    }

    var onEvent: ((Event) -> Void)?

    private var sink: Sink?
    private var label: String = ""

    // MARK: - Observed objects

    private weak var player: AVPlayer?
    private weak var playerItem: AVPlayerItem?

    private var itemStatusToken: NSKeyValueObservation?
    private var itemBufferEmptyToken: NSKeyValueObservation?
    private var itemBufferFullToken: NSKeyValueObservation?
    private var itemLikelyKeepUpToken: NSKeyValueObservation?
    private var playerTimeControlToken: NSKeyValueObservation?
    private var playerRateToken: NSKeyValueObservation?

    private var failedObserver: NSObjectProtocol?
    private var errorLogObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?

    // MARK: - Start / Stop

    /// Start observing. Safe to call again on the same instance — previous
    /// observers are torn down first.
    func start(player: AVPlayer, item: AVPlayerItem, label: String, sink: @escaping Sink) {
        stop()
        self.player = player
        self.playerItem = item
        self.label = label
        self.sink = sink

        emit("start — url=\(item.asset.debugURL) format=\(item.asset.debugContainerHint)")

        itemStatusToken = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            self?.reportItemStatus(item)
        }
        itemBufferEmptyToken = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            if item.isPlaybackBufferEmpty {
                self?.emit("buffer empty")
            }
        }
        itemBufferFullToken = item.observe(\.isPlaybackBufferFull, options: [.new]) { [weak self] item, _ in
            if item.isPlaybackBufferFull {
                self?.emit("buffer full")
            }
        }
        itemLikelyKeepUpToken = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            self?.emit("likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp)")
        }

        playerTimeControlToken = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] p, _ in
            self?.reportTimeControl(p)
        }
        playerRateToken = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
            self?.emit("rate=\(p.rate)")
        }

        let nc = NotificationCenter.default
        failedObserver = nc.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self?.emit("failedToPlayToEndTime: \(err.map(Self.describe) ?? "(no error attached)")")
            self?.onEvent?(.failedToPlayToEnd(err))
        }
        stalledObserver = nc.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item, queue: .main
        ) { [weak self] _ in
            self?.emit("playback stalled")
            self?.onEvent?(.playbackStalled)
        }
        errorLogObserver = nc.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: item, queue: .main
        ) { [weak self] _ in
            guard let event = item.errorLog()?.events.last else { return }
            self?.emit("errorLog: " + Self.describe(event))
        }
    }

    func stop() {
        itemStatusToken?.invalidate(); itemStatusToken = nil
        itemBufferEmptyToken?.invalidate(); itemBufferEmptyToken = nil
        itemBufferFullToken?.invalidate(); itemBufferFullToken = nil
        itemLikelyKeepUpToken?.invalidate(); itemLikelyKeepUpToken = nil
        playerTimeControlToken?.invalidate(); playerTimeControlToken = nil
        playerRateToken?.invalidate(); playerRateToken = nil
        if let o = failedObserver { NotificationCenter.default.removeObserver(o) }
        if let o = errorLogObserver { NotificationCenter.default.removeObserver(o) }
        if let o = stalledObserver { NotificationCenter.default.removeObserver(o) }
        failedObserver = nil
        errorLogObserver = nil
        stalledObserver = nil
        player = nil
        playerItem = nil
        sink = nil
        onEvent = nil
    }

    deinit { stop() }

    // MARK: - Reporting helpers

    private func reportItemStatus(_ item: AVPlayerItem) {
        switch item.status {
        case .unknown:
            emit("status=unknown")
        case .readyToPlay:
            emit("status=readyToPlay")
            onEvent?(.statusReady)
        case .failed:
            let err = item.error.map(Self.describe) ?? "(no error)"
            emit("status=failed err=\(err)")
            onEvent?(.statusFailed(item.error))
        @unknown default:
            emit("status=?(\(item.status.rawValue))")
        }
    }

    private func reportTimeControl(_ p: AVPlayer) {
        switch p.timeControlStatus {
        case .paused:
            emit("timeControl=paused")
        case .waitingToPlayAtSpecifiedRate:
            let reason = p.reasonForWaitingToPlay?.rawValue ?? "?"
            emit("timeControl=waiting reason=\(reason)")
            onEvent?(.timeControlWaiting(reason: p.reasonForWaitingToPlay?.rawValue))
        case .playing:
            emit("timeControl=playing")
            onEvent?(.timeControlPlaying)
        @unknown default:
            emit("timeControl=?(\(p.timeControlStatus.rawValue))")
        }
    }

    private func emit(_ line: String) {
        sink?("[\(label)] \(line)")
    }

    // MARK: - Description helpers

    fileprivate static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var out = "\(ns.domain)#\(ns.code): \(ns.localizedDescription)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            out += " | underlying=\(underlying.domain)#\(underlying.code): \(underlying.localizedDescription)"
        }
        return out
    }

    fileprivate static func describe(_ event: AVPlayerItemErrorLogEvent) -> String {
        var parts: [String] = []
        parts.append("status=\(event.errorStatusCode)")
        if !event.errorDomain.isEmpty { parts.append("domain=\(event.errorDomain)") }
        if let comment = event.errorComment, !comment.isEmpty { parts.append("msg=\(comment)") }
        if let uri = event.uri, !uri.isEmpty { parts.append("uri=\(uri)") }
        if let server = event.serverAddress, !server.isEmpty { parts.append("server=\(server)") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Asset convenience

private extension AVAsset {
    /// Best-effort URL for logging (AVURLAsset returns its URL, anything
    /// else returns a generic marker).
    var debugURL: String {
        (self as? AVURLAsset)?.url.absoluteString ?? "(non-URL asset)"
    }

    /// Best-effort container hint from the URL extension — we can't
    /// synchronously inspect tracks without blocking, so this is enough
    /// for logging.
    var debugContainerHint: String {
        guard let url = (self as? AVURLAsset)?.url else { return "?" }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "?" : ext
    }
}

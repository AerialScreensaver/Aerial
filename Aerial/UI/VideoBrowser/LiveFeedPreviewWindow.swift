//
//  LiveFeedPreviewWindow.swift
//  Aerial Companion
//
//  Standalone preview window for a single live feed — lets the user
//  verify a URL plays (or see exactly why it doesn't) without having
//  to trigger the screensaver. Uses the shared LivePlaybackDiagnostics
//  to surface AVPlayer events into an on-screen log console.
//

import AppKit
import AVFoundation
import AVKit
import SwiftUI

// MARK: - Window Controller

final class LiveFeedPreviewWindowController: NSWindowController {

    /// Retained controllers keyed by feed id, so hitting Preview twice on
    /// the same feed refocuses the existing window instead of spawning a
    /// second one.
    private static var open: [UUID: LiveFeedPreviewWindowController] = [:]

    private let feedID: UUID

    static func show(for feed: LiveFeed) {
        if let existing = open[feed.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = LiveFeedPreviewWindowController(feed: feed)
        open[feed.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(feed: LiveFeed) {
        self.feedID = feed.id
        let view = LiveFeedPreviewView(initialFeed: feed)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: Self.defaultWindowWidth,
                                height: Self.defaultWindowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preview — \(feed.displayName)"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: Self.minWindowWidth, height: Self.minWindowHeight)
        window.titlebarAppearsTransparent = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    /// Default content size tuned for a 16:9 video area (960×540) plus the
    /// metadata + event log sections below it.
    fileprivate static let defaultWindowWidth: CGFloat = 960
    fileprivate static let defaultWindowHeight: CGFloat = 840
    fileprivate static let minWindowWidth: CGFloat = 640
    fileprivate static let minWindowHeight: CGFloat = 540

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
}

extension LiveFeedPreviewWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        Self.open[feedID] = nil
    }
}

// MARK: - SwiftUI View

private struct LiveFeedPreviewView: View {
    let initialFeed: LiveFeed

    @State private var feed: LiveFeed
    @State private var log: [String] = []
    @State private var status: PreviewStatus = .idle
    @StateObject private var playback = PreviewPlayback()

    init(initialFeed: LiveFeed) {
        self.initialFeed = initialFeed
        _feed = State(initialValue: initialFeed)
    }

    var body: some View {
        VStack(spacing: 0) {
            videoArea
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)

            Divider()
            metadataSection
            Divider()
            logSection
        }
        .frame(minWidth: LiveFeedPreviewWindowController.minWindowWidth,
               minHeight: LiveFeedPreviewWindowController.minWindowHeight)
        .onAppear(perform: startPreview)
        .onDisappear(perform: playback.teardown)
        .onReceive(NotificationCenter.default.publisher(for: LiveFeedManager.didChangeNotification)) { _ in
            if let updated = LiveFeedManager.shared.feed(id: feed.id) {
                feed = updated
                if status == .resolving, let url = updated.playbackURL, !url.isEmpty {
                    attach(url: url)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: LiveFeedManager.resolutionFailedNotification)) { note in
            guard let userInfo = note.userInfo,
                  let idString = userInfo["feedID"] as? String,
                  idString == feed.id.uuidString else { return }
            let message = (userInfo["error"] as? String) ?? "(no error message)"
            status = .failed
            // Split multi-line error strings (ffmpeg stderr tails) onto
            // separate log entries so the monospaced log view stays
            // readable.
            for line in message.split(whereSeparator: \.isNewline) where !line.isEmpty {
                append("! " + String(line))
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var videoArea: some View {
        ZStack {
            if status == .missingYtDlp {
                missingToolCard(
                    icon: "terminal",
                    title: "yt-dlp is required to preview YouTube feeds",
                    install: "brew install yt-dlp"
                )
            } else if status == .missingFfmpeg {
                missingToolCard(
                    icon: "terminal",
                    title: "ffmpeg is required to preview RTSP feeds",
                    install: "brew install ffmpeg"
                )
            } else {
                PreviewPlayerView(player: playback.player)
            }

            if status == .resolving {
                ProgressView(resolvingMessage)
                    .progressViewStyle(.circular)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func missingToolCard(icon: String, title: String, install: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.white)
            Text(title)
                .font(.title3)
                .foregroundStyle(.white)
            Text("Install via: \(install)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .textSelection(.enabled)
        }
        .padding()
    }

    private var resolvingMessage: String {
        switch feed.kind {
        case .youtube: return "Resolving via yt-dlp…"
        case .rtsp:    return "Starting ffmpeg transmuxer…"
        case .hls:     return "Loading…"
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(feed.displayName).font(.headline)
                Spacer()
                statusPill
            }
            HStack(spacing: 16) {
                Label(feed.kind.displayName, systemImage: kindIcon)
                Text(maskedSourceURL)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if feed.kind != .hls, let resolved = feed.resolvedURL, !resolved.isEmpty {
                Text("Resolved: \(resolved)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Event log").font(.caption.bold())
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.joined(separator: "\n"), forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(log.isEmpty)

                Button {
                    log.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(log.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .onChange(of: log.count) { _ in
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .frame(height: 180)
        }
        .padding(12)
    }

    private var statusPill: some View {
        Text(status.label)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(status.color.opacity(0.2))
            .foregroundStyle(status.color)
            .clipShape(Capsule())
    }

    private var kindIcon: String {
        switch feed.kind {
        case .hls: return "dot.radiowaves.left.and.right"
        case .youtube: return "play.rectangle"
        case .rtsp: return "video"
        }
    }

    private var maskedSourceURL: String {
        if let range = feed.sourceURL.range(of: "://") {
            let after = feed.sourceURL[range.upperBound...]
            if let atIndex = after.firstIndex(of: "@") {
                let scheme = feed.sourceURL[..<range.upperBound]
                let host = after[after.index(after: atIndex)...]
                return "\(scheme)••••@\(host)"
            }
        }
        return feed.sourceURL
    }

    // MARK: - Lifecycle

    private func startPreview() {
        append("▶ preview opened (kind=\(feed.kind.rawValue))")
        switch feed.kind {
        case .rtsp:
            guard LiveFeedsTooling.shared.ffmpegPath != nil else {
                status = .missingFfmpeg
                append("! ffmpeg not found — install via `brew install ffmpeg`")
                return
            }
            // Transmuxing is async — kick off the ffmpeg + gateway path
            // and let the LiveFeedManager notification deliver the
            // resolved 127.0.0.1 URL when it's ready.
            status = .resolving
            append("… starting ffmpeg transmuxer for \(maskedSourceURL)")
            LiveFeedResolver.shared.resolveIfNeeded(feed, force: true)

        case .youtube:
            guard LiveFeedsTooling.shared.ytDlpPath != nil else {
                status = .missingYtDlp
                append("! yt-dlp not found — install via `brew install yt-dlp`")
                return
            }
            if let url = feed.playbackURL, !url.isEmpty {
                attach(url: url)
            } else {
                status = .resolving
                append("… resolving via yt-dlp")
                LiveFeedResolver.shared.resolveIfNeeded(feed, force: true)
            }

        case .hls:
            attach(url: feed.sourceURL)
        }
    }

    private func attach(url: String) {
        guard let parsed = URL(string: url) else {
            status = .failed
            append("! invalid URL: \(url)")
            return
        }
        status = .loading
        append("→ attaching AVPlayer to \(parsed.absoluteString)")
        playback.attach(url: parsed, label: feed.displayName) { line, inferred in
            Task { @MainActor in
                self.append(line)
                if let inferred = inferred {
                    self.status = inferred
                }
            }
        }
    }

    private func append(_ line: String) {
        let ts = Self.tsFormatter.string(from: Date())
        log.append("[\(ts)] \(line)")
    }

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// MARK: - AVPlayerView wrapper

private struct PreviewPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

// MARK: - Playback state

@MainActor
private final class PreviewPlayback: ObservableObject {
    let player = AVPlayer()
    private var diagnostics: LivePlaybackDiagnostics?

    func attach(url: URL, label: String, sink: @escaping (String, PreviewStatus?) -> Void) {
        teardown()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        let diag = LivePlaybackDiagnostics()
        diag.start(player: player, item: item, label: label) { line in
            let inferred = PreviewStatus.infer(from: line)
            sink(line, inferred)
        }
        diagnostics = diag
        player.play()
    }

    func teardown() {
        diagnostics?.stop()
        diagnostics = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

// MARK: - Status

private enum PreviewStatus: Equatable {
    case idle
    case resolving
    case loading
    case playing
    case stalled
    case failed
    case missingYtDlp
    case missingFfmpeg

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .resolving: return "Resolving…"
        case .loading: return "Loading…"
        case .playing: return "Playing"
        case .stalled: return "Stalled"
        case .failed: return "Failed"
        case .missingYtDlp: return "yt-dlp missing"
        case .missingFfmpeg: return "ffmpeg missing"
        }
    }

    var color: Color {
        switch self {
        case .idle, .resolving, .loading: return .secondary
        case .playing: return .green
        case .stalled: return .orange
        case .failed, .missingYtDlp, .missingFfmpeg: return .red
        }
    }

    /// Guess a status from a diagnostics log line.
    static func infer(from line: String) -> PreviewStatus? {
        if line.contains("status=readyToPlay") || line.contains("timeControl=playing") {
            return .playing
        }
        if line.contains("status=failed") || line.contains("failedToPlayToEndTime") {
            return .failed
        }
        if line.contains("stalled") || line.contains("buffer empty") {
            return .stalled
        }
        return nil
    }
}

//
//  LiveFeedsContentView.swift
//  Aerial Companion
//
//  Shown when the "Live Feeds" sidebar row is selected. Lets the user
//  add, edit, and remove live streams (HLS, YouTube, RTSP). Writes
//  through LiveFeedManager, which regenerates the shared source folder.
//

import SwiftUI
import AppKit

struct LiveFeedsContentView: View {
    @State private var feeds: [LiveFeed] = []
    @State private var showingAdd = false
    @State private var editing: LiveFeed?
    @State private var showingToolingGuidance: LiveFeedKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if feeds.isEmpty {
                    emptyState
                } else {
                    feedsList
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: LiveFeedManager.didChangeNotification)) { _ in
            reload()
        }
        .sheet(isPresented: $showingAdd) {
            LiveFeedEditor(feed: nil, onSave: { feed in
                LiveFeedManager.shared.add(
                    displayName: feed.displayName,
                    sourceURL: feed.sourceURL,
                    kind: feed.kind,
                    playbackSeconds: feed.playbackSeconds
                )
                maybePromptForTooling(kind: feed.kind)
                showingAdd = false
            }, onCancel: { showingAdd = false })
        }
        .sheet(item: $editing) { feed in
            LiveFeedEditor(feed: feed, onSave: { updated in
                LiveFeedManager.shared.update(updated)
                editing = nil
            }, onCancel: { editing = nil })
        }
        .sheet(item: $showingToolingGuidance) { kind in
            LiveFeedToolingSheet(kind: kind) { showingToolingGuidance = nil }
        }
    }

    private var header: some View {
        ContentHeader(
            icon: "dot.radiowaves.left.and.right",
            title: "Live Feeds",
            description: "Add live streams from local cameras, YouTube, or any HLS URL."
        ) {
            Button {
                showingAdd = true
            } label: {
                Label("Add Live Feed", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No live feeds yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Click \"Add Live Feed\" to paste a YouTube live URL, an HLS stream, or an RTSP camera.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var feedsList: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(feeds) { feed in
                LiveFeedRow(feed: feed,
                            onEdit: { editing = feed },
                            onDelete: { LiveFeedManager.shared.remove(id: feed.id) },
                            onPreview: { LiveFeedPreviewWindowController.show(for: feed) },
                            onReload: { reloadFeed(feed) })
            }
        }
    }

    private func reload() {
        feeds = LiveFeedManager.shared.allFeeds().sorted { $0.addedAt < $1.addedAt }
    }

    /// Force-rerun the async resolution for a feed — yt-dlp for YouTube
    /// feeds whose cached HLS URL has expired, a fresh ffmpeg transmuxer
    /// for an RTSP feed that has stalled on a flaky camera. Also
    /// regenerates the thumbnail.
    private func reloadFeed(_ feed: LiveFeed) {
        if feed.kind == .rtsp {
            // Kill the existing ffmpeg + clear the segment dir so the
            // resolver's ensureRunning spawns a fresh process.
            LiveFeedTransmuxerManager.shared.stop(feedID: feed.id)
        }
        LiveFeedResolver.shared.resolveIfNeeded(feed, force: true)
        LiveFeedThumbnailer.shared.ensureThumbnail(for: feed, force: true)
    }

    private func maybePromptForTooling(kind: LiveFeedKind) {
        switch kind {
        case .youtube:
            if LiveFeedsTooling.shared.ytDlpPath == nil {
                showingToolingGuidance = .youtube
            }
        case .rtsp:
            if LiveFeedsTooling.shared.ffmpegPath == nil {
                showingToolingGuidance = .rtsp
            }
        case .hls:
            break
        }
    }
}

// MARK: - Row

private struct LiveFeedRow: View {
    let feed: LiveFeed
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onPreview: () -> Void
    let onReload: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnailView
                .frame(width: 96, height: 54)  // 16:9 at list-card scale
                .background(Color.black.opacity(0.3))
                .cornerRadius(4)
                .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(feed.displayName)
                    .font(.system(size: 14, weight: .medium))
                Text(kindLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(maskedURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if feed.kind == .youtube {
                    Text(resolutionStatus)
                        .font(.caption2)
                        .foregroundStyle(feed.resolvedURL == nil ? .orange : .secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(Int(feed.playbackSeconds))s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button(action: onPreview) {
                        Image(systemName: "play.rectangle")
                    }
                    .help("Preview stream")
                    if feed.kind != .hls {
                        Button(action: onReload) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help(feed.kind == .youtube
                              ? "Re-resolve via yt-dlp"
                              : "Restart ffmpeg transmuxer")
                    }
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var iconName: String {
        switch feed.kind {
        case .hls: return "dot.radiowaves.left.and.right"
        case .youtube: return "play.rectangle"
        case .rtsp: return "video"
        }
    }

    /// Thumbnail image if one has been generated; placeholder icon
    /// otherwise. Thumbnails are byte-loaded off disk — the parent
    /// `LiveFeedsContentView` re-renders on
    /// `LiveFeedManager.didChangeNotification`, which the thumbnailer
    /// posts when a new image is saved.
    @ViewBuilder
    private var thumbnailView: some View {
        if let path = LiveFeedThumbnailer.thumbnailPath(for: feed),
           let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: iconName)
                .font(.system(size: 24))
                .foregroundStyle(Color.aerial)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var kindLabel: String { feed.kind.displayName }

    /// Hide any `user:pass@` fragment when showing the URL.
    private var maskedURL: String {
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

    private var resolutionStatus: String {
        if let at = feed.resolvedAt {
            let formatter = RelativeDateTimeFormatter()
            return "Resolved \(formatter.localizedString(for: at, relativeTo: Date()))"
        }
        return "Not yet resolved"
    }
}

// MARK: - Editor Sheet

private struct LiveFeedEditor: View {
    let feed: LiveFeed?
    let onSave: (LiveFeed) -> Void
    let onCancel: () -> Void

    @State private var displayName: String
    @State private var sourceURL: String
    @State private var playbackSeconds: Double

    init(feed: LiveFeed?, onSave: @escaping (LiveFeed) -> Void, onCancel: @escaping () -> Void) {
        self.feed = feed
        self.onSave = onSave
        self.onCancel = onCancel
        _displayName = State(initialValue: feed?.displayName ?? "")
        _sourceURL = State(initialValue: feed?.sourceURL ?? "")
        _playbackSeconds = State(initialValue: feed?.playbackSeconds ?? 300)
    }

    private var detectedKind: LiveFeedKind {
        LiveFeedKind.detect(from: sourceURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(feed == nil ? "Add Live Feed" : "Edit Live Feed")
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("ISS Live Cam, Garage Camera, …", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Stream URL").font(.caption).foregroundStyle(.secondary)
                TextField("https://… or rtsp://… or a YouTube link", text: $sourceURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if !sourceURL.isEmpty {
                    Text("Detected type: \(detectedKind.displayName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Play for").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Slider(value: $playbackSeconds, in: 10...1800, step: 10)
                    Text("\(Int(playbackSeconds))s")
                        .font(.callout.monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(feed == nil ? "Add" : "Save") {
                    let id = feed?.id ?? UUID()
                    let addedAt = feed?.addedAt ?? Date()
                    let updated = LiveFeed(
                        id: id,
                        displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                        sourceURL: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines),
                        kind: detectedKind,
                        playbackSeconds: playbackSeconds,
                        addedAt: addedAt,
                        resolvedURL: nil,
                        resolvedAt: nil,
                        thumbnailPath: feed?.thumbnailPath
                    )
                    onSave(updated)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty
                          || sourceURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

// MARK: - Tooling Guidance Sheet

private struct LiveFeedToolingSheet: View {
    let kind: LiveFeedKind
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind == .youtube ? "yt-dlp is required" : "ffmpeg is required")
                        .font(.title3.bold())
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                HStack {
                    Text(installCommand)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(installCommand, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(8)
            }

            HStack {
                Button("Open Terminal") {
                    if let url = URL(string: "file:///System/Applications/Utilities/Terminal.app") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button("I've installed it") {
                    LiveFeedsTooling.shared.refreshPaths()
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                Button("Close", action: onDismiss)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var description: String {
        switch kind {
        case .youtube:
            return "YouTube live streams are resolved via the yt-dlp command-line tool. Install it via Homebrew, then try again."
        case .rtsp:
            return "RTSP streams are transmuxed via ffmpeg. Install it via Homebrew. (Full RTSP playback support is coming in a later update.)"
        case .hls:
            return ""
        }
    }

    private var installCommand: String {
        switch kind {
        case .youtube: return "brew install yt-dlp"
        case .rtsp:    return "brew install ffmpeg"
        case .hls:     return ""
        }
    }
}

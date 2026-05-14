//
//  VideoInspectorView.swift
//  Aerial Companion
//
//  Right panel showing detailed metadata and per-video settings.
//

import SwiftUI

struct VideoInspectorView: View {
    let video: AerialVideo
    @ObservedObject var state: VideoBrowserState

    @StateObject private var downloadTracker = DownloadTracker.shared
    @State private var editingTitle: String = ""
    @State private var pendingAction: PendingFormatAction?

    /// Consolidated pending-confirmation state. A single `.alert(item:)`
    /// drives both "switch to format X" and "reset to global"; chaining
    /// two separate `.alert` modifiers on the same view silently
    /// shadows one of them in SwiftUI.
    private enum PendingFormatAction: Identifiable {
        case switchTo(VideoFormat)
        case reset

        var id: String {
            switch self {
            case .switchTo(let fmt): return "switch-\(fmt.rawValue)"
            case .reset: return "reset"
            }
        }
    }

    /// Display order for "Other formats" badges. Rough
    /// best-to-worst-quality ranking so the row reads top-down.
    private let formatDisplayOrder: [VideoFormat] = [
        .v4KHDR, .v4KSDR240, .v4KHEVC, .v1080pHDR, .v1080pHEVC, .v1080pH264,
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Large thumbnail
                largeThumbnailView
                    .frame(height: 158)
                    .clipped()
                    .cornerRadius(8)

                // Download button (when not cached)
                if !video.isAvailableOffline {
                    downloadButton
                }

                // Name
                VStack(alignment: .leading, spacing: 2) {
                    if !video.secondaryName.isEmpty {
                        if state.isMyVideos {
                            HStack(spacing: 4) {
                                TextField("Title", text: $editingTitle, onCommit: {
                                    updateMyVideoTitle(newTitle: editingTitle)
                                })
                                .font(.system(size: 16, weight: .bold))
                                .textFieldStyle(.plain)
                                .fixedSize()
                                Image(systemName: "pencil.line")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text(video.secondaryName)
                                .font(.system(size: 16, weight: .bold))
                        }
                    }
                    Text(video.name)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }

                Divider()

                // Time of Day
                TimeOfDayOverrideView(video: video, state: state)

                Divider()

                // Toggles
                togglesSection

                Divider()

                // Info
                infoSection

                if shouldShowFormatPicker {
                    Divider()
                    otherFormatsSection
                }
            }
            .padding(16)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .alert(item: $pendingAction) { action in
            let currentLabel = AerialVideo.label(for: video.effectiveFormat())
            switch action {
            case .switchTo(let target):
                let targetLabel = AerialVideo.label(for: target)
                return Alert(
                    title: Text("Switch to \(targetLabel)?"),
                    message: Text("The \(currentLabel) copy will be removed from your cache and \(targetLabel) will be downloaded in its place."),
                    primaryButton: .default(Text("Switch")) { switchFormat(to: target) },
                    secondaryButton: .cancel()
                )
            case .reset:
                let globalLabel = AerialVideo.label(for: PrefsVideos.videoFormat)
                return Alert(
                    title: Text("Reset to global format?"),
                    message: Text("The \(currentLabel) copy will be removed and \(globalLabel) will be downloaded instead."),
                    primaryButton: .default(Text("Reset")) { resetFormatOverride() },
                    secondaryButton: .cancel()
                )
            }
        }
        .onAppear {
            loadData()
            editingTitle = video.secondaryName
        }
        .onChange(of: video.id) { _ in
            loadData()
            editingTitle = video.secondaryName
        }
    }

    // MARK: - Large Thumbnail

    @ViewBuilder
    private var largeThumbnailView: some View {
        if let thumb = state.thumbnails[video.id] {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    Image(systemName: "film")
                        .foregroundColor(.secondary.opacity(0.4))
                        .font(.system(size: 24))
                )
        }
    }

    // MARK: - Download Button

    @ViewBuilder
    private var downloadButton: some View {
        let dlState = downloadTracker.state(for: video.id)
        switch dlState {
        case .downloading(let progress):
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 2)
                        .frame(width: 20, height: 20)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.aerial, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 20, height: 20)
                        .rotationEffect(.degrees(-90))
                }
                Text("Downloading \(Int(progress * 100))%...")
                    .font(.system(size: 13))
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .padding(.horizontal, 8)
        case .queued:
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.aerial)
                Text("Queued for Download")
                    .font(.system(size: 13))
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .padding(.horizontal, 8)
        case .none:
            Button(action: { downloadTracker.queueDownload(videoId: video.id) }) {
                Label("Download Video", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.aerial)
            .frame(maxWidth: .infinity, minHeight: 32)
        }
    }

    // MARK: - Toggles

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { PrefsVideos.favorites.contains(video.id) },
                set: { newVal in
                    var favs = PrefsVideos.favorites
                    if newVal { favs.append(video.id) }
                    else { favs.removeAll { $0 == video.id } }
                    PrefsVideos.favorites = favs
                    state.refreshTrigger += 1
                }
            )) {
                Label("Favorite", systemImage: "star")
            }

            Toggle(isOn: Binding(
                get: { PrefsVideos.hidden.contains(video.id) },
                set: { newVal in
                    var hidden = PrefsVideos.hidden
                    if newVal { hidden.append(video.id) }
                    else { hidden.removeAll { $0 == video.id } }
                    PrefsVideos.hidden = hidden
                    state.refreshTrigger += 1
                }
            )) {
                Label("Hidden", systemImage: "eye.slash")
            }
        }
    }

    // MARK: - Info

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Information")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            let effectiveFormat = video.effectiveFormat()
            HStack {
                Text("Format")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .leading)
                FormatBadge(format: effectiveFormat, variant: .current)
            }
            infoRow("Duration", video.duration > 0 ? formatDuration(video.duration) : "Unknown")
            infoRow("Source", video.sourceFor(format: effectiveFormat).name)
            infoRow("Scene", video.scene.rawValue.capitalized)
            infoRow("Orientation", video.isVertical ? "Vertical" : "Horizontal")

            if video.contentLength > 0 {
                let mb = Double(video.contentLength) / 1_048_576
                infoRow("Size", String(format: "%.1f MB", mb))
            }

            if video.isAvailableOffline {
                let path = VideoList.instance.localPathFor(video: video)
                HStack(alignment: .top) {
                    Text("Path")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 70, alignment: .leading)
                    Text(path)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            } else {
                HStack {
                    switch downloadTracker.state(for: video.id) {
                    case .downloading(let progress):
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(.aerial)
                        Text("Downloading \(Int(progress * 100))%...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    case .queued:
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.aerial)
                        Text("Queued for download")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    case .none:
                        Image(systemName: "cloud")
                            .foregroundColor(.secondary)
                        Text("Not downloaded")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Other Formats

    private var shouldShowFormatPicker: Bool {
        guard !video.isLive else { return false }
        guard video.source.type != .local else { return false }
        return availableOtherFormats.count > 0 || hasFormatOverride
    }

    private var availableOtherFormats: [VideoFormat] {
        let current = video.effectiveFormat()
        return formatDisplayOrder.filter { fmt in
            fmt != current && (video.urls[fmt] ?? "") != ""
        }
    }

    private var hasFormatOverride: Bool {
        PrefsVideos.videoFormatOverride[video.id] != nil
    }

    @ViewBuilder
    private var otherFormatsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Other Formats")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            if availableOtherFormats.isEmpty {
                Text("No other formats available")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(availableOtherFormats, id: \.self) { fmt in
                        FormatBadge(format: fmt, variant: .available) {
                            pendingAction = .switchTo(fmt)
                        }
                    }
                }
            }

            if hasFormatOverride {
                Button(action: { pendingAction = .reset }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10))
                        Text("Reset to Global Format")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
                .foregroundColor(.aerial)
            }
        }
    }

    // MARK: - Format Switching

    private func switchFormat(to newFormat: VideoFormat) {
        // Capture the file the *current* effective format points at
        // BEFORE we flip the override — that's the file we're about to
        // orphan.
        let oldPath = VideoCache.cachePath(forVideo: video)

        var overrides = PrefsVideos.videoFormatOverride
        overrides[video.id] = newFormat.rawValue
        PrefsVideos.videoFormatOverride = overrides

        let newPath = VideoCache.cachePath(forVideo: video)

        if let oldPath = oldPath,
           oldPath != newPath,
           FileManager.default.fileExists(atPath: oldPath) {
            try? FileManager.default.removeItem(atPath: oldPath)
        }

        if !video.isAvailableOffline {
            DownloadTracker.shared.queueDownload(videoId: video.id)
        }

        state.refreshTrigger += 1
    }

    private func resetFormatOverride() {
        let oldPath = VideoCache.cachePath(forVideo: video)

        var overrides = PrefsVideos.videoFormatOverride
        overrides.removeValue(forKey: video.id)
        PrefsVideos.videoFormatOverride = overrides

        let newPath = VideoCache.cachePath(forVideo: video)

        if let oldPath = oldPath,
           oldPath != newPath,
           FileManager.default.fileExists(atPath: oldPath) {
            try? FileManager.default.removeItem(atPath: oldPath)
        }

        if !video.isAvailableOffline {
            DownloadTracker.shared.queueDownload(videoId: video.id)
        }

        state.refreshTrigger += 1
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
        }
    }

    // MARK: - Title Update

    private func updateMyVideoTitle(newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let filePath = video.urls[.v4KHEVC] ?? video.urls.values.first ?? ""
        guard !filePath.isEmpty else { return }

        let entriesPath = Cache.supportPath.appending("/Sources/My Videos/entries.json")
        guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: entriesPath)),
              let manifest = try? newJSONDecoder().decode(VideoManifest.self, from: jsonData) else {
            return
        }

        let updatedAssets = manifest.assets.map { asset -> VideoAsset in
            if asset.url4KSDR == filePath {
                return VideoAsset(
                    accessibilityLabel: asset.accessibilityLabel,
                    id: asset.id,
                    title: trimmed,
                    timeOfDay: asset.timeOfDay,
                    scene: asset.scene,
                    pointsOfInterest: asset.pointsOfInterest,
                    url4KHDR: asset.url4KHDR,
                    url4KSDR: asset.url4KSDR,
                    url1080H264: asset.url1080H264,
                    url1080HDR: asset.url1080HDR,
                    url4KSDR120FPS: asset.url4KSDR120FPS,
                    url4KSDR240FPS: asset.url4KSDR240FPS,
                    url1080SDR: asset.url1080SDR,
                    url: asset.url,
                    type: asset.type
                )
            }
            return asset
        }

        let updatedManifest = VideoManifest(
            assets: updatedAssets,
            initialAssetCount: manifest.initialAssetCount,
            version: manifest.version
        )

        if let source = SourceList.list.first(where: { $0.name == "My Videos" && $0.type == .local }) {
            SourceList.saveEntries(source: source, manifest: updatedManifest)
        }

        SourceList.ensureDefaultLocalSource()
        state.refreshTrigger += 1
    }

    // MARK: - Data Loading

    private func loadData() {
        state.loadThumbnail(for: video)
    }
}

struct VideoInspectorView_Previews: PreviewProvider {
    static var previews: some View {
        let video = PreviewData.makeVideo()
        let state = PreviewData.makeState(selectedVideo: video)
        VideoInspectorView(video: video, state: state)
            .frame(width: 280, height: 600)
    }
}

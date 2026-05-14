//
//  PlaylistListView.swift
//  Aerial Companion
//
//  Vertical list view for playlists — an alternative to the horizontal strip.
//  Purely presentational: receives all data and callbacks from parent.
//

import SwiftUI

struct PlaylistListView: View {
    let entries: [PlaylistEntry]
    let uncachedEntries: [PlaylistEntry]
    let currentIdx: Int
    let thumbnails: [String: NSImage]
    @ObservedObject var playbackManager: PlaybackManager
    @ObservedObject var downloadTracker: DownloadTracker
    var onTapEntry: (Int) -> Void
    var onDownload: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        cachedRow(entry: entry, index: index)
                            .id(index)
                    }
                    ForEach(Array(uncachedEntries.enumerated()), id: \.offset) { _, entry in
                        uncachedRow(entry: entry)
                            .id("dl-\(entry.videoId)")
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 220)
            .onChange(of: currentIdx) { newIndex in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    proxy.scrollTo(currentIdx, anchor: .center)
                }
            }
        }
    }

    // MARK: - Cached Row

    private func cachedRow(entry: PlaylistEntry, index: Int) -> some View {
        let isCurrent = index == currentIdx
        let video = VideoList.instance.videos.first(where: { $0.id == entry.videoId })

        return HStack(spacing: 8) {
            // Thumbnail
            ZStack(alignment: .leading) {
                thumbnailImage(for: entry)
                    .frame(width: 80, height: 45)
                    .clipped()
                    .cornerRadius(4)

                // Progress bar
                if isCurrent {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.aerial.opacity(0.8))
                            .frame(width: 3, height: geo.size.height * playbackManager.playbackProgress)
                    }
                    .frame(width: 80, height: 45)
                }

                // Play/pause overlay
                if isCurrent && playbackManager.playbackMode != .none {
                    Button(action: { playbackManager.togglePause() }) {
                        Image(systemName: playbackManager.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 80, height: 45)
                    .help(playbackManager.isPaused ? "Resume" : "Pause")
                    .accessibilityLabel(playbackManager.isPaused ? "Resume" : "Pause")
                    .keyboardShortcut(.space, modifiers: [])
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isCurrent ? Color.aerial : Color.clear, lineWidth: 2)
            )

            // Text + metadata
            VStack(alignment: .leading, spacing: 2) {
                if !entry.secondaryName.isEmpty {
                    Text(entry.secondaryName)
                        .font(.system(size: 12, weight: isCurrent ? .bold : .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }

                Text(entry.videoName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let video = video {
                    HStack(spacing: 6) {
                        Image(systemName: timeOfDayIcon(video.timeOfDay))
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                            .help(video.timeOfDay.capitalized)
                        Image(systemName: sceneIcon(video.scene))
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                            .help(video.scene.rawValue.capitalized)
                    }
                }
                if let duration = entry.duration {
                    metadataPill(icon: "clock", text: formatDuration(duration))
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? Color.aerial.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isCurrent else { return }
            onTapEntry(index)
        }
    }

    // MARK: - Uncached Row

    private func uncachedRow(entry: PlaylistEntry) -> some View {
        let dlState = downloadTracker.state(for: entry.videoId)
        let video = VideoList.instance.videos.first(where: { $0.id == entry.videoId })

        return HStack(spacing: 8) {
            // Thumbnail with download badge
            ZStack {
                thumbnailImage(for: entry)
                    .frame(width: 80, height: 45)
                    .clipped()
                    .cornerRadius(4)

                // Dark scrim
                Rectangle()
                    .fill(Color.black.opacity(0.4))
                    .frame(width: 80, height: 45)
                    .cornerRadius(4)

                // Download badge
                switch dlState {
                case .downloading(let progress):
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 2)
                            .frame(width: 22, height: 22)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.aerial, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 22, height: 22)
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                    }
                case .queued:
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.8))
                case .none:
                    Button(action: { onDownload(entry.videoId) }) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.borderless)
                    .help("Download this video")
                    .accessibilityLabel("Download this video")
                }
            }

            // Text + metadata
            VStack(alignment: .leading, spacing: 2) {
                if !entry.secondaryName.isEmpty {
                    Text(entry.secondaryName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }

                Text(entry.videoName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let video = video {
                    HStack(spacing: 6) {
                        Image(systemName: timeOfDayIcon(video.timeOfDay))
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                            .help(video.timeOfDay.capitalized)
                        Image(systemName: sceneIcon(video.scene))
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                            .help(video.scene.rawValue.capitalized)
                    }
                }
                if let duration = entry.duration {
                    metadataPill(icon: "clock", text: formatDuration(duration))
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .opacity(0.6)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func thumbnailImage(for entry: PlaylistEntry) -> some View {
        if let thumb = thumbnails[entry.videoId] {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    Image(systemName: "film")
                        .foregroundColor(.secondary.opacity(0.4))
                        .font(.system(size: 12))
                )
        }
    }

    private func metadataPill(icon: String, text: String?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            if let text = text {
                Text(text)
            }
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }

}

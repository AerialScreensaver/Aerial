//
//  UserPlaylistContentView.swift
//  Aerial
//
//  Content view for a user-created playlist.
//

import SwiftUI
import UniformTypeIdentifiers

struct UserPlaylistContentView: View {
    @ObservedObject var state: VideoBrowserState
    @State private var isDropTargeted = false

    private var playlistId: UUID? {
        state.userPlaylistId
    }

    private var manifest: UserPlaylistManifest? {
        guard let id = playlistId else { return nil }
        return UserPlaylistManager.shared.playlist(id: id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            if let manifest = manifest {
                headerView(manifest: manifest)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
            }

            // Content
            if let manifest = manifest, !manifest.entries.isEmpty {
                entryList(manifest: manifest)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.plainText], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay(
            Group {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.aerial, lineWidth: 2)
                        .background(Color.aerial.opacity(0.05))
                        .cornerRadius(8)
                        .padding(4)
                }
            }
        )
    }

    // MARK: - Header

    private func headerView(manifest: UserPlaylistManifest) -> some View {
        ContentHeader(
            icon: "music.note.list",
            title: manifest.name,
            description: "\(manifest.entries.count) video\(manifest.entries.count == 1 ? "" : "s")"
        ) {
            if !manifest.entries.isEmpty {
                Button(action: { shufflePlaylist() }) {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Entry List

    private func entryList(manifest: UserPlaylistManifest) -> some View {
        List {
            ForEach(Array(manifest.entries.enumerated()), id: \.element.videoId) { index, entry in
                entryRow(entry: entry, index: index)
            }
            .onMove { source, destination in
                guard let id = playlistId else { return }
                UserPlaylistManager.shared.moveEntry(from: source, to: destination, in: id)
            }
            .onDelete { offsets in
                guard let id = playlistId else { return }
                UserPlaylistManager.shared.removeEntry(at: offsets, from: id)
            }
        }
    }

    private func entryRow(entry: PlaylistEntry, index: Int) -> some View {
        let isLive = VideoList.instance.videos.first(where: { $0.id == entry.videoId })?.isLive ?? false
        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .trailing)

            // Thumbnail
            thumbnailView(for: entry.videoId)
                .frame(width: 80, height: 45)
                .clipped()
                .cornerRadius(4)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.secondaryName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(entry.videoName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let dur = entry.duration {
                Text(formatDuration(dur))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            // Per-video play-duration override: loop this clip for a set time
            // before advancing. Hidden for live feeds (they self-advance).
            if !isLive {
                PlayDurationField(
                    seconds: entry.playDuration,
                    onCommit: { newValue in
                        guard let id = playlistId else { return }
                        UserPlaylistManager.shared.setPlayDuration(newValue, forEntryAt: index, in: id)
                    }
                )
            }

            Button(action: {
                guard let id = playlistId else { return }
                UserPlaylistManager.shared.removeEntry(at: IndexSet(integer: index), from: id)
            }) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No videos yet")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Text("Drag videos here or right-click videos in the browser to add them.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private func thumbnailView(for videoId: String) -> some View {
        if let thumb = state.thumbnails[videoId] {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    Image(systemName: "film")
                        .foregroundColor(.secondary.opacity(0.4))
                        .font(.system(size: 10))
                )
                .onAppear {
                    if let video = VideoList.instance.videos.first(where: { $0.id == videoId }) {
                        state.loadThumbnail(for: video)
                    }
                }
        }
    }

    // MARK: - Actions

    private func shufflePlaylist() {
        guard let id = playlistId, var manifest = manifest else { return }
        manifest.entries.shuffle()
        // Write the shuffled manifest directly
        JSONPreferencesStore.shared.write(manifest, to: UserPlaylistIndex.playlistURL(for: id))
        state.refreshTrigger += 1
        NotificationCenter.default.post(name: UserPlaylistManager.didChangeNotification, object: nil)
    }

    // MARK: - Drop

    private func handleDrop(providers: [NSItemProvider]) {
        guard let id = playlistId else { return }
        for provider in providers {
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                guard let payload = string as? String else { return }
                let videoIds = payload.components(separatedBy: "\n").filter { !$0.isEmpty }
                DispatchQueue.main.async {
                    for videoId in videoIds {
                        guard let video = VideoList.instance.videos.first(where: { $0.id == videoId }) else { continue }
                        let entry = PlaylistEntry(
                            videoId: video.id,
                            videoName: video.name,
                            secondaryName: video.secondaryName,
                            duration: video.duration > 0 ? video.duration : nil
                        )
                        UserPlaylistManager.shared.addVideo(entry, to: id)
                    }
                }
            }
        }
    }
}

// MARK: - Play Duration Field

/// Inline `m:ss` editor for a playlist entry's optional play-duration override.
/// Empty field = "play once" (nil). Accepts "90" or "1:30"; commits on Enter or
/// when focus leaves. When set on a multi-video playlist, the player loops this
/// clip for that many seconds of playtime before advancing.
private struct PlayDurationField: View {
    let seconds: Double?
    let onCommit: (Double?) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("once", text: $text)
            .font(.system(size: 11, design: .monospaced))
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
            .focused($focused)
            .onAppear { text = Self.format(seconds) }
            .onChange(of: seconds) { newValue in
                // Reflect external changes (reload / reorder) only when not editing.
                if !focused { text = Self.format(newValue) }
            }
            .onChange(of: focused) { isFocused in
                if !isFocused { commit() }
            }
            .onSubmit { commit() }
            .help("Loop this video for this long (m:ss of playtime), then advance. Leave empty to play once.")
    }

    private func commit() {
        let parsed = Self.parse(text)
        onCommit(parsed)
        text = Self.format(parsed)   // normalize ("90" → "1:30", invalid → "")
    }

    /// nil / ≤0 → "" (placeholder shows "once"); else `m:ss`.
    static func format(_ seconds: Double?) -> String {
        guard let s = seconds, s > 0 else { return "" }
        let total = Int(s.rounded())
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    /// "" → nil, "90" → 90, "1:30" → 90. nil for invalid or ≤0. Clamps to 24h.
    static func parse(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        let totalSeconds: Int
        switch parts.count {
        case 1:
            guard let s = Int(parts[0]) else { return nil }
            totalSeconds = s
        case 2:
            guard let m = Int(parts[0]), let s = Int(parts[1]), s >= 0, s < 60 else { return nil }
            totalSeconds = m * 60 + s
        default:
            return nil
        }
        guard totalSeconds > 0 else { return nil }
        return Double(min(totalSeconds, 24 * 3600))
    }
}

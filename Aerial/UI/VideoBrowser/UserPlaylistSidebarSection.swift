//
//  UserPlaylistSidebarSection.swift
//  Aerial
//
//  Sidebar section for user-created playlists.
//

import SwiftUI

struct UserPlaylistSidebarSection: View {
    @ObservedObject var state: VideoBrowserState
    @State private var renamingId: UUID?
    @State private var renameText: String = ""
    @State private var showingCreateSheet = false
    @State private var newPlaylistName: String = ""

    var body: some View {
        // MY PLAYLISTS header
        HStack {
            Text("MY PLAYLISTS")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            Button(action: { showingCreateSheet = true }) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Create Playlist")
            .accessibilityLabel("Create Playlist")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)

        ForEach(state.userPlaylists) { summary in
            if renamingId == summary.id {
                renameRow(summary: summary)
            } else {
                playlistRow(summary: summary)
            }
        }

        // Create button row
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text("Create Playlist")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { showingCreateSheet = true }
        .padding(.horizontal, 4)

        // Create sheet
        .sheet(isPresented: $showingCreateSheet) {
            createPlaylistSheet
        }
    }

    // MARK: - Playlist Row

    private func playlistRow(summary: UserPlaylistSummary) -> some View {
        let isSelected: Bool = {
            if case .userPlaylist(let id) = state.selectedSidebarItem {
                return id == summary.id
            }
            return false
        }()

        return HStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 15))
                .foregroundColor(isSelected ? .aerial : .secondary)
                .frame(width: 20)
            Text(summary.name)
                .font(.system(size: 14))
                .foregroundColor(.primary)
                .lineLimit(1)
            Spacer()
            Text("\(summary.entryCount)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 12)
        .background(isSelected ? Color.aerial.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            state.clearSelection()
            state.selectedSidebarItem = .userPlaylist(id: summary.id)
        }
        .contextMenu {
            Button("Rename...") {
                renameText = summary.name
                renamingId = summary.id
            }
            Divider()
            Button("Delete", role: .destructive) {
                UserPlaylistManager.shared.deletePlaylist(id: summary.id)
                if case .userPlaylist(let id) = state.selectedSidebarItem, id == summary.id {
                    state.selectedSidebarItem = .allVideos
                }
            }
        }
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            handleDrop(providers: providers, playlistId: summary.id)
            return true
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Rename Row

    private func renameRow(summary: UserPlaylistSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 15))
                .foregroundColor(.aerial)
                .frame(width: 20)
            TextField("Playlist name", text: $renameText, onCommit: {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    UserPlaylistManager.shared.renamePlaylist(id: summary.id, name: trimmed)
                }
                renamingId = nil
            })
            .textFieldStyle(.plain)
            .font(.system(size: 14))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 12)
        .background(Color.aerial.opacity(0.1))
        .cornerRadius(6)
        .padding(.horizontal, 4)
    }

    // MARK: - Create Sheet

    private var createPlaylistSheet: some View {
        VStack(spacing: 16) {
            Text("New Playlist")
                .font(.headline)
            TextField("Playlist Name", text: $newPlaylistName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
            HStack {
                Button("Cancel") {
                    newPlaylistName = ""
                    showingCreateSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let summary = UserPlaylistManager.shared.createPlaylist(name: trimmed)
                        state.selectedSidebarItem = .userPlaylist(id: summary.id)
                    }
                    newPlaylistName = ""
                    showingCreateSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider], playlistId: UUID) {
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
                        UserPlaylistManager.shared.addVideo(entry, to: playlistId)
                    }
                }
            }
        }
    }
}

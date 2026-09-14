//
//  UserPlaylistSidebarSection.swift
//  Aerial
//
//  Sidebar section for user-created playlists.
//

import SwiftUI
import UniformTypeIdentifiers

struct UserPlaylistSidebarSection: View {
    @ObservedObject var state: VideoBrowserState
    @State private var renamingId: UUID?
    @State private var renameText: String = ""
    @State private var showingCreateSheet = false
    @State private var newPlaylistName: String = ""
    @State private var importMessage: String?
    /// Playlist row currently hovered by a video drag. One scalar for the
    /// whole section (only one row can be targeted at a time) because rows
    /// are built by a ForEach helper, not a subview with its own @State.
    @State private var dropTargetPlaylistId: UUID?

    var body: some View {
        // MY PLAYLISTS header
        HStack {
            Text("MY PLAYLISTS")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            Button(action: importPlaylist) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Import Playlist…")
            .accessibilityLabel("Import Playlist")
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
        // Import outcome (also carries the missing-videos warning)
        .alert("Playlist Import", isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button("OK") { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
    }

    // MARK: - Import / Export

    private func importPlaylist() {
        let panel = NSOpenPanel()
        panel.message = "Choose an exported Aerial playlist (.json)"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let result = try UserPlaylistManager.shared.importPlaylist(from: data)
            state.clearSelection()
            state.selectedSidebarItem = .userPlaylist(id: result.summary.id)
            if result.unresolvedCount > 0 {
                importMessage = "Imported \"\(result.summary.name)\" — \(result.unresolvedCount) of \(result.totalCount) videos aren't in your library. Local videos from another Mac can't be matched; Apple videos will download when played."
            }
        } catch {
            importMessage = "Couldn't import this file: \(error.localizedDescription)"
        }
    }

    private func exportPlaylist(summary: UserPlaylistSummary) {
        guard let data = UserPlaylistManager.shared.exportData(id: summary.id) else { return }

        let panel = NSSavePanel()
        panel.title = "Export Playlist"
        panel.message = "Save \"\(summary.name)\" as a shareable playlist file."
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(summary.name).aerial-playlist.json"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            importMessage = "Couldn't export: \(error.localizedDescription)"
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
        let isDropTarget = dropTargetPlaylistId == summary.id

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
        .background(isDropTarget ? Color.aerial.opacity(0.15) : (isSelected ? Color.aerial.opacity(0.1) : Color.clear))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isDropTarget ? Color.aerial : Color.clear, lineWidth: 2)
        )
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
            Button("Export...") {
                exportPlaylist(summary: summary)
            }
            Divider()
            Button("Delete", role: .destructive) {
                UserPlaylistManager.shared.deletePlaylist(id: summary.id)
                if case .userPlaylist(let id) = state.selectedSidebarItem, id == summary.id {
                    state.selectedSidebarItem = .allVideos
                }
            }
        }
        .onDrop(of: [.plainText], isTargeted: Binding(
            get: { dropTargetPlaylistId == summary.id },
            set: { targeted in
                if targeted {
                    dropTargetPlaylistId = summary.id
                } else if dropTargetPlaylistId == summary.id {
                    // Only clear if still ours — the next row's "entered"
                    // can arrive before this row's "exited".
                    dropTargetPlaylistId = nil
                }
            }
        )) { providers in
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

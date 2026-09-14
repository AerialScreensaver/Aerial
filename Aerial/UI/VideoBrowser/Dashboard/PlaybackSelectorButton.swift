//
//  PlaybackSelectorButton.swift
//  Aerial Companion
//
//  Compact Dashboard control for "what plays" on a scope: a one-line
//  summary ("Locations · Hawaii, Maui") plus a pencil button that opens the
//  full `PlaybackSelectorView` in a floating popover. Keeps cards short when
//  there are many screens.
//

import SwiftUI

struct PlaybackSelectorButton: View {
    @StateObject private var model: PlaybackSelectorModel
    @State private var showingPicker = false

    init(scope: PlaybackScope) {
        _model = StateObject(wrappedValue: PlaybackSelectorModel(scope: scope))
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: categoryIcon)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text("Plays:")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Text(summary)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            Button("Change…") {
                // Open with the source grid already revealed — no second
                // "expand" click. (Grid-less categories ignore this.)
                model.isExpanded = true
                showingPicker = true
            }
            .buttonStyle(.bordered)
            .help("Change what plays")
            .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                PlaybackSelectorView(model: model)
                    .frame(width: 380)
                    .padding(12)
            }

            Spacer(minLength: 0)
        }
        .onAppear { model.reloadState() }
        .onReceive(NotificationCenter.default.publisher(for: PlaylistManager.playlistDidChangeNotification)) { _ in
            model.reloadState()
        }
    }

    // MARK: - Summary

    private var summary: String {
        if model.showingPlaylists {
            if let id = model.activeUserPlaylistId(),
               let s = UserPlaylistManager.shared.allSummaries().first(where: { $0.id == id }) {
                return s.name
            }
            return "Playlist"
        }
        let detail = model.summaryText
        return detail.isEmpty ? categoryName : "\(categoryName) · \(detail)"
    }

    private var categoryName: String {
        if model.showingPlaylists { return "Playlist" }
        switch model.selectedCategory {
        case .everything: return "Everything"
        case .location:   return "Locations"
        case .favorites:  return "Favorites"
        case .time:       return "Times"
        case .scene:      return "Scenes"
        case .source:     return "Sources"
        case .expansions: return "Expansions"
        case .liveFeeds:  return "Live Feeds"
        }
    }

    private var categoryIcon: String {
        if model.showingPlaylists { return "music.note.list" }
        switch model.selectedCategory {
        case .everything: return "infinity"
        case .location:   return "location"
        case .favorites:  return "star"
        case .time:       return "clock"
        case .scene:      return "leaf"
        case .source:     return "video.badge.plus"
        case .expansions: return "sparkles"
        case .liveFeeds:  return "dot.radiowaves.left.and.right"
        }
    }
}

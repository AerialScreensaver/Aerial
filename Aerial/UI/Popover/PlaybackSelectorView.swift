//
//  PlaybackSelectorView.swift
//  Aerial Companion
//
//  Presentation-agnostic "what plays" picker: a category dropdown, a
//  one-line summary, a collapsible thumbnail grid of sources, and the user
//  playlist list. Driven entirely by an injected `PlaybackSelectorModel`,
//  so the same UI serves the menubar popover (`NowPlayingSectionView`) and
//  the Dashboard's per-screen picker (`PlaybackSelectorButton`).
//

import SwiftUI

struct PlaybackSelectorView: View {
    @ObservedObject var model: PlaybackSelectorModel

    var body: some View {
        VStack(spacing: 8) {
            // Header row — tappable to expand/collapse the grid.
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 20))

                categoryPicker
                    .font(.title3)

                if !model.showingPlaylists {
                    Text(model.summaryText)
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if model.hasSourceGrid {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(model.isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: model.isExpanded)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard model.hasSourceGrid else { return }
                withAnimation(.easeInOut(duration: 0.2)) { model.isExpanded.toggle() }
            }

            if model.showingPlaylists {
                userPlaylistList
            }

            if model.hasSourceGrid && model.isExpanded {
                expandedGrid
            }
        }
        .padding(.vertical, 4)
        .onAppear { model.reloadState() }
        // Re-sync whenever any code path regenerates the playlist. The
        // programmatic-sync guard inside `handleCategoryChange` keeps the
        // reseat idempotent.
        .onReceive(NotificationCenter.default.publisher(for: PlaylistManager.playlistDidChangeNotification)) { _ in
            model.reloadState()
        }
    }

    // MARK: - Category Picker

    private var categoryPicker: some View {
        Picker("", selection: $model.popoverCategory) {
            Label("Everything", systemImage: "infinity").tag(PopoverCategory.filter(.everything))
            Divider()
            Label("Locations", systemImage: "location").tag(PopoverCategory.filter(.location))
            Label("Favorites", systemImage: "star").tag(PopoverCategory.filter(.favorites))
            Label("Times", systemImage: "clock").tag(PopoverCategory.filter(.time))
            Label("Scenes", systemImage: "leaf").tag(PopoverCategory.filter(.scene))
            Label("Expansions", systemImage: "sparkles").tag(PopoverCategory.filter(.expansions))
            Label("Live Feeds", systemImage: "dot.radiowaves.left.and.right").tag(PopoverCategory.filter(.liveFeeds))
            Label("Sources", systemImage: "video.badge.plus").tag(PopoverCategory.filter(.source))
            if !UserPlaylistManager.shared.allSummaries().isEmpty {
                Divider()
                Label("Playlists", systemImage: "music.note.list").tag(PopoverCategory.playlists)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("Filter what's playing — by location, time, scene, source, expansion, live feed, or playlist")
        .onChange(of: model.popoverCategory) { newValue in
            model.handleCategoryChange(newValue)
        }
    }

    // MARK: - Expanded Grid

    private var expandedGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { model.toggleAll() }) {
                HStack(spacing: 4) {
                    Image(systemName: model.allSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundColor(model.allSelected ? .aerial : .secondary)
                    Text(model.allSelected ? "All selected" : "Select all")
                        .foregroundColor(.primary)
                }.padding(.leading, 4)
            }
            .buttonStyle(.plain)
            .help(model.allSelected ? "Deselect all" : "Select all")

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.sourceRows, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(row, id: \.self) { index in
                                let source = model.sources[index]
                                let path = model.modePrefix + source
                                let count = VideoList.instance.videos.filter { $0.sources.contains(where: { $0.name == source }) }.count
                                SourceThumbnailCard(
                                    name: source,
                                    videoCount: count,
                                    isSelected: model.selectedItems.contains(path),
                                    thumbnail: model.thumbnails[source],
                                    onTap: { model.toggleSource(path) }
                                )
                            }
                            if row.count < 4 { Spacer() }
                        }
                    }
                }
                .padding(4)
            }
            .frame(height: model.gridHeight)
        }
        .padding(4)
    }

    // MARK: - User Playlist List

    private var userPlaylistList: some View {
        // Touch the tick so SwiftUI registers this sub-view as dependent.
        _ = model.playlistActivationTick
        let summaries = UserPlaylistManager.shared.allSummaries()
        let activeId = model.activeUserPlaylistId()

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(summaries) { summary in
                let isActive = summary.id == activeId
                HStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 14))
                        .foregroundColor(isActive ? .aerial : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(summary.name)
                            .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                            .foregroundColor(isActive ? .aerial : .primary)
                            .lineLimit(1)
                        Text("\(summary.entryCount) video\(summary.entryCount == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.aerial)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(isActive ? Color.aerial.opacity(0.25) : Color.clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard summary.entryCount > 0 else { return }
                    model.activateUserPlaylist(summary.id)
                }
                .opacity(summary.entryCount > 0 ? 1.0 : 0.5)
            }

            Button(action: { model.backToFilters() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12))
                    Text("Back to filter-based playback")
                        .font(.system(size: 12))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .opacity(model.isUserPlaylistActive() ? 1.0 : 0.0)
        }
        .padding(4)
    }
}

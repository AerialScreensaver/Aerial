//
//  DashboardSharedCard.swift
//  Aerial Companion
//
//  The single unified Dashboard "mini-player" card shown in shared viewing
//  modes (cloned / spanned / mirrored), where all displays are driven by
//  one shared playlist. Header: a mode banner + the "what plays" selector.
//  Body: a two-column layout — left is the full display-arrangement
//  miniature with the now-playing line and ⏮ ⏯ ⏭ transport; right is the
//  shared playlist (tap to jump), reusing `PlaylistSectionView`.
//

import SwiftUI

struct DashboardSharedCard: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(alignment: .top, spacing: 16) {
                leftColumn
                Divider()
                PlaylistSectionView(
                    playbackManager: model.playbackManager,
                    scope: .screen(nil),
                    showsSpeedSlider: false
                )
                .frame(maxHeight: 260)
            }

            Divider().padding(.vertical, 2)
            DashboardOverlayStatusRow(screenUUID: nil, perScreen: model.overlayPerScreen)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Label("All displays — \(model.viewingMode.displayName.capitalized)",
                  systemImage: modeIcon)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize()
            PlaybackSelectorButton(scope: .screen(nil))
        }
    }

    // MARK: - Left column (preview + now playing + transport)

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            miniature

            DashboardPauseMention(playbackManager: model.playbackManager, screenUUID: nil)

            nowPlaying

            DashboardTransportControls(
                playbackManager: model.playbackManager,
                screenUUID: nil,
                entryCount: model.entryCount(for: nil)
            )
            .padding(.top, 2)
        }
        .frame(width: 260)
    }

    private var modeIcon: String {
        switch model.viewingMode {
        case .cloned:   return "rectangle.on.rectangle"
        case .spanned:  return "rectangle.split.2x1"
        case .mirrored: return "rectangle.2.swap"
        case .independent: return "display"   // not reached in this card
        }
    }

    // MARK: - Miniature

    private var miniature: some View {
        DashboardMiniature(
            image: model.thumbnail(for: nil),
            refreshID: model.projectionRefreshID
        )
        .frame(width: 260, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Now Playing

    @ViewBuilder
    private var nowPlaying: some View {
        if let text = model.nowPlayingText(for: nil) {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                Text(text)
                    .font(.system(size: 13))
                    .lineLimit(2)
            }
            .foregroundColor(.secondary)
        } else {
            Text("Nothing in the playlist")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
    }
}

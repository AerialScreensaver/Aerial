//
//  DashboardScreenCard.swift
//  Aerial Companion
//
//  One Dashboard "mini-player" card for a single display in independent
//  viewing mode. Header: the display name + the "what plays" selector.
//  Body (when active): a two-column layout — left is a larger preview with
//  the now-playing line and ⏮ ⏯ ⏭ transport; right is the display's full
//  playlist (tap a thumbnail/row to jump), reusing the popover's
//  `PlaylistSectionView` scoped to this screen.
//

import SwiftUI

struct DashboardScreenCard: View {
    let screen: PlaybackManager.ScreenInfo
    @ObservedObject var model: DashboardModel
    /// Live cue for the preview styling only — never gates the playlist or
    /// controls (the per-display content always shows, like the shared
    /// card). True when the wallpaper extension is running. Replaces the
    /// old `activeScreenUuids` gate, which only ever reflected the legacy
    /// desktop-launcher path and is empty when the extension is the
    /// wallpaper — the cause of the bogus "Not playing on this display".
    @ObservedObject private var statusMonitor = WallpaperStatusMonitor.shared

    private var screenUUID: String { screen.uuid }
    private var aspect: CGFloat { screen.aspect }
    private var isMain: Bool { screen.isMain }
    private var isLive: Bool { statusMonitor.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            // Always render the per-display content (mirrors
            // DashboardSharedCard). Empty / not-running states are handled
            // inside the body (now-playing → "Nothing in this playlist";
            // transport disabled when the playlist is empty).
            HStack(alignment: .top, spacing: 16) {
                leftColumn
                    .frame(width: 240)
                Divider()
                PlaylistSectionView(
                    playbackManager: model.playbackManager,
                    scope: .screen(screenUUID),
                    showsSpeedSlider: false
                )
                .frame(maxHeight: 260)
            }

            if model.overlayPerScreen {
                Divider().padding(.vertical, 2)
                DashboardOverlayStatusRow(screenUUID: screenUUID, perScreen: true)
            }
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
            Text(screen.name)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize()
            PlaybackSelectorButton(scope: .screen(screenUUID))
            Spacer(minLength: 0)
        }
    }

    // MARK: - Left column (preview + now playing + transport)

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScreenThumbnailView(
                aspect: aspect,
                isMain: isMain,
                isActive: isLive,
                thumbnail: model.thumbnail(for: screenUUID),
                maxWidth: 240,
                maxHeight: 135
            )

            DashboardPauseMention(playbackManager: model.playbackManager, screenUUID: screenUUID)

            nowPlaying

            DashboardTransportControls(
                playbackManager: model.playbackManager,
                screenUUID: screenUUID,
                entryCount: model.entryCount(for: screenUUID)
            )
            .padding(.top, 2)
        }
    }

    // MARK: - Now Playing

    @ViewBuilder
    private var nowPlaying: some View {
        if let text = model.nowPlayingText(for: screenUUID) {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                Text(text)
                    .font(.system(size: 13))
                    .lineLimit(2)
            }
            .foregroundColor(.secondary)
        } else {
            Text("Nothing in this playlist")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
    }

}

// MARK: - Transport controls

/// Prev / play-pause / next transport for a Dashboard mini-player.
/// Observes `PlaybackManager` directly so the play/pause icon tracks live
/// playback state. Prev/next are scoped to `screenUUID`; play/pause is
/// global (all displays) in v1 — the help text says so. Shared by both the
/// per-screen and the shared cards (kept here, non-private, to avoid adding
/// a new file to the project).
struct DashboardTransportControls: View {
    @ObservedObject var playbackManager: PlaybackManager
    let screenUUID: String?
    let entryCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Button {
                playbackManager.previousVideo(screenUUID: screenUUID)
            } label: {
                Image(systemName: "backward.fill")
            }
            .help("Previous video")

            Button {
                playbackManager.togglePause()
            } label: {
                Image(systemName: pauseIcon)
            }
            .help(pauseHelp)

            Button {
                playbackManager.nextVideo(screenUUID: screenUUID)
            } label: {
                Image(systemName: "forward.fill")
            }
            .help("Next video")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        // The wallpaper is the extension — only an empty playlist disables the transport.
        .disabled(entryCount == 0)
    }

    private var pauseIcon: String {
        playbackManager.isPaused ? "play.fill" : "pause.fill"
    }

    private var pauseHelp: String {
        (playbackManager.isPaused ? "Resume" : "Pause") + " — affects all displays"
    }
}

// MARK: - Auto-paused mention

/// Small "auto-paused" mention shown under a card's preview when playback is
/// paused by an automatic reason (battery or coverage), independent of the
/// user's own play/pause status (which lives on the transport button).
/// Observes `PlaybackManager` so it tracks battery/coverage live. Shared by
/// the per-screen and shared cards (kept here, non-private, to avoid adding a
/// new file to the project).
struct DashboardPauseMention: View {
    @ObservedObject var playbackManager: PlaybackManager
    let screenUUID: String?            // nil = shared surface (aggregate)

    var body: some View {
        if let m = mention {
            Label(m.text, systemImage: m.icon)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    /// Only while this scope intends to play (not user-paused). Shared
    /// with the popover via `PlaybackManager.pauseMention(for:)`.
    private var mention: (icon: String, text: String)? {
        playbackManager.pauseMention(for: screenUUID)
    }
}

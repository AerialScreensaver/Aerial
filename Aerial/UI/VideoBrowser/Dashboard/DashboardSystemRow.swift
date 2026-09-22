//
//  DashboardSystemRow.swift
//  Aerial Companion
//
//  Home-dashboard row with the system-integration cards: start the
//  screensaver immediately / set Aerial as the saver, and live
//  wallpaper-extension controls driven by the status channel. This is
//  the permanent home of the main controls that lived in the retired
//  "Aerial 4 (Beta)" settings panel.
//

import SwiftUI

struct DashboardSystemRow: View {
    @ObservedObject private var statusMonitor = WallpaperStatusMonitor.shared

    /// User pause intent, mirrored from WallpaperControl (which isn't
    /// observable) — refreshed on appear and on every status echo.
    @State private var wallpaperPaused = WallpaperControl.shared.currentPaused

    /// Whether Aerial4 is the *selected* system wallpaper / screensaver (read from
    /// the wallpaper store — distinct from `statusMonitor.isRunning`, the live process).
    @State private var isWallpaperSet = false
    @State private var isScreensaverSet = false
    @State private var isSettingWallpaper = false
    @State private var isSettingScreensaver = false

    /// Opt-in "Restart" button in the Wallpaper card (Settings →
    /// Wallpaper → Troubleshooting). Live-updated via the pref
    /// notification: the Video Library window can stay open while the
    /// Settings checkbox is toggled.
    @State private var showRestartButton = Preferences.showRestartWallpaperButton
    @State private var isRestartingAgent = false

    var body: some View {
        HStack(spacing: 12) {
            screensaverCard
            wallpaperCard
        }
        .onAppear {
            wallpaperPaused = WallpaperControl.shared.currentPaused
            showRestartButton = Preferences.showRestartWallpaperButton
            refreshSetState()
        }
        .onReceive(statusMonitor.$status) { _ in
            wallpaperPaused = WallpaperControl.shared.currentPaused
            refreshSetState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showRestartWallpaperButtonDidChange)) { notification in
            showRestartButton = (notification.object as? Bool) ?? Preferences.showRestartWallpaperButton
        }
    }

    private func restartWallpaperAgent() {
        Task { @MainActor in
            isRestartingAgent = true
            await WallpaperExtensionHealth.restartAgentAndReload(reason: "Home button")
            isRestartingAgent = false
        }
    }

    /// Re-read whether Aerial4 is the active wallpaper / screensaver.
    private func refreshSetState() {
        isWallpaperSet = (WallpaperControl.isAerialSystemWallpaper() == true)
        isScreensaverSet = (WallpaperControl.isAerialSystemScreensaver() == true)
    }

    // MARK: - Screensaver card

    private var screensaverCard: some View {
        RecapCard(title: "Screensaver", showsMenu: false, menu: { EmptyView() }) {
            HStack(spacing: 12) {
                Image(systemName: "display")
                    .font(.system(size: 26))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(isScreensaverSet
                         ? "Aerial runs as your screensaver via the wallpaper extension."
                         : "Aerial isn't set as your screensaver yet.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if isScreensaverSet {
                            Button("Start now") {
                                PlaybackManager.shared.startScreensaver()
                            }
                            .buttonStyle(.bordered)
                            .help("Start the screensaver immediately")
                        } else {
                            Button("Set as screensaver") {
                                Task {
                                    isSettingScreensaver = true
                                    _ = await WallpaperControl.setAerialAsScreensaver()
                                    refreshSetState()
                                    isSettingScreensaver = false
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSettingScreensaver)
                            .help("Set Aerial 4 as your screensaver")
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Wallpaper card

    private var wallpaperCard: some View {
        RecapCard(title: "Wallpaper", showsMenu: false, menu: { EmptyView() }) {
            if isWallpaperSet {
                runningControls
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 26))
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Aerial isn't set as your wallpaper yet.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Set as wallpaper") {
                            Task {
                                isSettingWallpaper = true
                                _ = await WallpaperControl.setAerialAsWallpaper()
                                refreshSetState()
                                isSettingWallpaper = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSettingWallpaper)
                        .help("Set Aerial 4 as your desktop wallpaper")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var runningControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    WallpaperControl.shared.regressVideo(screenUUID: nil)
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.bordered)
                .help("Previous video (all displays)")

                Button {
                    wallpaperPaused.toggle()
                    WallpaperControl.shared.setPaused(wallpaperPaused)
                } label: {
                    Image(systemName: wallpaperPaused ? "play.fill" : "pause.fill")
                        .frame(width: 22)
                }
                .buttonStyle(.bordered)
                .help(wallpaperPaused ? "Resume the wallpaper" : "Pause the wallpaper")

                Button {
                    WallpaperControl.shared.advanceVideo(screenUUID: nil)
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(.bordered)
                .help("Next video (all displays)")

                if showRestartButton {
                    Button {
                        restartWallpaperAgent()
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRestartingAgent)
                    .padding(.leading, 8)
                    .help("Restart the wallpaper agent — use it if you see the default wallpaper or a black screen")
                }

                Spacer(minLength: 0)
            }

            if let mention = pauseMention {
                Label(mention.text, systemImage: mention.icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else if let nowPlaying = nowPlayingText {
                Label(nowPlaying, systemImage: "play.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// Mirrors DashboardPauseMention's priorities for the extension:
    /// coverage (truthful, from the status echo) wins over the plain
    /// user pause.
    private var pauseMention: (icon: String, text: String)? {
        if let status = statusMonitor.status, !status.autoPausedScreens.isEmpty {
            return ("macwindow", "Paused — display covered")
        }
        if wallpaperPaused {
            return ("pause.circle", "Paused")
        }
        return nil
    }

    private var nowPlayingText: String? {
        guard let names = statusMonitor.status?.nowPlaying, !names.isEmpty else { return nil }
        let unique = Array(Set(names.values)).sorted()
        if unique.count == 1 { return unique[0] }
        return "\(unique[0]) and \(unique.count - 1) more"
    }
}

//
//  ModeSectionView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

/// Top row with two equal mode buttons: Screensaver and Wallpaper.
struct ModeSectionView: View {
    @ObservedObject var playbackManager: PlaybackManager
    var onDismiss: () -> Void

    /// Source of truth for "is the wallpaper extension running" (drives the
    /// wallpaper button's play/pause vs. guide-to-Settings state).
    @ObservedObject private var statusMonitor = WallpaperStatusMonitor.shared

    /// User pause intent mirrored from WallpaperControl (not observable);
    /// refreshed on appear and on every status echo.
    @State private var wallpaperPaused = WallpaperControl.shared.currentPaused

    var body: some View {
        HStack(spacing: 8) {
            // Screensaver button — starts the OS screensaver now (which
            // renders Aerial via the wallpaper extension's idle mode).
            Button(action: {
                playbackManager.startScreensaver()
                onDismiss()
            }) {
                modeLabel(icon: "lock.display", title: "Screensaver")
            }
            .buttonStyle(.plain)
            .help("Start the screensaver now")

            // Wallpaper button.
            wallpaperButton
        }
        .onAppear { wallpaperPaused = WallpaperControl.shared.currentPaused }
        .onReceive(statusMonitor.$status) { _ in
            wallpaperPaused = WallpaperControl.shared.currentPaused
        }
    }

    /// Wallpaper control: a play/pause toggle for the wallpaper extension.
    /// When it's running, flips static ↔ animated (`WallpaperControl.paused`);
    /// when Aerial 4 isn't the active system wallpaper yet, it points the
    /// user at System Settings (enabling it in-app is a future PaperSaver
    /// capability — see WallpaperControl TODOs).
    private var wallpaperButton: some View {
        Button(action: {
            if statusMonitor.isRunning {
                wallpaperPaused.toggle()
                WallpaperControl.shared.setPaused(wallpaperPaused)
            } else {
                _ = Helpers.shell(launchPath: "/usr/bin/open", arguments: [
                    "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
                ])
            }
            onDismiss()
        }) {
            modeLabel(
                icon: wallpaperButtonIcon,
                title: "Wallpaper",
                isActive: statusMonitor.isRunning && !wallpaperPaused,
                stopWhenActive: false
            )
        }
        .buttonStyle(.plain)
        .help(wallpaperButtonHelp)
    }

    private var wallpaperButtonIcon: String {
        if !statusMonitor.isRunning { return "menubar.dock.rectangle" }
        return wallpaperPaused ? "play.fill" : "pause.fill"
    }

    private var wallpaperButtonHelp: String {
        if !statusMonitor.isRunning {
            return "Choose Aerial 4 in System Settings → Wallpaper to use the live wallpaper"
        }
        return wallpaperPaused ? "Resume the animated wallpaper" : "Pause the wallpaper (static frame)"
    }

    private func modeLabel(
        icon: String,
        title: String,
        isActive: Bool = false,
        stopWhenActive: Bool = true
    ) -> some View {
        VStack(spacing: 4) {
            Image(systemName: (isActive && stopWhenActive) ? "stop.fill" : icon)
                .font(.system(size: 20, weight: .semibold))
            Text(title)
                .font(.body)
        }
        .foregroundColor(.aerial)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        // minHeight (not exact height) lets the button grow under Dynamic
        // Type while keeping the two siblings on a shared baseline.
        .frame(minHeight: 64)
        .background(Color.aerial.opacity(isActive ? 0.25 : 0.1))
        .cornerRadius(8)
        .contentShape(Rectangle())
    }
}

struct ModeSectionView_Previews: PreviewProvider {
    static var previews: some View {
        ModeSectionView(
            playbackManager: PlaybackManager.shared,
            onDismiss: {}
        )
        .padding()
        .frame(width: 380)
    }
}

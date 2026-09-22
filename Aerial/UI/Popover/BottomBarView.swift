//
//  BottomBarView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

/// Bottom bar with info, settings, help buttons and version label
struct BottomBarView: View {
    @Environment(\.openWindow) private var openWindow

    let version: String
    var onOpenInfo: () -> Void
    /// Called *after* the Video Library window is opened so the
    /// AppDelegate can dismiss the surrounding popover. The window
    /// itself is opened in-place via `@Environment(\.openWindow)`.
    var onOpenVideoBrowser: () -> Void
    var onOpenSettings: () -> Void
    var onExit: () -> Void

    /// Opt-in restart chip (Settings → Wallpaper → Troubleshooting).
    /// Seeded on every popover open — the whole popover tree is
    /// dismounted while closed — and live-updated via the pref
    /// notification for the rare open-while-toggling case.
    @State private var showRestartButton = Preferences.showRestartWallpaperButton
    @State private var isRestarting = false

    var body: some View {
        HStack(spacing: 8) {
            // Info button
            Button(action: onOpenInfo) {
                chipLabel(icon: "info.circle")
            }
            .buttonStyle(.plain)
            .help("About Aerial")
            .accessibilityLabel("About Aerial")

            // Settings button
            Button(action: {
                SettingsWindowController.show(via: openWindow)
                onOpenSettings()
            }) {
                chipLabel(icon: "gear")
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
            .keyboardShortcut(",", modifiers: .command)

            // Video Browser button
            Button(action: {
                VideoBrowserWindowController.show(via: openWindow)
                onOpenVideoBrowser()
            }) {
                chipLabel(icon: "film.stack")
            }
            .buttonStyle(.plain)
            .help("Video Library")
            .accessibilityLabel("Video Library")

            Spacer()

            // Version label
            Text(version)
                .font(.title3).bold()
                .foregroundStyle(.tertiary)

            Spacer()

            // Restart wallpaper agent (opt-in)
            if showRestartButton {
                Button(action: restartWallpaperAgent) {
                    chipLabel(icon: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(isRestarting)
                .opacity(isRestarting ? 0.5 : 1)
                .help("Restart the wallpaper agent")
                .accessibilityLabel("Restart Wallpaper Agent")
            }

            // Exit button
            Button(action: onExit) {
                chipLabel(icon: "xmark.circle")
            }
            .buttonStyle(.plain)
            .help("Quit Aerial")
            .accessibilityLabel("Quit Aerial")
        }
        .padding(.top, 8)
        .onReceive(NotificationCenter.default.publisher(for: .showRestartWallpaperButtonDidChange)) { notification in
            showRestartButton = (notification.object as? Bool) ?? Preferences.showRestartWallpaperButton
        }
    }

    private func restartWallpaperAgent() {
        Task { @MainActor in
            isRestarting = true
            await WallpaperExtensionHealth.restartAgentAndReload(reason: "Menu bar button")
            isRestarting = false
        }
    }

    private func chipLabel(icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(.aerial)
            .frame(width: 44, height: 36)
            .background(Color.aerial.opacity(0.1))
            .cornerRadius(8)
            .contentShape(Rectangle())
    }
}

struct BottomBarView_Previews: PreviewProvider {
    static var previews: some View {
        BottomBarView(
            version: "3.5",
            onOpenInfo: {},
            onOpenVideoBrowser: {},
            onOpenSettings: {},
            onExit: {}
        )
        .padding()
        .frame(width: 380)
    }
}

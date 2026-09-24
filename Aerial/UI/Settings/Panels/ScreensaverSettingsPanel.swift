//
//  ScreensaverSettingsPanel.swift
//  Aerial Companion
//
//  Screensaver-only options. Shown in full only when the wallpaper mode is
//  Off: with Aerial also the desktop wallpaper, the saver shares the
//  desktop's renderer and these options have nothing to act on.
//

import SwiftUI

struct ScreensaverSettingsPanel: View {
    @State private var advanceAtLaunch: Bool = false
    /// Snapshot of `Preferences.wallpaperMode` at panel-appear time.
    @State private var wallpaperMode: WallpaperMode = .animated
    /// Companion's observed "Aerial is the system wallpaper" bit — what the
    /// extension actually gates on (a stale store entry can keep it true
    /// after the mode was switched to Off).
    @State private var desktopWallpaperActive: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Screensaver")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)

                if wallpaperMode == .off {
                    playbackSection
                } else {
                    wallpaperOnNote
                }

                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear { loadSettings() }
    }

    // MARK: - Playback

    private var playbackSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Don't resume video at launch", isOn: $advanceAtLaunch)
                    .font(.system(size: 14))
                    .onChange(of: advanceAtLaunch) { newValue in
                        // Only a user flip — loadSettings sets it to the pref value.
                        guard newValue != PrefsVideos.saverAdvanceAtLaunch else { return }
                        PrefsVideos.saverAdvanceAtLaunch = newValue
                        // The extension's settings cache is load-once; the
                        // generation bump makes a running one re-read.
                        WallpaperControl.shared.displaysConfigDidChange()
                    }

                Text("When the screensaver starts, play the next video in the playlist instead of resuming the last one where it stopped.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if desktopWallpaperActive {
                    Text("Aerial still appears to be set as the desktop wallpaper; this option takes effect once it isn't.")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        } label: {
            Label("Playback", systemImage: "play.circle")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    private var wallpaperOnNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)
            Text("These options apply when Aerial is not your desktop wallpaper (Wallpaper mode: Off).")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Private Methods

    private func loadSettings() {
        wallpaperMode = Preferences.wallpaperMode
        advanceAtLaunch = PrefsVideos.saverAdvanceAtLaunch
        desktopWallpaperActive = WallpaperControl.shared.desktopWallpaperActive
    }
}

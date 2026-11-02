//
//  ScreensaverSettingsPanel.swift
//  Aerial Companion
//
//  Screensaver options. Activation (the system's idle delay and display
//  sleep) always applies. Playback options are shown only when the
//  wallpaper mode is Off: with Aerial also the desktop wallpaper, the saver
//  shares the desktop's renderer and they have nothing to act on.
//

import SwiftUI

struct ScreensaverSettingsPanel: View {
    /// Picker choices for the system idle delay, in seconds; 0 = never.
    private static let idleChoices = [60, 120, 300, 600, 1200, 1800, 3600, 0]

    /// Mirrors `com.apple.screensaver` `idleTime` (current host), in seconds.
    @State private var idleSeconds: Int = 0
    /// Display sleep for the current power source, in minutes; nil = unknown.
    @State private var displaySleepMinutes: Int?
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

                activationSection

                if wallpaperMode == .off {
                    playbackSection
                }

                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear { loadSettings() }
        .task { await loadDisplaySleep() }
        // Both values can be changed in System Settings › Lock Screen; pick
        // the change up when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            idleSeconds = WallpaperControl.screensaverIdleSeconds
            Task { await loadDisplaySleep() }
        }
    }

    // MARK: - Activation

    private var activationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Start screensaver after")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    Picker("", selection: $idleSeconds) {
                        ForEach(Self.idleChoices, id: \.self) { seconds in
                            Text(Self.idleTitle(seconds)).tag(seconds)
                        }
                        if !Self.idleChoices.contains(idleSeconds) {
                            Text("Custom (\(Self.idleTitle(idleSeconds)))").tag(idleSeconds)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 220, alignment: .trailing)
                    .onChange(of: idleSeconds) { newValue in
                        // Only a user pick — loads set it to the system value.
                        guard newValue != WallpaperControl.screensaverIdleSeconds else { return }
                        WallpaperControl.setScreensaverIdleSeconds(newValue)
                    }
                }

                HStack {
                    Text("Turn display off after")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text(displaySleepMinutes.map { Self.idleTitle($0 * 60) } ?? "Unknown")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Button("Open Lock Screen Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }

                Text("The display must stay on longer than the screensaver delay, or the screensaver never shows. Change when the display turns off in System Settings.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let displaySleepMinutes {
                    Divider()
                    ScreensaverTimelineView(
                        // Round a sub-minute delay up so it doesn't read as "disabled".
                        activationMinutes: idleSeconds == 0 ? 0 : max(1, idleSeconds / 60),
                        displaySleepMinutes: displaySleepMinutes
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        } label: {
            Label("Activation", systemImage: "clock")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    private static func idleTitle(_ seconds: Int) -> String {
        if seconds == 0 { return "Never" }
        if seconds < 60 { return "\(seconds) seconds" }
        if seconds % 3600 == 0 { let h = seconds / 3600; return "\(h) hour\(h == 1 ? "" : "s")" }
        let m = seconds / 60
        return "\(m) minute\(m == 1 ? "" : "s")"
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

    // MARK: - Private Methods

    private func loadSettings() {
        idleSeconds = WallpaperControl.screensaverIdleSeconds
        wallpaperMode = Preferences.wallpaperMode
        advanceAtLaunch = PrefsVideos.saverAdvanceAtLaunch
        desktopWallpaperActive = WallpaperControl.shared.desktopWallpaperActive
    }

    private func loadDisplaySleep() async {
        displaySleepMinutes = await WallpaperControl.displaySleepMinutes()
    }
}

//
//  OtherSettingsPanel.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

@available(macOS 13.0, *)
struct OtherSettingsPanel: View {
    // Screen saver updates
    @State private var getBetaReleases: Bool = false
    @State private var updateMode: CompanionUpdateMode = .automatic
    @State private var checkEvery: CheckEvery = .day

    // Companion
    @State private var launchMode: LaunchMode = .manual

    // Desktop Background
    @State private var restartAtLaunch: Bool = false

    // Watchdog
    @State private var enableWatchdog: Bool = false
    @State private var watchdogDelay: Int = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                Text("Other Settings")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)

                // Screen Saver Updates Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        // Beta releases
                        HStack {
                            Text("Get beta releases")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $getBetaReleases) {
                                Text("Yes").tag(true)
                                Text("No").tag(false)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 100)
                            .onChange(of: getBetaReleases) { newValue in
                                Preferences.desiredVersion = newValue ? .beta : .release
                            }
                        }

                        Divider()

                        // Update mode
                        HStack {
                            Text("Update mode")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $updateMode) {
                                Text("Automatic").tag(CompanionUpdateMode.automatic)
                                Text("Notify me").tag(CompanionUpdateMode.notifyme)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 120)
                            .onChange(of: updateMode) { newValue in
                                Preferences.updateMode = newValue
                            }
                        }

                        Divider()

                        // Check every
                        HStack {
                            Text("Check every")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $checkEvery) {
                                Text("Hour").tag(CheckEvery.hour)
                                Text("Day").tag(CheckEvery.day)
                                Text("Week").tag(CheckEvery.week)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 100)
                            .onChange(of: checkEvery) { newValue in
                                Preferences.checkEvery = newValue
                            }

                            Button("Check now") {
                                checkForUpdates()
                            }
                            .controlSize(.large)
                        }
                    }
                    .padding(12)
                } label: {
                    Label("Screen Saver Updates", systemImage: "arrow.down.circle")
                }

                // Companion Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Launch Companion")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $launchMode) {
                                Text("Manually").tag(LaunchMode.manual)
                                Text("At startup").tag(LaunchMode.startup)
                                Text("In the background").tag(LaunchMode.background)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 160)
                            .onChange(of: launchMode) { newValue in
                                Preferences.launchMode = newValue
                                LaunchAgent.update()
                            }
                        }
                    }
                    .padding(12)
                } label: {
                    Label("Companion", systemImage: "app.badge")
                }

                // Desktop Background Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Restart at launch", isOn: $restartAtLaunch)
                            .font(.system(size: 14))
                            .onChange(of: restartAtLaunch) { newValue in
                                Preferences.restartBackground = newValue
                            }

                        Text("When enabled, the desktop background mode will automatically restart when Companion launches.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                } label: {
                    Label("Desktop Background", systemImage: "desktopcomputer")
                }

                // Watchdog Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Enable watchdog", isOn: $enableWatchdog)
                            .font(.system(size: 14))
                            .onChange(of: enableWatchdog) { newValue in
                                Preferences.enableScreensaverWatchdog = newValue
                            }

                        if enableWatchdog {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Timer delay: \(watchdogDelay) seconds")
                                    .font(.system(size: 14))

                                Slider(
                                    value: Binding(
                                        get: { Double(watchdogDelay) },
                                        set: { watchdogDelay = Int($0) }
                                    ),
                                    in: 1...15,
                                    step: 1
                                )
                                .onChange(of: watchdogDelay) { newValue in
                                    Preferences.watchdogTimerDelay = newValue
                                }
                            }

                            Text("Time delay in seconds (1-15s). After the screen is unlocked, it waits for that duration before killing legacyScreenSaver. 5s is the default, if things get stuck you can try changing it.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                } label: {
                    Label("Legacy Screensaver Watchdog", systemImage: "eye")
                }

                Spacer()
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            loadSettings()
        }
    }

    // MARK: - Private Methods

    private func loadSettings() {
        getBetaReleases = Preferences.desiredVersion == .beta
        updateMode = Preferences.updateMode
        checkEvery = Preferences.checkEvery
        launchMode = Preferences.launchMode
        restartAtLaunch = Preferences.restartBackground
        enableWatchdog = Preferences.enableScreensaverWatchdog
        watchdogDelay = Preferences.watchdogTimerDelay
    }

    private func checkForUpdates() {
        // Get the app delegate and trigger update check
        if let appDelegate = NSApp.delegate as? AppDelegate {
            // Open the update check window via the popover controller
            appDelegate.popoverViewController.openSettingsClick(self)
        }
    }
}

// MARK: - Preview

@available(macOS 13.0, *)
struct OtherSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        OtherSettingsPanel()
            .frame(width: 500, height: 600)
    }
}

//
//  ScreensaverSettingsPanel.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI
import IOKit.ps

// MARK: - Activation Time Options

enum ActivationTime: Int, CaseIterable, Identifiable {
    case oneMinute = 1
    case twoMinutes = 2
    case fiveMinutes = 5
    case tenMinutes = 10
    case twentyMinutes = 20
    case thirtyMinutes = 30
    case oneHour = 60
    case never = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .oneMinute: return "1 minute"
        case .twoMinutes: return "2 minutes"
        case .fiveMinutes: return "5 minutes"
        case .tenMinutes: return "10 minutes"
        case .twentyMinutes: return "20 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .never: return "Never"
        }
    }

    static func fromMinutes(_ minutes: Int) -> ActivationTime? {
        return ActivationTime(rawValue: minutes)
    }
}

// MARK: - Screensaver Settings Panel

struct ScreensaverSettingsPanel: View {
    @ObservedObject private var screensaverManager = AerialPluginManager.shared
    @State private var selectedActivationTime: ActivationTime = .fiveMinutes
    @State private var customMinutes: Int? = nil
    @State private var displaySleepMinutes: Int = 0
    @State private var isLoading: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                Text("Screensaver")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)

                // Status Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        // Row 1: App Location
                        HStack(spacing: 8) {
                            switch screensaverManager.appLocation {
                            case .systemApplications:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Installed for all users in /Applications")
                                        .font(.system(size: 14, weight: .medium))
                                }
                            case .userApplications:
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.yellow)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Installed locally in ~/Applications")
                                        .font(.system(size: 14, weight: .medium))
                                    Text("Settings/Cache are shared between all users")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            case .other:
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Not installed in Applications folder")
                                        .font(.system(size: 14, weight: .medium))
                                }
                            }
                            Spacer()
                        }

                        Divider()

                        // Row 2: Plugin Registration
                        HStack(spacing: 8) {
                            if screensaverManager.isPluginRegistered {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Screensaver extension registered")
                                    .font(.system(size: 14, weight: .medium))
                            } else {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.yellow)
                                Text("Screensaver extension not registered")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            Spacer()
                            if !screensaverManager.isPluginRegistered {
                                Button("Register") {
                                    screensaverManager.registerPlugin()
                                }
                                .controlSize(.small)
                            }
                        }

                        Divider()

                        // Row 3: Screensaver Enabled
                        HStack(spacing: 8) {
                            if screensaverManager.isScreensaverEnabled {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Set as active screensaver")
                                    .font(.system(size: 14, weight: .medium))
                            } else {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.yellow)
                                Text("Not set as active screensaver")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            Spacer()
                            if !screensaverManager.isScreensaverEnabled {
                                Button("Enable") {
                                    Task {
                                        await screensaverManager.enableScreensaver()
                                    }
                                }
                                .controlSize(.small)
                            }
                        }

                        // Duplicate-registration warning. A known cause of the
                        // screensaver initialising then never starting (black
                        // screen until a macOS restart). Debug-mode only for now.
                        if PrefsAdvanced.debugMode && !screensaverManager.staleRegistrations.isEmpty {
                            Divider()
                            duplicateRegistrationsWarning
                        }

                        Divider()

                        // Timeline
                        ScreensaverTimelineView(
                            activationMinutes: selectedActivationTime.rawValue,
                            displaySleepMinutes: displaySleepMinutes
                        )
                    }
                    .padding(12)
                } label: {
                    Label("Status", systemImage: "checkmark.shield").font(Font.title3.bold()).padding(4)
                }

                // Start After Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Start after")
                                .font(.system(size: 14, weight: .medium))

                            Spacer()

                            Picker("", selection: $selectedActivationTime) {
                                ForEach(ActivationTime.allCases) { time in
                                    Text(time.title).tag(time)
                                }
                                if customMinutes != nil {
                                    Text("Custom (\(customMinutes!) min)").tag(ActivationTime.never)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 220, alignment: .trailing)
                            .onChange(of: selectedActivationTime) { newValue in
                                customMinutes = nil
                                SystemPrefs.setSaverActivationTime(time: newValue.rawValue)
                            }
                        }

                        Text("How long to wait before the screensaver starts when your Mac is idle.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                } label: {
                    Label("Activation", systemImage: "clock").font(Font.title3.bold()).padding(4)
                }

                // Sleep Screen Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Sleep screen after")
                                .font(.system(size: 14, weight: .medium))

                            Spacer()

                            Button(action: openEnergySettings) {
                                Text(displaySleepMinutes == 0 ? "Never" : "\(displaySleepMinutes) minutes")
                                    .frame(width: 120)
                            }
                            .controlSize(.large)
                        }

                        Text("Open System Settings to change when your display turns off. This time must be longer that the one above, or the screensaver won't run at all.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                } label: {
                    Label("Display Sleep", systemImage: "moon.zzz").font(Font.title3.bold()).padding(4)
                }

                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .task {
            await loadSettings()
        }
    }

    // MARK: - Duplicate Registrations (debug)

    private var duplicateRegistrationsWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(screensaverManager.staleRegistrations.count) duplicate screensaver registration(s) found")
                        .font(.system(size: 14, weight: .medium))
                    Text("Duplicate registrations of the extension can stop the screensaver from starting — it initialises, then shows a black screen until a restart. Removing the stale ones usually fixes it.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            ForEach(screensaverManager.staleRegistrations) { reg in
                Text("• \(reg.version) — \(reg.path)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Button("Remove duplicate registration(s)") {
                screensaverManager.removeStaleRegistrations()
            }
        }
    }

    // MARK: - Private Methods

    private func loadSettings() async {
        isLoading = true

        // Refresh the duplicate-registration scan when the panel opens so the
        // warning reflects the current state (registrations can change between
        // launch and now). Fast pluginkit query; safe on the main actor.
        screensaverManager.scanScreensaverRegistrations()

        // Load activation time
        let activationMinutes = await Task.detached {
            SystemPrefs.getSaverActivationTime() ?? 0
        }.value

        if let time = ActivationTime.fromMinutes(activationMinutes) {
            selectedActivationTime = time
            customMinutes = nil
        } else {
            // Custom time not in our list
            customMinutes = activationMinutes
            selectedActivationTime = .never // Will show custom in picker
        }

        // Load display sleep time
        displaySleepMinutes = await Task.detached {
            SystemPrefs.getDisplaySleep() ?? 0
        }.value

        isLoading = false
    }

    private func openEnergySettings() {
        _ = Helpers.shell(launchPath: "/usr/bin/open", arguments: [
            "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"
        ])

        // Refresh display sleep time after a delay (user may change it)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            displaySleepMinutes = await Task.detached {
                SystemPrefs.getDisplaySleep() ?? 0
            }.value
        }
    }
}

// MARK: - Preview

struct ScreensaverSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        ScreensaverSettingsPanel()
            .frame(width: 500, height: 400)
    }
}

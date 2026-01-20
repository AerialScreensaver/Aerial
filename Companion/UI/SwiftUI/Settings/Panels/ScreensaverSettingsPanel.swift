//
//  ScreensaverSettingsPanel.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI
import IOKit.ps

// MARK: - Activation Time Options

@available(macOS 13.0, *)
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

@available(macOS 13.0, *)
struct ScreensaverSettingsPanel: View {
    @State private var selectedActivationTime: ActivationTime = .fiveMinutes
    @State private var customMinutes: Int? = nil
    @State private var displaySleepMinutes: Int = 0
    @State private var showWarning: Bool = false
    @State private var isLoading: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                Text("Screensaver")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)

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
                            .frame(width: 150)
                            .onChange(of: selectedActivationTime) { newValue in
                                customMinutes = nil
                                SystemPrefs.setSaverActivationTime(time: newValue.rawValue)
                                validateSettings()
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

                // Warning Box
                if showWarning {
                    GroupBox {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.orange)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Screensaver may not appear")
                                    .font(.system(size: 14, weight: .medium))

                                Text("Your display sleep time is less than or equal to the screensaver start time. The screen will turn off before the screensaver can start.")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(12)
                    } label: {
                        Label("Warning", systemImage: "exclamationmark.triangle")
                    }
                }

                Spacer()
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .task {
            await loadSettings()
        }
    }

    // MARK: - Private Methods

    private func loadSettings() async {
        isLoading = true

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

        validateSettings()
        isLoading = false
    }

    private func validateSettings() {
        let saverTime = selectedActivationTime.rawValue
        let displayTime = displaySleepMinutes

        // Show warning if display sleeps before or at same time as screensaver starts
        // Exception: if display sleep is 0 (never) and screensaver is > 0
        if displayTime == 0 && saverTime > 0 {
            showWarning = false
        } else if saverTime == 0 || saverTime >= displayTime {
            showWarning = true
        } else {
            showWarning = false
        }
    }

    private func openEnergySettings() {
        if #available(macOS 13, *) {
            _ = Helpers.shell(launchPath: "/usr/bin/open", arguments: [
                "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"
            ])
        } else if #available(macOS 11, *) {
            let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
            let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
            if sources.count > 0 {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Battery.prefpane"))
            } else {
                if #available(macOS 12, *) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/EnergySaverPref.prefpane"))
                } else {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/EnergySaver.prefpane"))
                }
            }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/EnergySaver.prefpane"))
        }

        // Refresh display sleep time after a delay (user may change it)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            displaySleepMinutes = await Task.detached {
                SystemPrefs.getDisplaySleep() ?? 0
            }.value
            validateSettings()
        }
    }
}

// MARK: - Preview

@available(macOS 13.0, *)
struct ScreensaverSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        ScreensaverSettingsPanel()
            .frame(width: 500, height: 400)
    }
}

//
//  AutoUpdatesPanel.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import Combine
import SwiftUI
import Sparkle

enum UpdateCheckFrequency: String, CaseIterable {
    case hourly = "Hourly"
    case daily = "Daily"
    case weekly = "Weekly"
    case never = "Never"

    var interval: TimeInterval {
        switch self {
        case .hourly: return 3600
        case .daily: return 86400
        case .weekly: return 604800
        case .never: return 0
        }
    }

    static func from(enabled: Bool, interval: TimeInterval) -> UpdateCheckFrequency {
        guard enabled else { return .never }
        if interval <= 3600 { return .hourly }
        if interval <= 86400 { return .daily }
        return .weekly
    }
}

enum AutoInstallMode: String, CaseIterable {
    case off = "Off"
    case onQuit = "On Quit"
    case immediately = "Immediately"
}

struct AutoUpdatesPanel: View {
    @State private var checkFrequency: UpdateCheckFrequency = .daily
    @State private var autoInstallMode: AutoInstallMode = .off
    @State private var canCheckForUpdates: Bool = false
    @State private var lastCheckDate: Date?

    private var sparkleController: SPUStandardUpdaterController? {
        AppDelegate.shared?.sparkleController
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                Text("Auto Updates")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)

                // Companion Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Check for updates")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $checkFrequency) {
                                ForEach(UpdateCheckFrequency.allCases, id: \.self) { freq in
                                    Text(freq.rawValue).tag(freq)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 280)
                        }
                        .onChange(of: checkFrequency) { newValue in
                            guard let updater = sparkleController?.updater else { return }
                            updater.automaticallyChecksForUpdates = newValue != .never
                            if newValue != .never {
                                updater.updateCheckInterval = newValue.interval
                            }
                        }

                        HStack {
                            Text("Auto install updates")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $autoInstallMode) {
                                ForEach(AutoInstallMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                        .disabled(checkFrequency == .never)
                        .onChange(of: autoInstallMode) { newValue in
                            sparkleController?.updater.automaticallyDownloadsUpdates = newValue != .off
                            UserDefaults.standard.set(newValue.rawValue, forKey: "autoInstallMode")
                        }

                        if let date = lastCheckDate {
                            Text("Last checked: \(date, style: .relative) ago")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Spacer()
                            Button("Check for Updates...") {
                                guard let updater = sparkleController?.updater else { return }
                                updater.checkForUpdates()
                            }
                            .disabled(!canCheckForUpdates)
                        }
                    }
                    .padding(12)
                } label: {
                    HStack(spacing: 4) {
                        Label("Via", systemImage: "sparkle").font(Font.title3.bold())
                        Link("Sparkle", destination: URL(string: "https://sparkle-project.org")!)
                            .font(Font.title3.bold())
                            .foregroundColor(.aerial)
                    }
                    .padding(4)
                }

                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            loadSettings()
        }
        .onReceive(canCheckPublisher) { newValue in
            canCheckForUpdates = newValue
        }
        .onReceive(lastCheckPublisher) { newValue in
            lastCheckDate = newValue
        }
    }

    // MARK: - Private Methods

    /// Reactive publisher for Sparkle's `canCheckForUpdates` KVO property.
    private var canCheckPublisher: AnyPublisher<Bool, Never> {
        guard let updater = sparkleController?.updater else {
            return Just(false).eraseToAnyPublisher()
        }
        return updater.publisher(for: \.canCheckForUpdates)
            .eraseToAnyPublisher()
    }

    /// Reactive publisher for Sparkle's `lastUpdateCheckDate` KVO property.
    private var lastCheckPublisher: AnyPublisher<Date?, Never> {
        guard let updater = sparkleController?.updater else {
            return Just(nil).eraseToAnyPublisher()
        }
        return updater.publisher(for: \.lastUpdateCheckDate)
            .eraseToAnyPublisher()
    }

    private func loadSettings() {
        let enabled = sparkleController?.updater.automaticallyChecksForUpdates ?? true
        let interval = sparkleController?.updater.updateCheckInterval ?? 86400
        checkFrequency = UpdateCheckFrequency.from(enabled: enabled, interval: interval)
        if let saved = UserDefaults.standard.string(forKey: "autoInstallMode"),
           let mode = AutoInstallMode(rawValue: saved) {
            autoInstallMode = mode
        } else {
            autoInstallMode = (sparkleController?.updater.automaticallyDownloadsUpdates ?? false) ? .onQuit : .off
        }
        canCheckForUpdates = sparkleController?.updater.canCheckForUpdates ?? false
        lastCheckDate = sparkleController?.updater.lastUpdateCheckDate
    }
}

// MARK: - Preview

struct AutoUpdatesPanel_Previews: PreviewProvider {
    static var previews: some View {
        AutoUpdatesPanel()
            .frame(width: 500, height: 600)
    }
}

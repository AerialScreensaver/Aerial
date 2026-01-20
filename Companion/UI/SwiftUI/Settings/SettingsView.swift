//
//  SettingsView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

// MARK: - Settings Panel Enum

@available(macOS 13.0, *)
enum SettingsPanel: String, CaseIterable, Identifiable {
    case myVideos = "My Videos"
    case screensaver = "Screensaver"
    case others = "Others"

    var id: String { rawValue }

    var title: String { rawValue }

    var icon: String {
        switch self {
        case .myVideos:
            return "film"
        case .screensaver:
            return "sparkles.tv"
        case .others:
            return "gearshape"
        }
    }

    var description: String {
        switch self {
        case .myVideos:
            return "Additional videos"
        case .screensaver:
            return "Activation timing"
        case .others:
            return "Updates & more"
        }
    }
}

// MARK: - Sidebar Navigation Item

@available(macOS 13.0, *)
struct SettingsNavItem: View {
    let panel: SettingsPanel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: panel.icon)
                .font(.system(size: 24))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(panel.title)
                    .font(.system(size: 14, weight: .medium))

                Text(panel.description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
    }
}

// MARK: - Main Settings View

@available(macOS 13.0, *)
struct SettingsView: View {
    @State private var selectedPanel: SettingsPanel = .myVideos

    var body: some View {
        NavigationSplitView {
            // Sidebar
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                ForEach(SettingsPanel.allCases) { panel in
                    SettingsNavItem(panel: panel, isSelected: selectedPanel == panel)
                        .onTapGesture {
                            selectedPanel = panel
                        }
                        .padding(.horizontal, 8)
                }

                Spacer()
            }
            .frame(minWidth: 200, maxWidth: 220)
            .background(Color(NSColor.windowBackgroundColor))
        } detail: {
            // Content panel
            Group {
                switch selectedPanel {
                case .myVideos:
                    MyVideosSettingsPanel()
                case .screensaver:
                    ScreensaverSettingsPanel()
                case .others:
                    OtherSettingsPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 650, minHeight: 450)
    }
}

// MARK: - Preview

@available(macOS 13.0, *)
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .frame(width: 700, height: 500)
    }
}

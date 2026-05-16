//
//  SettingsView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

// MARK: - Settings Panel Enum

enum SettingsPanel: String, CaseIterable, Identifiable {
    case screensaver = "Screensaver"
    case desktop = "Wallpaper"
    case displays = "Displays"
    case cache = "Cache"
    case time = "Time"
    case overlays = "Overlays"
    case accessibility = "Accessibility"
    case advanced = "Advanced"
    case autoUpdates = "Auto Updates"
    case about = "About"

    var id: String { rawValue }

    var title: String { rawValue }

    var icon: String {
        switch self {
        case .screensaver:
            return "sparkles.tv"
        case .time:
            return "clock"
        case .overlays:
            return "text.below.photo"
        case .cache:
            return "internaldrive"
        case .displays:
            return "display.2"
        case .desktop:
            return "desktopcomputer"
        case .accessibility:
            return "accessibility"
        case .autoUpdates:
            return "gearshape"
        case .advanced:
            return "wrench.and.screwdriver"
        case .about:
            return "info.circle"
        }
    }

    var description: String {
        switch self {
        case .screensaver:
            return "Activation timing"
        case .time:
            return "Day/Night adaptation"
        case .overlays:
            return "Clock, weather & more"
        case .cache:
            return "Network/Disk use"
        case .displays:
            return "Screen layout"
        case .desktop:
            return "Playback & continuity"
        case .accessibility:
            return "Shortcuts & visuals"
        case .autoUpdates:
            return "Via Sparkle"
        case .advanced:
            return "Settings & tweaks"
        case .about:
            return "Help & support"
        }
    }
}

// MARK: - Sidebar Navigation Item

struct SettingsNavItem: View {
    let panel: SettingsPanel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: panel.icon)
                .font(.system(size: 24))
                .foregroundColor(isSelected ? .aerial : .secondary)
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
        .background(isSelected ? Color.aerial.opacity(0.1) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
    }
}

// MARK: - Main Settings View

struct SettingsView: View {
    @State private var selectedPanel: SettingsPanel = .screensaver
    @ObservedObject private var screensaverManager = AerialPluginManager.shared
    @Environment(\.openWindow) private var openWindow

    /// Aggregate of the three screensaver-health checks shown on
    /// `ScreensaverSettingsPanel`. Drives the toolbar status icon.
    private enum HealthStatus { case ok, warning }
    private var screensaverHealth: HealthStatus {
        let installedOK: Bool
        switch screensaverManager.appLocation {
        case .systemApplications: installedOK = true
        default: installedOK = false
        }
        let registered = screensaverManager.isPluginRegistered
        let enabled    = screensaverManager.isScreensaverEnabled
        return (installedOK && registered && enabled) ? .ok : .warning
    }

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
            // The sidebar-toggle item is added to the sidebar column's
            // toolbar slot — `.toolbar(removing:)` only takes effect
            // when applied to that column, not the NavigationSplitView
            // root.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            // Content panel
            Group {
                switch selectedPanel {
                case .screensaver:
                    ScreensaverSettingsPanel()
                case .time:
                    TimeSettingsPanel()
                case .overlays:
                    OverlaysSettingsPanel()
                case .cache:
                    CacheSettingsPanel()
                case .displays:
                    DisplaysSettingsPanel()
                case .desktop:
                    DesktopSettingsPanel()
                case .accessibility:
                    AccessibilityPanel()
                case .autoUpdates:
                    AutoUpdatesPanel()
                case .advanced:
                    AdvancedSettingsPanel()
                case .about:
                    AboutSettingsPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Real `ToolbarItem` is required to engage SwiftUI's
            // unified-window-chrome path on the detail column —
            // empty / 1×1 placeholders aren't enough; AppKit falls
            // back to the legacy layout (separate titlebar, traffic
            // lights above the sidebar instead of overlaid on it).
            // We use the slot for a screensaver-health status icon
            // so it's actually useful: green if everything's set,
            // orange if any of the three Screensaver checks needs
            // attention. Click → jumps to the Screensaver panel.
            //
            // The leading `.principal` Spacer pushes the
            // `.primaryAction` item to the trailing (right) edge —
            // without it, a lone `.primaryAction` falls back to the
            // leading slot on macOS once the title is removed.
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Spacer()
                }
                // Mirrors the Settings button in the Video Library
                // toolbar — quick jump between the two windows.
                // Declared before the health icon so it lands to its
                // left within the trailing primaryAction group.
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        openWindow(id: "videoBrowser")
                    }) {
                        Label("Video Library", systemImage: "film.stack")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Open Video Library")
                    .accessibilityLabel("Open Video Library")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        selectedPanel = .screensaver
                    } label: {
                        Image(systemName: screensaverHealth == .ok
                              ? "checkmark.circle.fill"
                              : "exclamationmark.triangle.fill")
                            .foregroundColor(screensaverHealth == .ok ? .green : .orange)
                    }
                    .help(screensaverHealth == .ok
                          ? "Screensaver: all set"
                          : "Screensaver needs attention")
                    .accessibilityLabel(
                        screensaverHealth == .ok
                            ? "Screensaver health: all set"
                            : "Screensaver health: needs attention. Click to fix."
                    )
                }
            }
        }
        .toolbar(removing: .title)
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 950, minHeight: 700)
        .tint(.aerial)
    }
}

// MARK: - Preview

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .frame(width: 950, height: 700)
    }
}

//
//  AccessibilityPanel.swift
//  Aerial Companion
//
//  Settings panel that hosts accessibility-adjacent features:
//  global system-wide shortcuts (toggle pause / next / previous
//  video) and the two existing visual toggles relocated from the
//  Advanced panel (solid popover background, invert video colors).
//

import SwiftUI
import KeyboardShortcuts

struct AccessibilityPanel: View {
    @State private var globalShortcutsEnabled: Bool = false
    @State private var popoverSolidBackground: Bool = false
    @State private var invertColors: Bool = false
    @State private var reduceMotionActive: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Accessibility")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)

                if reduceMotionActive {
                    reduceMotionSection
                }
                globalShortcutsSection
                displaySection

                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear { loadSettings() }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
            )
        ) { _ in
            reduceMotionActive = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    // MARK: - Reduce Motion Section (system-driven)

    private var reduceMotionSection: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .padding(.top, 1)
                Text("macOS Reduce Motion is enabled. Aerial honors this setting: video fades are disabled, and other transitions (speed changes, occlusion handoffs) are reduced.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
        } label: {
            Label("Reduce Motion", systemImage: "figure.walk.motion")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    // MARK: - Global Shortcuts Section

    private var globalShortcutsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Enable global shortcuts", isOn: $globalShortcutsEnabled)
                    .font(.system(size: 14))
                    .onChange(of: globalShortcutsEnabled) { newValue in
                        Preferences.globalShortcutsEnabled = newValue
                        GlobalShortcutsManager.refresh()
                    }

                Text("Control playback even when Aerial isn't focused. You can set any key combination.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if globalShortcutsEnabled {
                    Divider()

                    Form {
                        KeyboardShortcuts.Recorder("Toggle pause / resume:", name: .togglePause)
                        KeyboardShortcuts.Recorder("Previous video:", name: .previousVideo)
                        KeyboardShortcuts.Recorder("Next video:", name: .nextVideo)
                        KeyboardShortcuts.Recorder("Launch screensaver:", name: .launchScreensaver)
                        KeyboardShortcuts.Recorder("Toggle fullscreen:", name: .toggleFullscreen)
                        #if DEBUG
                        KeyboardShortcuts.Recorder("Cycle simulated battery (DEBUG):", name: .cycleBatterySimulation)
                        #endif
                    }

                    #if DEBUG
                    Text("Debug build only — cycles Battery.simulationState through off → on battery → on battery low. Lets you test pause-on-battery on Macs without a battery. Stripped from Release builds.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    #endif
                }
            }
            .padding(12)
        } label: {
            Label("Global Shortcuts", systemImage: "keyboard")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    // MARK: - Display Section (relocated from Advanced)

    private var displaySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Use solid popover background", isOn: $popoverSolidBackground)
                    .font(.system(size: 14))
                    .onChange(of: popoverSolidBackground) { newValue in
                        Preferences.popoverSolidBackground = newValue
                        NotificationCenter.default.post(
                            name: .popoverSolidBackgroundDidChange,
                            object: newValue
                        )
                    }

                Text("Replaces the translucent popover background with a solid color. Useful when transparency makes labels hard to read.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle("Invert video colors", isOn: $invertColors)
                    .font(.system(size: 14))
                    .onChange(of: invertColors) { newValue in
                        Preferences.invertColors = newValue
                    }

                Text("Inverts the colors of video playback for improved visibility. Takes effect on the next video.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        } label: {
            Label("Display", systemImage: "eye")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    // MARK: - Load Settings

    private func loadSettings() {
        globalShortcutsEnabled = Preferences.globalShortcutsEnabled
        popoverSolidBackground = Preferences.popoverSolidBackground
        invertColors = Preferences.invertColors
    }
}

struct AccessibilityPanel_Previews: PreviewProvider {
    static var previews: some View {
        AccessibilityPanel()
            .frame(width: 600, height: 500)
    }
}

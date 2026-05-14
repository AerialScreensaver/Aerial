//
//  OverlaysSettingsPanel.swift
//  Aerial
//
//  Settings panel for overlay configuration toggles and editor launch.
//

import SwiftUI

struct OverlaysSettingsPanel: View {
    @State private var perScreen: Bool = OverlayConfigManager.shared.config.perScreen
    @State private var separateDesktop: Bool = OverlayConfigManager.shared.config.separateDesktopConfig
    @State private var hideOverlaysDuringLogin: Bool = OverlayConfigManager.shared.config.hideOverlaysDuringLogin
    @State private var showVersionAtStartup: Bool = OverlayConfigManager.shared.config.showVersionAtStartup
    @State private var rotationMode: OverlayRotationMode = OverlayConfigManager.shared.config.rotationMode

    /// Retained controller so the editor window stays alive
    private static var editorController: OverlayEditorWindowController?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Overlays")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)

                Text("Configure text and information overlays shown on top of videos.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Use separate overlay layout per screen", isOn: $perScreen)
                        .onChange(of: perScreen) { _, newValue in
                            var config = OverlayConfigManager.shared.config
                            config.perScreen = newValue
                            OverlayConfigManager.shared.setConfig(config)
                        }

                    Text("When enabled, each screen can have a different set of overlays.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Toggle("Show overlays in Wallpaper/Fullscreen mode", isOn: $separateDesktop)
                        .onChange(of: separateDesktop) { _, newValue in
                            var config = OverlayConfigManager.shared.config
                            config.separateDesktopConfig = newValue
                            OverlayConfigManager.shared.setConfig(config)
                        }

                    Text("When enabled, wallpaper/fullscreen mode gets a separate overlay layout from the screensaver.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Toggle("Hide overlays while logging in from screensaver", isOn: $hideOverlaysDuringLogin)
                        .onChange(of: hideOverlaysDuringLogin) { _, newValue in
                            var config = OverlayConfigManager.shared.config
                            config.hideOverlaysDuringLogin = newValue
                            OverlayConfigManager.shared.setConfig(config)
                        }

                    Text("Hides overlay information when macOS shows the password prompt over the screensaver.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Toggle("Show version at startup", isOn: $showVersionAtStartup)
                        .onChange(of: showVersionAtStartup) { _, newValue in
                            var config = OverlayConfigManager.shared.config
                            config.showVersionAtStartup = newValue
                            OverlayConfigManager.shared.setConfig(config)
                        }

                    Text("Briefly shows the Aerial version number at the bottom of the screen when the screensaver starts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Picker("Rotate overlays", selection: $rotationMode) {
                        ForEach(OverlayRotationMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .onChange(of: rotationMode) { _, newValue in
                        var config = OverlayConfigManager.shared.config
                        config.rotationMode = newValue
                        OverlayConfigManager.shared.setConfig(config)
                    }

                    Text("Use this option if you want to reduce risk of burn-in on  your monitors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

                Button("Open Overlay Editor") {
                    if let existing = Self.editorController, existing.window?.isVisible == true {
                        existing.showEditorWindow()
                    } else {
                        // Detect the screen the settings window is on
                        let settingsScreen = NSApp.keyWindow?.screen ?? NSScreen.main
                        let screenUUID: String? = perScreen ? settingsScreen?.screenUuid : nil

                        let controller = OverlayEditorWindowController(
                            screenUUID: screenUUID,
                            onScreen: settingsScreen
                        )
                        Self.editorController = controller
                        controller.showEditorWindow()
                    }
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

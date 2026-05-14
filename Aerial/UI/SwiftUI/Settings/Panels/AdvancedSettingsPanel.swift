//
//  AdvancedSettingsPanel.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 13/02/2026.
//

import SwiftUI

struct AdvancedSettingsPanel: View {
    // Video
    @State private var videoFormat: Int = PrefsVideos.videoFormat.rawValue
    @State private var originalFormat: Int = PrefsVideos.videoFormat.rawValue
    @State private var fadeMode: Int = PrefsVideos.fadeMode.rawValue

    // Audio
    @State private var muteSound: Bool = PrefsAdvanced.muteSound
    @State private var muteGlobalSound: Bool = PrefsAdvanced.muteGlobalSound

    // Playback
    @State private var onBatteryMode: Int = PrefsVideos.onBatteryMode.rawValue
    @State private var favorOrientation: Bool = PrefsAdvanced.favorOrientation
    // Language
    @State private var languagePosition: Int = PoiStringProvider.sharedInstance.getLanguagePosition()

    // (Popover-bg / invert-colors moved to Settings → Accessibility.)

    // Alerts
    @State private var showFormatAlert: Bool = false
    @State private var pendingFormat: Int = 0
    @State private var showResetAlert: Bool = false
    @State private var showResetSuccessAlert: Bool = false

    private let videoFormatLabels = [
        "1080p H264",
        "1080p HEVC",
        "1080p HDR",
        "4K HEVC",
        "4K HDR",
        "4K SDR 240fps",
    ]

    private let fadeModeLabels = [
        "Disabled",
        "0.5 seconds",
        "1 second",
        "2 seconds",
    ]

    private let onBatteryLabels = [
        "Keep enabled",
        "Always disabled",
        "Disable on low battery",
    ]

    private let languages: [(label: String, code: String)] = [
        ("Preferred language", ""),
        ("Arabic", "ar"),
        ("Chinese Simplified", "zh_CN"),
        ("Chinese Traditional", "zh_TW"),
        ("Dutch", "nl"),
        ("English", "en"),
        ("French", "fr"),
        ("German", "de"),
        ("Hebrew", "he"),
        ("Hungarian", "hu"),
        ("Italian", "it"),
        ("Japanese", "ja"),
        ("Korean", "ko"),
        ("Polish", "pl"),
        ("Portuguese", "pt"),
        ("Portuguese (Brazil)", "pt_BR"),
        ("Russian", "ru"),
        ("Spanish", "es"),
        ("Swedish", "sv"),
        ("Tagalog", "tl"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Advanced")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)

                // MARK: - Video
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Video format")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $videoFormat) {
                                ForEach(0..<videoFormatLabels.count, id: \.self) { index in
                                    Text(videoFormatLabels[index]).tag(index)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 220, alignment: .trailing)
                            .onChange(of: videoFormat) { newValue in
                                if newValue != originalFormat {
                                    pendingFormat = newValue
                                    showFormatAlert = true
                                } else {
                                    PrefsVideos.videoFormat = VideoFormat(rawValue: newValue)!
                                }
                            }
                        }

                        HStack {
                            Text("Video fades")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $fadeMode) {
                                ForEach(0..<fadeModeLabels.count, id: \.self) { index in
                                    Text(fadeModeLabels[index]).tag(index)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 220, alignment: .trailing)
                            .onChange(of: fadeMode) { newValue in
                                PrefsVideos.fadeMode = FadeMode(rawValue: newValue)!
                            }
                        }
                    }
                    .padding(12)
                } label: {
                    Label("Video", systemImage: "film").font(Font.title3.bold()).padding(4)
                }

                // MARK: - Audio
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Mute sound from videos", isOn: $muteSound)
                            .font(.system(size: 14))
                            .onChange(of: muteSound) { newValue in
                                PrefsAdvanced.muteSound = newValue
                            }

                        Toggle("Mute all macOS sounds", isOn: $muteGlobalSound)
                            .font(.system(size: 14))
                            .onChange(of: muteGlobalSound) { newValue in
                                PrefsAdvanced.muteGlobalSound = newValue
                            }
                    }
                    .padding(12)
                } label: {
                    Label("Audio", systemImage: "speaker.wave.2").font(Font.title3.bold()).padding(4)
                }

                // MARK: - Playback
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("On battery")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $onBatteryMode) {
                                ForEach(0..<onBatteryLabels.count, id: \.self) { index in
                                    Text(onBatteryLabels[index]).tag(index)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 220, alignment: .trailing)
                            .onChange(of: onBatteryMode) { newValue in
                                PrefsVideos.onBatteryMode = OnBatteryMode(rawValue: newValue)!
                            }
                        }

                        Toggle("Favor orientation", isOn: $favorOrientation)
                            .font(.system(size: 14))
                            .onChange(of: favorOrientation) { newValue in
                                PrefsAdvanced.favorOrientation = newValue
                            }

                    }
                    .padding(12)
                } label: {
                    Label("Playback", systemImage: "play.circle").font(Font.title3.bold()).padding(4)
                }

                // MARK: - Language
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Language override")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $languagePosition) {
                                ForEach(0..<languages.count, id: \.self) { index in
                                    Text(languages[index].label).tag(index)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 220, alignment: .trailing)
                            .onChange(of: languagePosition) { newValue in
                                let poisp = PoiStringProvider.sharedInstance
                                PrefsAdvanced.ciOverrideLanguage = poisp.getLanguageStringFromPosition(pos: newValue)
                            }
                        }

                        Text(Aerial.helper.getPreferredLanguage())
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                } label: {
                    Label("Language", systemImage: "globe").font(Font.title3.bold()).padding(4)
                }

                // (Accessibility section moved to its own
                //  Settings → Accessibility panel.)

                // MARK: - Troubleshooting
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            Button("Show Log in Finder") {
                                showLogInFinder()
                            }

                            Button("Reset All Settings") {
                                showResetAlert = true
                            }
                        }
                    }
                    .padding(12)
                } label: {
                    Label("Troubleshooting", systemImage: "ant").font(Font.title3.bold()).padding(4)
                }

                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .alert("Changing format will delete all videos", isPresented: $showFormatAlert) {
            Button("Change Format and Delete Videos", role: .destructive) {
                PrefsVideos.videoFormat = VideoFormat(rawValue: pendingFormat)!
                originalFormat = pendingFormat
                Cache.clearCache()
                Cache.clearNonCacheableSources()
            }
            Button("Cancel", role: .cancel) {
                videoFormat = originalFormat
            }
        } message: {
            Text("Changing format will delete your downloaded videos. They will be re-downloaded based on your preferences.\n\nYou can also manually redownload videos in Custom Sources.")
        }
        .alert("Reset all settings?", isPresented: $showResetAlert) {
            Button("Reset my settings", role: .destructive) {
                resetAllSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will reset all your screensaver settings to their defaults.\n\nAre you sure you want to reset your settings?")
        }
        .alert("Settings reset to defaults", isPresented: $showResetSuccessAlert) {
            Button("OK") {}
        } message: {
            Text("Your screensaver settings were reset to defaults.")
        }
    }

    // MARK: - Private Methods

    private func showLogInFinder() {
        let logfile = Cache.supportPath.appending("/AerialLog.txt")
        if FileManager.default.fileExists(atPath: logfile) {
            NSWorkspace.shared.selectFile(logfile, inFileViewerRootedAtPath: Cache.supportPath)
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Cache.supportPath)
        }
    }

    private func resetAllSettings() {
        let fileURL = ScreensaverSettings.fileURL
        try? FileManager.default.removeItem(at: fileURL)
        showResetSuccessAlert = true
    }
}

// MARK: - Preview

struct AdvancedSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        AdvancedSettingsPanel()
            .frame(width: 500, height: 800)
    }
}

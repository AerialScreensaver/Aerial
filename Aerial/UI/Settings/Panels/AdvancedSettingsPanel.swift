//
//  AdvancedSettingsPanel.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 13/02/2026.
//

import SwiftUI

struct AdvancedSettingsPanel: View {
    // Launch
    @State private var launchMode: LaunchMode = Preferences.launchMode
    @State private var presentation: AppPresentation = Preferences.appPresentation

    // Video
    @State private var videoFormat: Int = PrefsVideos.videoFormat.rawValue
    @State private var originalFormat: Int = PrefsVideos.videoFormat.rawValue
    @State private var transitionStyle: WallpaperTransitionStyle = WallpaperControl.shared.currentTransitionStyle
    @State private var transitionDuration: Double = WallpaperControl.shared.currentTransitionDuration

    // Audio
    @State private var audioEnabled: Bool = WallpaperControl.shared.currentAudioEnabled
    @State private var audioVolume: Double = WallpaperControl.shared.currentAudioVolume

    // Playback
    @State private var onBatteryMode: Int = PrefsVideos.onBatteryMode.rawValue
    @State private var favorOrientation: Bool = PrefsAdvanced.favorOrientation

    // Diagnostics
    @State private var showDiagnosticBadges: Bool = PrefsAdvanced.showDiagnosticBadges
    @State private var overlapWorkaround: OverlapWorkaround = PrefsAdvanced.overlapWorkaround
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

    private let transitionDurations: [(label: String, seconds: Double)] = [
        ("1 second", 1.0),
        ("2 seconds", 2.0),
        ("4 seconds", 4.0),
        ("6 seconds", 6.0),
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

                // MARK: - Launch
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Show Aerial in")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $presentation) {
                                Text("Menu bar").tag(AppPresentation.menuBar)
                                Text("Dock").tag(AppPresentation.dock)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 220, alignment: .trailing)
                            .onChange(of: presentation) { newValue in
                                AppPresentationController.shared.apply(newValue, reason: "settings")
                            }
                        }

                        Text("In the menu bar, Aerial is a compact popover next to the clock. In the Dock, Aerial is a regular app: the Video Library becomes its main window and the Playback menu gains keyboard shortcuts. Switching takes effect immediately.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Divider()

                        HStack {
                            Text("Launch Aerial")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $launchMode) {
                                Text("Manually").tag(LaunchMode.manual)
                                Text("At login").tag(LaunchMode.startup)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 220, alignment: .trailing)
                            .onChange(of: launchMode) { newValue in
                                Preferences.launchMode = newValue
                                LaunchAgent.update()
                            }
                        }

                        Text("Choose whether Aerial starts automatically when you log in. Aerial runs in the background to manage downloads, overlays, and the live wallpaper.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                } label: {
                    Label("Launch", systemImage: "power").font(Font.title3.bold()).padding(4)
                }

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
                            Text("Transition between videos")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $transitionStyle) {
                                ForEach(WallpaperTransitionStyle.allCases, id: \.self) { style in
                                    Text(style.displayName).tag(style)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 220, alignment: .trailing)
                            .onChange(of: transitionStyle) { newValue in
                                WallpaperControl.shared.setTransition(style: newValue, duration: transitionDuration)
                            }
                        }

                        if transitionStyle != WallpaperTransitionStyle.none {
                            HStack {
                                Text("Transition duration")
                                    .font(.system(size: 14))
                                Spacer()
                                Picker("", selection: $transitionDuration) {
                                    ForEach(transitionDurations, id: \.seconds) { option in
                                        Text(option.label).tag(option.seconds)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 220, alignment: .trailing)
                                .onChange(of: transitionDuration) { newValue in
                                    WallpaperControl.shared.setTransition(style: transitionStyle, duration: newValue)
                                }
                            }
                        }

                        Text("Played at every video change, in both wallpaper and screensaver mode. Manual skips use a quicker fade.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                } label: {
                    Label("Video", systemImage: "film").font(Font.title3.bold()).padding(4)
                }

                // MARK: - Audio
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Play audio from videos", isOn: $audioEnabled)
                            .font(.system(size: 14))
                            .onChange(of: audioEnabled) { newValue in
                                WallpaperControl.shared.setAudioEnabled(newValue)
                            }

                        if audioEnabled {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Volume")
                                        .font(.system(size: 14))
                                    Spacer()
                                    Text("\(Int(audioVolume * 100))%")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                Slider(value: $audioVolume, in: 0...1, step: 0.05)
                                    .onChange(of: audioVolume) { newValue in
                                        WallpaperControl.shared.setAudioVolume(newValue)
                                    }
                            }
                            .padding(.leading, 20)
                        }

                        Text("Plays the video's own soundtrack when playback runs at full speed — in the screensaver, or on the wallpaper with speed set to 100%. With multiple displays, audio comes from the main display only. The lock screen stays silent.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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

                // MARK: - Diagnostics
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Show diagnostic badges on wallpaper", isOn: $showDiagnosticBadges)
                            .font(.system(size: 14))
                            .onChange(of: showDiagnosticBadges) { newValue in
                                PrefsAdvanced.showDiagnosticBadges = newValue
                                // Push it to the running extension so badges
                                // appear/disappear without a restart.
                                WallpaperControl.shared.displaysConfigDidChange()
                            }

                        HStack {
                            Text("Overlap workaround")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $overlapWorkaround) {
                                Text("Default").tag(OverlapWorkaround.variantD)
                                Text("HDR compatible").tag(OverlapWorkaround.variantA)
                            }
                            .pickerStyle(.radioGroup)
                            .horizontalRadioGroupLayout()
                            .onChange(of: overlapWorkaround) { newValue in
                                PrefsAdvanced.overlapWorkaround = newValue
                                WallpaperControl.shared.displaysConfigDidChange()
                            }
                        }
                        .padding(.leading, 20)
                        .disabled(!showDiagnosticBadges)

                        Text("Overlays each wallpaper window with corner markers, an identity chip and a running counter. Only useful when troubleshooting display issues with us — leave it off otherwise.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope").font(Font.title3.bold()).padding(4)
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
                            Button("Export Diagnostics…") {
                                DiagnosticsExporter.exportInteractively()
                            }

                            Button("Show Log in Finder") {
                                showLogInFinder()
                            }

                            Button("Reset All Settings") {
                                showResetAlert = true
                            }
                        }

                        Text("Export Diagnostics saves a zip of Aerial's logs and settings to attach to a bug report — review it before sharing.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
            Text(formatAlertMessage)
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

    private var formatAlertMessage: String {
        var msg = "Changing format will delete your downloaded videos. They will be re-downloaded based on your preferences.\n\nYou can also manually redownload videos in Custom Sources."
        if VideoFormat(rawValue: pendingFormat)?.isHDR == true {
            msg += "\n\nHDR formats may have rendering issues on macOS Tahoe. You may need to restart your Mac for HDR videos to display correctly."
        }
        return msg
    }

    private func showLogInFinder() {
        // The current logs live in Logs/ (app.txt + wallpaper.txt) —
        // the old AerialLog.txt single-file path predates the split.
        let logfile = AerialPaths.logsPath().appending("/app.txt")
        if FileManager.default.fileExists(atPath: logfile) {
            NSWorkspace.shared.selectFile(logfile, inFileViewerRootedAtPath: AerialPaths.logsPath())
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

private extension WallpaperTransitionStyle {
    var displayName: String {
        switch self {
        case .none: return "None (hard cut)"
        case .crossfade: return "Crossfade"
        case .dipToBlack: return "Dip to black"
        case .zoomFade: return "Zoom dissolve"
        }
    }
}

// MARK: - Preview

struct AdvancedSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        AdvancedSettingsPanel()
            .frame(width: 500, height: 800)
    }
}

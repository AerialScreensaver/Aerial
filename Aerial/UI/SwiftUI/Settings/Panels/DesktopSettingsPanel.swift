//
//  DesktopSettingsPanel.swift
//  Aerial Companion
//

import SwiftUI
import Combine

struct ScreenCoverageInfo: Identifiable {
    let id: Int        // index in NSScreen.screens
    let name: String
    var coverage: Double
}

struct DesktopSettingsPanel: View {
    @State private var autoPauseEnabled: Bool = true
    @State private var autoPauseThreshold: Double = 0.6
    @State private var screenCoverages: [ScreenCoverageInfo] = []
    @State private var coverageTimer: AnyCancellable?
    @State private var launchMode: LaunchMode = .manual
    @State private var restartAtLaunch: Bool = false
    @State private var replaceWallpaper: Bool = false
    /// Snapshot of `PrefsVideos.videoFormat` at panel-appear time. Drives
    /// the HDR-incompatibility warning in the Wallpaper Continuity section.
    /// Format picker lives in a different panel, so .onAppear refresh is
    /// enough to keep this in sync.
    @State private var videoFormat: VideoFormat = .v4KHEVC
    /// Snapshot of `PrefsDisplays.viewingMode` at panel-appear time.
    /// Used to switch the auto-pause copy and per-screen badges between
    /// independent ("would pause") and shared ("would pause all"
    /// + "paused (other screen)") wording.
    @State private var viewingMode: ViewingMode = .independent
    /// Sub-option under the master Continuity toggle. ON (default)
    /// asks the cleaner to keep the wallpaper-agent cache pruned;
    /// OFF disables it entirely even while continuity is on. Only
    /// surfaced on macOS 26+ where the underlying cache bug exists.
    @State private var cleanWallpaperCache: Bool = true
    /// Mirrors `WallpaperCacheCleaner.shared.hasBookmark`. Drives the
    /// "Grant access" affordance shown when the sub-toggle is on but
    /// the user hasn't yet approved the NSOpenPanel.
    @State private var hasCacheAccess: Bool = false

    /// Pause desktop wallpaper / fullscreen-window playback on battery.
    @State private var pauseOnBattery: Bool = false
    /// `"anyBattery"` or `"lowBattery"`.
    @State private var pauseOnBatteryMode: String = "anyBattery"
    /// Snapshot of `Battery.hasBattery()` at load time. Drives the
    /// "no battery detected" warning when the user enables the toggle
    /// on a Mac that doesn't have a battery (Mac mini, Studio, etc.).
    @State private var hasBatteryHardware: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Wallpaper")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)

                autoPauseSection

                pauseOnBatterySection

                restartAtLaunchSection

                replaceWallpaperSection

                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            loadSettings()
            startCoveragePolling()
        }
        .onDisappear {
            coverageTimer?.cancel()
            coverageTimer = nil
        }
    }

    // MARK: - Auto-Pause Section

    private var autoPauseSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Pause when wallpaper is hidden", isOn: $autoPauseEnabled)
                    .font(.system(size: 14))
                    .onChange(of: autoPauseEnabled) { newValue in
                        Preferences.desktopAutoPause = newValue
                    }

                Text("Automatically pauses video playback when other windows cover most of the screen, saving GPU and CPU resources.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                if viewingMode != .independent {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                        Text("In \(viewingMode.displayName) mode all screens share one playlist, so auto-pause acts on every screen together — any covered screen pauses the whole group.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                if autoPauseEnabled {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Coverage threshold")
                                .font(.system(size: 14))
                            Spacer()
                            Text("\(Int(autoPauseThreshold * 100))%")
                                .font(.system(size: 14, weight: .medium))
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }

                        Slider(value: $autoPauseThreshold, in: 0.3...0.9, step: 0.05)
                            .onChange(of: autoPauseThreshold) { newValue in
                                Preferences.desktopAutoPauseThreshold = newValue
                            }

                        Text("Pause playback when this percentage of the screen is covered by windows. Lower values pause sooner.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Live coverage")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)

                            // In shared viewing modes, every screen pauses
                            // together as soon as any one passes the
                            // threshold. The "paused (other screen)" badge
                            // tells the user why a visible screen would
                            // still be paused.
                            let isShared = viewingMode != .independent
                            let anyWouldPause = screenCoverages.contains { $0.coverage >= autoPauseThreshold }

                            ForEach(screenCoverages) { screen in
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(screen.coverage >= autoPauseThreshold ? Color.orange : Color.green)
                                        .frame(width: 8, height: 8)
                                    Text(screen.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: 160, alignment: .leading)
                                    Text("\(Int(screen.coverage * 100))%")
                                        .font(.system(size: 12))
                                        .monospacedDigit()
                                        .foregroundColor(.secondary)
                                        .frame(width: 32, alignment: .trailing)
                                    if screen.coverage >= autoPauseThreshold {
                                        Text(isShared ? "would pause all" : "would pause")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.orange)
                                    } else if isShared && anyWouldPause {
                                        Text("paused (other screen)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.orange.opacity(0.7))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
        } label: {
            Label("Auto-Pause", systemImage: "pause.circle")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    // MARK: - Pause on Battery Section

    private var pauseOnBatterySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Pause on battery", isOn: $pauseOnBattery)
                    .font(.system(size: 14))
                    .onChange(of: pauseOnBattery) { newValue in
                        Preferences.desktopPauseOnBattery = newValue
                        PlaybackManager.shared.evaluateBatteryState()
                    }

                Text("Automatically pauses wallpaper and fullscreen playback when this Mac is running on battery, saving energy. Click the popover's play button to override for the current session.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                if pauseOnBattery {
                    Divider()

                    Picker("When to pause", selection: $pauseOnBatteryMode) {
                        Text("On any battery power").tag("anyBattery")
                        Text("Only when battery is low").tag("lowBattery")
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 14))
                    .onChange(of: pauseOnBatteryMode) { newValue in
                        Preferences.desktopPauseOnBatteryMode = newValue
                        PlaybackManager.shared.evaluateBatteryState()
                    }

                    Text("\"On any battery power\" pauses as soon as the charger is unplugged. \"Only when battery is low\" waits until the remaining capacity drops below 20%.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    if !hasBatteryHardware {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No battery detected on this Mac")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("The setting is only available for syncing your preferences to other Macs.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.orange.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
                        )
                    }
                }
            }
            .padding(12)
        } label: {
            Label("Pause on Battery", systemImage: "battery.25percent")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    // MARK: - Restart at Launch Section

    private var restartAtLaunchSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
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

                Divider()

                Toggle("Restart wallpaper at launch", isOn: $restartAtLaunch)
                    .font(.system(size: 14))
                    .onChange(of: restartAtLaunch) { newValue in
                        Preferences.restartBackground = newValue
                    }
                Text("When enabled, the wallpaper will automatically restart when Aerial launches.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(12)
        } label: {
            Label("Startup", systemImage: "arrow.clockwise").font(Font.title3.bold()).padding(4)
        }
    }

    // MARK: - Replace Wallpaper Section

    /// HDR formats can't be tone-mapped correctly when captured as a still
    /// frame for the wallpaper — Dolby Vision metadata only applies on
    /// Apple's privileged decoder path used by AVPlayerLayer, not on
    /// AVAssetReader / AVAssetImageGenerator extractions.
    private var formatIsHDR: Bool {
        videoFormat == .v1080pHDR || videoFormat == .v4KHDR
    }

    private var replaceWallpaperSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Replace wallpaper", isOn: $replaceWallpaper)
                    .font(.system(size: 14))
                    .onChange(of: replaceWallpaper) { newValue in
                        Preferences.replaceWallpaper = newValue
                        // Re-evaluate the cache cleaner — turning
                        // continuity on with the sub-toggle default
                        // (true) and no bookmark fires the NSOpenPanel.
                        WallpaperCacheCleaner.shared.reevaluate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            hasCacheAccess = WallpaperCacheCleaner.shared.hasBookmark
                        }
                    }

                Text("Updates your macOS wallpaper to match the current video, to improve continuity when you wake up your mac from sleep and with Mission Control/Exposé. \n\nThis will not behave perfectly if you use macOS Spaces, but will try to do a best effort!")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                if formatIsHDR {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("Wallpaper continuity does not produce correct colors with HDR video formats. The captured wallpaper will look off or plainly wrong. Switch to a non-HDR video format for this feature to work properly. 4K 240FPS is recommended.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                if #available(macOS 26.0, *), replaceWallpaper {
                    Divider()
                    cacheCleanerSubsection
                }
            }
            .padding(12)
        } label: {
            Label("Continuity", systemImage: "rectangle.on.rectangle")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    /// Nested under the master Continuity toggle on macOS 26+. The
    /// sub-toggle (default ON) controls whether Aerial prunes
    /// macOS's wallpaper-agent cache — which on this version of the
    /// OS is never cleaned automatically and balloons to many GB
    /// when continuity is on. If the sub-toggle is ON but we don't
    /// hold folder access yet, a "Grant Access" affordance appears.
    @ViewBuilder
    private var cacheCleanerSubsection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Automatically clean wallpaper cache", isOn: $cleanWallpaperCache)
                .font(.system(size: 13))
                .onChange(of: cleanWallpaperCache) { newValue in
                    Preferences.cleanWallpaperCache = newValue
                    WallpaperCacheCleaner.shared.reevaluate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        hasCacheAccess = WallpaperCacheCleaner.shared.hasBookmark
                    }
                }

            Text("macOS 26 doesn't clean its wallpaper-image cache; with continuity on it can grow to many GB over time. Aerial keeps it under 2 GB.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            if cleanWallpaperCache && !hasCacheAccess {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("Access not yet granted — the cleaner can't run until you allow it.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Grant Access…") {
                        Task { @MainActor in
                            _ = await WallpaperCacheCleaner.shared.requestAccess()
                            hasCacheAccess = WallpaperCacheCleaner.shared.hasBookmark
                            // Granting may unblock monitoring.
                            WallpaperCacheCleaner.shared.reevaluate()
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Load Settings

    private func loadSettings() {
        autoPauseEnabled = Preferences.desktopAutoPause
        autoPauseThreshold = Preferences.desktopAutoPauseThreshold
        viewingMode = PrefsDisplays.viewingMode
        launchMode = Preferences.launchMode
        restartAtLaunch = Preferences.restartBackground
        replaceWallpaper = Preferences.replaceWallpaper
        cleanWallpaperCache = Preferences.cleanWallpaperCache
        videoFormat = PrefsVideos.videoFormat
        hasCacheAccess = WallpaperCacheCleaner.shared.hasBookmark
        pauseOnBattery = Preferences.desktopPauseOnBattery
        pauseOnBatteryMode = Preferences.desktopPauseOnBatteryMode
        hasBatteryHardware = Battery.hasBattery()
    }

    private func startCoveragePolling() {
        // Snapshot screen list as (index + name + displayID) on main
        // thread. Capturing the displayID rather than the CG bounds
        // lets the timer below re-fetch current bounds via
        // CGDisplayBounds on every tick, so a System Settings →
        // Displays rearrange is reflected without closing+reopening
        // the panel.
        let screens = NSScreen.screens.enumerated().compactMap { (index, screen) -> (Int, String, CGDirectDisplayID)? in
            guard let did = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            return (index, screen.localizedName, did)
        }

        coverageTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                DispatchQueue.global(qos: .utility).async {
                    let results = screens.map { (index, name, did) in
                        ScreenCoverageInfo(
                            id: index,
                            name: name,
                            coverage: DesktopOcclusionMonitor.coverage(for: CGDisplayBounds(did))
                        )
                    }
                    DispatchQueue.main.async {
                        screenCoverages = results
                    }
                }
            }
    }
}

// MARK: - Preview

struct DesktopSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        DesktopSettingsPanel()
            .frame(width: 500, height: 400)
    }
}

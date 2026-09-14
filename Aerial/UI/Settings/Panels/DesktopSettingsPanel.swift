//
//  DesktopSettingsPanel.swift
//  Aerial Companion
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

struct ScreenCoverageInfo: Identifiable {
    let id: Int        // index in NSScreen.screens
    let name: String
    var coverage: Double
}

struct DesktopSettingsPanel: View {
    @State private var autoPauseEnabled: Bool = true
    @State private var autoPauseThreshold: Double = 0.6
    @State private var screenCoverages: [ScreenCoverageInfo] = []
    /// Live list of apps currently covering any watched screen, merged
    /// across screens (each app shows its highest coverage), refreshed
    /// by the same 1-second poller as `screenCoverages`.
    @State private var occludingApps: [OccludingAppInfo] = []
    /// The persisted ignore list (bundle IDs / owner names).
    @State private var ignoredApps: [String] = []
    @State private var coverageTimer: AnyCancellable?
    /// Snapshot of `PrefsDisplays.viewingMode` at panel-appear time.
    /// Used to switch the auto-pause copy and per-screen badges between
    /// independent ("would pause") and shared ("would pause all"
    /// + "paused (other screen)") wording.
    @State private var viewingMode: ViewingMode = .independent

    /// Pause desktop wallpaper / fullscreen-window playback on battery.
    @State private var pauseOnBattery: Bool = false
    /// `"anyBattery"` or `"lowBattery"`.
    @State private var pauseOnBatteryMode: String = "anyBattery"
    /// Snapshot of `Battery.hasBattery()` at load time. Drives the
    /// "no battery detected" warning when the user enables the toggle
    /// on a Mac that doesn't have a battery (Mac mini, Studio, etc.).
    @State private var hasBatteryHardware: Bool = false

    /// Pause the wallpaper under serious/critical thermal pressure.
    @State private var pauseOnThermal: Bool = true
    /// Pause the wallpaper while macOS Low Power Mode is on.
    @State private var pauseOnLowPower: Bool = false
    /// Pause the wallpaper while any camera is in use.
    @State private var pauseOnCamera: Bool = false

    /// Auto-advance the playlist at a fixed cadence (even while paused).
    @State private var autoAdvanceEnabled: Bool = false
    /// Auto-advance cadence in minutes.
    @State private var autoAdvanceMinutes: Int = 60

    /// Reverse status channel — drives the Troubleshooting box's
    /// "running extension version" line.
    @ObservedObject private var statusMonitor = WallpaperStatusMonitor.shared
    @State private var isRestartingAgent = false

    private let autoAdvanceIntervals: [(label: String, minutes: Int)] = [
        ("15 minutes", 15),
        ("30 minutes", 30),
        ("1 hour", 60),
        ("2 hours", 120),
        ("3 hours", 180),
        ("4 hours", 240),
        ("8 hours", 480),
        ("12 hours", 720),
        ("Daily", 1440),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Wallpaper")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)

                autoAdvanceSection

                // Auto-pause and battery pause govern the wallpaper on
                // every OS — the occlusion auto-pause now drives the
                // wallpaper extension on Sonoma+.
                autoPauseSection

                pauseOnBatterySection

                powerAndThermalSection

                cameraSection

                troubleshootingSection

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

    // MARK: - Auto-Advance Section

    private var autoAdvanceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Change video periodically", isOn: $autoAdvanceEnabled)
                    .font(.system(size: 14))
                    .onChange(of: autoAdvanceEnabled) { newValue in
                        Preferences.desktopAutoAdvance = newValue
                        PlaybackManager.shared.reevaluateAutoAdvance()
                    }

                Text("Advances the playlist on all displays at the chosen interval — even while paused or auto-paused, so a paused wallpaper doesn't show the same frame forever.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                if autoAdvanceEnabled {
                    Divider()

                    HStack {
                        Text("Change video every")
                            .font(.system(size: 14))
                        Spacer()
                        Picker("", selection: $autoAdvanceMinutes) {
                            ForEach(autoAdvanceIntervals, id: \.minutes) { option in
                                Text(option.label).tag(option.minutes)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 220, alignment: .trailing)
                        .onChange(of: autoAdvanceMinutes) { newValue in
                            Preferences.desktopAutoAdvanceMinutes = newValue
                            PlaybackManager.shared.reevaluateAutoAdvance()
                        }
                    }

                    Text("Skipping a video manually restarts the countdown.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        } label: {
            Label("Auto-Advance", systemImage: "forward.end")
                .font(Font.title3.bold())
                .padding(4)
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
                        // Apply immediately — disabling must clear any
                        // active coverage flags now, not at the next
                        // status tick.
                        WallpaperAutoPauseCoordinator.shared.reevaluate()
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

                        Divider()

                        occludingAppsList

                        if !ignoredApps.isEmpty {
                            Divider()
                            ignoredAppsList
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

    // MARK: - Occluding / Ignored Apps

    private var occludingAppsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apps covering the wallpaper")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            if occludingApps.isEmpty {
                Text("No windows are covering the wallpaper.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(occludingApps) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: app.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(app.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .frame(maxWidth: 160, alignment: .leading)
                        Text("\(Int(app.coverage * 100))%")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(width: 32, alignment: .trailing)
                        Spacer()
                        Button("Ignore") {
                            ignoreOccludingApp(app)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Text("Ignored apps don't count toward the coverage threshold — useful for tools that keep a transparent window over the screen.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ignoredAppsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ignored apps")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            ForEach(ignoredApps, id: \.self) { id in
                let display = ignoredAppDisplay(id)
                HStack(spacing: 8) {
                    Image(nsImage: display.icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(display.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)
                    Spacer()
                    Button("Remove") {
                        removeIgnoredApp(id)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func ignoreOccludingApp(_ app: OccludingAppInfo) {
        var current = Preferences.desktopAutoPauseIgnoredApps
        if !current.contains(app.id) {
            current.append(app.id)
            Preferences.desktopAutoPauseIgnoredApps = current
        }
        ignoredApps = current
        // Drop the row now rather than at the poller's next tick.
        occludingApps.removeAll { $0.id == app.id }
    }

    private func removeIgnoredApp(_ id: String) {
        let current = Preferences.desktopAutoPauseIgnoredApps.filter { $0 != id }
        Preferences.desktopAutoPauseIgnoredApps = current
        ignoredApps = current
    }

    /// Display name + icon for an ignore-list entry, which may not be
    /// running anymore (or may be an owner-name entry with no bundle).
    private func ignoredAppDisplay(_ id: String) -> (name: String, icon: NSImage) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            return (running.localizedName ?? id,
                    running.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return (FileManager.default.displayName(atPath: url.path),
                    NSWorkspace.shared.icon(forFile: url.path))
        }
        return (id, NSWorkspace.shared.icon(for: .applicationBundle))
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

    // MARK: - Power & Thermal Section

    private var powerAndThermalSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Pause under thermal pressure", isOn: $pauseOnThermal)
                    .font(.system(size: 14))
                    .onChange(of: pauseOnThermal) { newValue in
                        Preferences.desktopPauseOnThermal = newValue
                        PlaybackManager.shared.evaluateThermalState()
                    }

                Text("Automatically pauses the wallpaper while this Mac reports serious thermal pressure (fans at full tilt), and resumes once it cools down.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Divider()

                Toggle("Pause in Low Power Mode", isOn: $pauseOnLowPower)
                    .font(.system(size: 14))
                    .onChange(of: pauseOnLowPower) { newValue in
                        Preferences.desktopPauseOnLowPower = newValue
                        PlaybackManager.shared.evaluateThermalState()
                    }

                Text("Pauses the wallpaper while macOS Low Power Mode is enabled. Click the popover's play button to override either pause for the current session.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(12)
        } label: {
            Label("Power & Thermal", systemImage: "thermometer.medium")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    // MARK: - Camera Section

    private var cameraSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Pause while the camera is in use", isOn: $pauseOnCamera)
                    .font(.system(size: 14))
                    .onChange(of: pauseOnCamera) { newValue in
                        Preferences.desktopPauseOnCamera = newValue
                        PlaybackManager.shared.evaluateCameraState()
                    }

                Text("Pauses the wallpaper whenever any app uses a camera — videoconferences, recordings — and resumes when it turns off. Aerial only reads the camera's on/off state, never the picture.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        } label: {
            Label("Camera", systemImage: "video")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    // MARK: - Troubleshooting Section

    private var troubleshootingSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                extensionStatusLine

                Button("Restart Wallpaper Agent") {
                    restartWallpaperAgent()
                }
                .disabled(isRestartingAgent)

                Text("If you see the default system wallpaper, or a black screen, use this feature. Restarting the wallpaper agent reloads Aerial's wallpaper extension; your desktop will flicker briefly.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        } label: {
            Label("Troubleshooting", systemImage: "ant")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    /// "Which extension build is the agent running" — the same verdict
    /// the startup check and the diagnostics bundle use.
    @ViewBuilder
    private var extensionStatusLine: some View {
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let app = "\(Helpers.version) (\(appBuild))"
        let running = statusMonitor.status?.identity
        switch WallpaperExtensionHealth.verdict(status: statusMonitor.status, isRunning: statusMonitor.isRunning) {
        case .notRunning:
            extensionStatusText("Wallpaper extension: not running", warning: false)
        case .upToDate:
            extensionStatusText("Wallpaper extension: \(running?.version ?? "?") (\(running?.build ?? "?")) — up to date", warning: false)
        case .unknownOlder:
            extensionStatusText("Wallpaper extension: running an older version — this app is \(app). Restart the wallpaper agent to load the new version.", warning: true)
        case .mismatch:
            extensionStatusText("Wallpaper extension: \(running?.version ?? "?") (\(running?.build ?? "?")) — this app is \(app). Restart the wallpaper agent to load the new version.", warning: true)
        }
    }

    private func extensionStatusText(_ text: String, warning: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(warning ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func restartWallpaperAgent() {
        isRestartingAgent = true
        WallpaperExtensionHealth.restartAgent(reason: "Settings → Wallpaper button") {
            // The respawned appex writes its identity at init within
            // ~1 s; 3 s covers a slow disk before re-reading the status.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                WallpaperStatusMonitor.shared.reload()
                isRestartingAgent = false
            }
        }
    }

    // MARK: - Load Settings

    private func loadSettings() {
        autoPauseEnabled = Preferences.desktopAutoPause
        autoPauseThreshold = Preferences.desktopAutoPauseThreshold
        ignoredApps = Preferences.desktopAutoPauseIgnoredApps
        viewingMode = PrefsDisplays.viewingMode
        pauseOnBattery = Preferences.desktopPauseOnBattery
        pauseOnBatteryMode = Preferences.desktopPauseOnBatteryMode
        hasBatteryHardware = Battery.hasBattery()
        pauseOnThermal = Preferences.desktopPauseOnThermal
        pauseOnLowPower = Preferences.desktopPauseOnLowPower
        pauseOnCamera = Preferences.desktopPauseOnCamera
        autoAdvanceEnabled = Preferences.desktopAutoAdvance
        autoAdvanceMinutes = Preferences.desktopAutoAdvanceMinutes
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

        coverageTimer = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                DispatchQueue.global(qos: .utility).async {
                    // One window snapshot + identity pass shared across
                    // screens (index-aligned with `screens`).
                    let allDetails = DesktopOcclusionMonitor.coverageDetails(
                        for: screens.map { CGDisplayBounds($0.2) }
                    )
                    var mergedApps = [String: OccludingAppInfo]()
                    let results = screens.enumerated().map { (offset, screen) -> ScreenCoverageInfo in
                        let (index, name, _) = screen
                        let details = allDetails[offset]
                        // Merged across screens: keep each app's highest coverage.
                        for app in details.apps {
                            if let existing = mergedApps[app.id], existing.coverage >= app.coverage { continue }
                            mergedApps[app.id] = app
                        }
                        return ScreenCoverageInfo(id: index, name: name, coverage: details.total)
                    }
                    // Drop apps that would display as 0%; tie-break by name
                    // so equal-coverage rows don't jitter between ticks.
                    let apps = mergedApps.values
                        .filter { $0.coverage >= 0.01 }
                        .sorted { $0.coverage == $1.coverage ? $0.name < $1.name : $0.coverage > $1.coverage }
                    DispatchQueue.main.async {
                        screenCoverages = results
                        occludingApps = apps
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

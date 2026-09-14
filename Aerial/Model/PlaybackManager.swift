//
//  PlaybackManager.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import Foundation
import Combine
import AppKit

/// Playback modes for the Aerial Companion app
enum PlaybackMode: Equatable {
    case none       // Nothing playing
    case desktop    // Desktop wallpaper mode (can be multiple screens)
    case monitor    // Window/fullscreen mode
}

/// Central state manager for playback controls
@MainActor
class PlaybackManager: ObservableObject {

    // MARK: - Singleton

    static let shared = PlaybackManager()

    // MARK: - Published State

    /// Current playback mode
    @Published private(set) var playbackMode: PlaybackMode = .none

    /// Whether something is currently playing
    @Published private(set) var isPlaying: Bool = false

    /// Whether playback is paused
    @Published private(set) var isPaused: Bool = false

    /// Whether playback is paused because the system is on battery (or
    /// low battery, per `Preferences.desktopPauseOnBatteryMode`).
    /// Distinct from `isPaused` — composes with it so the play/pause
    /// button can show a battery icon while keeping user-pause state
    /// intact. Driven by `BatteryStateMonitor` + `evaluateBatteryState`.
    @Published private(set) var isBatteryPaused: Bool = false

    /// True after the user explicitly clicks "resume" while battery-
    /// paused. Honoured until the next plug-in (which clears it) — at
    /// that point any subsequent unplug re-engages battery-pause as
    /// normal. Single-cycle scope, not persisted.
    private var batteryOverrideForThisCycle = false

    /// Why the thermal monitor is holding playback, nil when it isn't.
    /// Both causes ride the single `.thermal` reason; the split only
    /// exists so the UI can say WHICH condition paused it.
    enum ThermalPauseCause {
        case thermalPressure
        case lowPowerMode
    }

    /// Non-nil while playback is paused because of thermal pressure
    /// (`.serious`+) or macOS Low Power Mode, per the corresponding
    /// prefs. Same composition rules as `isBatteryPaused`. Driven by
    /// `setupThermalMonitor` + `evaluateThermalState`.
    @Published private(set) var thermalPauseCause: ThermalPauseCause?

    /// Whether the thermal/LPM rule is holding playback right now.
    var isThermalPaused: Bool { thermalPauseCause != nil }

    /// User "resume" override while thermal-paused — mirrors
    /// `batteryOverrideForThisCycle`; cleared when the thermal/LPM
    /// condition itself clears.
    private var thermalOverrideForThisCycle = false

    /// Whether playback is paused because a camera is in use, per the
    /// `desktopPauseOnCamera` pref. Driven by `CameraUsageMonitor`.
    @Published private(set) var isCameraPaused: Bool = false

    /// User "resume" override while camera-paused — cleared when the
    /// camera stops.
    private var cameraOverrideForThisCycle = false

    /// Global playback speed (0-100, maps to slider values)
    @Published var globalSpeed: Int {
        didSet {
            Preferences.globalSpeed = globalSpeed
            updatePlaybackSpeed()
        }
    }

    /// Set of screen UUIDs that have active desktop wallpaper
    @Published private(set) var activeScreenUuids: Set<String> = []

    /// Available screens with their UUIDs and names
    @Published private(set) var availableScreens: [ScreenInfo] = []

    /// UUID of the screen the popover is currently displayed on
    @Published private(set) var popoverScreenUUID: String? = nil

    // MARK: - Types

    struct ScreenInfo: Identifiable, Equatable {
        let uuid: String
        let name: String
        var id: String { uuid }
    }

    /// Effective screen UUID for playlist queries — non-nil only in independent mode.
    var effectiveScreenUUID: String? {
        guard PrefsDisplays.viewingMode == .independent else { return nil }
        return popoverScreenUUID
    }

    // MARK: - Private Properties

    /// Desktop launcher instances keyed by screen UUID
    private var desktopLauncherInstances: [String: DesktopLauncher] = [:]

    /// Per-screen occlusion state, keyed by screen UUID. Updated by every
    /// launcher's `DesktopOcclusionMonitor` callback (and by the
    /// screensaver-handoff seed). The aggregate over running launchers
    /// drives the actual pause/resume call in shared viewing modes.
    /// @Published so the popover's `pauseMention` line refreshes live on
    /// a coverage flip — mutations are rare (boolean transitions plus
    /// launcher start/stop), so the publish cost is negligible.
    @Published private var perScreenOcclusion: [String: Bool] = [:]

    /// 1 Hz timer that refreshes `PlaybackProgressModel` for the
    /// popover's thumbnail progress bar. Sourced from the desktop
    /// AVPlayer when the wallpaper is running, from `PlaylistManager`'s
    /// persisted timestamp otherwise. The timer always ticks, but
    /// `refreshPlaybackProgress` self-gates on popover visibility so a
    /// closed popover costs nothing.
    private var progressTimer: DispatchSourceTimer?

    // MARK: - Initialization

    private init() {
        self.globalSpeed = Preferences.globalSpeed
        refreshScreenList()
        startProgressTimer()

        // Listen for screen configuration changes
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenConfigurationChange()
            }
        }

        // Orphan-detect signal from AerialSaverView (Companion mode only).
        // Posted when a view's window has settled on a screen whose UUID
        // doesn't match the launcher's target. We drop the launcher and let
        // the deferred reconcile pass try again on a hopefully-settled OS.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("com.glouel.aerial.launcherOrphanDetected"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let uuid = note.object as? String else { return }
            Task { @MainActor in
                self?.handleLauncherOrphanDetected(uuid: uuid)
            }
        }

        // Battery-aware pause: subscribe to power-source change events,
        // re-evaluate on system wake (macOS can change battery state
        // during sleep without firing the IOPS callback), and check
        // initial state so a launch-on-battery doesn't play for a few
        // seconds before the first transition.
        setupBatteryMonitor()

        // Thermal / Low Power Mode and camera-aware pause, mirroring the
        // battery monitor's evaluate-on-event + initial-check shape.
        setupThermalMonitor()
        setupCameraMonitor()

        // Restore active screens on launch if preference is enabled
        if Preferences.restartBackground {
            restoreActiveScreens()
        }

        // Listen for video changes from the screensaver extension / desktop saver
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.glouel.aerial.nextvideo"),
            object: nil,
            queue: .main
        ) { notification in
            PlaylistManager.shared.syncFromExtension()
            // VoiceOver: announce the new video so users monitoring
            // playback hear the title without having to open the
            // popover. `.low` priority lets VO collapse rapid bursts.
            if let name = notification.object as? String, !name.isEmpty {
                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: "Now playing: \(name)",
                        .priority: NSAccessibilityPriorityLevel.low.rawValue
                    ]
                )
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        progressTimer?.cancel()
    }

    // MARK: - Screen Management

    /// Refresh the list of available screens
    func refreshScreenList() {
        availableScreens = NSScreen.screens.map { screen in
            let name = screen.localizedName
            return ScreenInfo(uuid: screen.screenUuid, name: name)
        }
    }

    /// Check if a specific screen has active desktop wallpaper
    func isScreenActive(_ uuid: String) -> Bool {
        activeScreenUuids.contains(uuid)
    }

    // MARK: - Start Actions

    /// Start the screensaver and lock the screen
    func startScreensaver() {
        // Use private API via dlopen
        if let libHandle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY) {
            let sym = dlsym(libHandle, "SACScreenSaverStartNow")
            typealias SACFunction = @convention(c) () -> Void
            let SACLockScreenImmediate = unsafeBitCast(sym, to: SACFunction.self)
            SACLockScreenImmediate()
            dlclose(libHandle)
        }
    }

    /// Start desktop wallpaper on all screens
    func startDesktopOnAllScreens() {
        for screen in NSScreen.screens {
            if !isScreenActive(screen.screenUuid) {
                toggleDesktopLauncher(for: screen.screenUuid)
            }
        }
    }

    /// Toggle desktop wallpaper for a specific screen
    /// - Parameter screenUuid: The UUID of the screen to toggle
    /// - Returns: Whether the screen is now active
    @discardableResult
    func toggleDesktopLauncher(for screenUuid: String) -> Bool {
        var isRunning = false

        if let launcher = desktopLauncherInstances[screenUuid] {
            launcher.toggleLauncher()
            launcher.changeSpeed(globalSpeed)
            isRunning = launcher.isRunning
        } else if let screen = NSScreen.getScreenByUuid(screenUuid) {
            let launcher = DesktopLauncher(screen: screen)
            desktopLauncherInstances[screenUuid] = launcher
            launcher.toggleLauncher()
            launcher.changeSpeed(globalSpeed)
            isRunning = launcher.isRunning
        }

        // Resync per-screen occlusion bookkeeping with this launcher's running
        // state. Without this, a stale `true` from a prior life of the same UUID
        // pins the shared-mode aggregate and silently suppresses auto-pause /
        // auto-resume after viewing-mode flips or stop/start cycles.
        if isRunning {
            perScreenOcclusion[screenUuid] = false
            // A freshly-(re)created launcher's coordinator starts with an
            // empty reason set. The evaluators can't fix this — their
            // `shouldPause != isXPaused` guards no-op when the manager state
            // is already correct — so re-assert the current decisions
            // directly onto the new launcher.
            if let launcher = desktopLauncherInstances[screenUuid] {
                reassertPauseReasons { launcher.pause(reason: $0) }
            }
        } else {
            perScreenOcclusion.removeValue(forKey: screenUuid)
        }

        // Update active screens set
        updateActiveScreens(screenUuid, isActive: isRunning)

        // Update playback mode based on active screens
        updatePlaybackModeFromActiveScreens()

        return isRunning
    }

    /// Toggle fullscreen mode on the active screen — starts if not
    /// currently in `.monitor`, stops if it is. Mirrors the popover
    /// Fullscreen button so the global shortcut and the menu UI
    /// behave identically.
    func toggleFullscreen() {
        if playbackMode == .monitor {
            stop()
        } else {
            startWindowMode()
        }
    }

    /// Start window/fullscreen mode
    func startWindowMode() {
        playbackMode = .monitor
        SaverLauncher.instance.windowMode()
        SaverLauncher.instance.changeSpeed(globalSpeed)
        isPlaying = true
        isPaused = false
        // Fresh window-mode start clears any user pause, but system
        // reasons (battery, thermal, camera) must carry over.
        reassertPauseReasons { SaverLauncher.instance.pause(reason: $0) }
    }

    // MARK: - Playback Controls

    /// Stop all playback
    func stop() {
        switch playbackMode {
        case .desktop:
            // Stop all desktop launchers
            for launcher in desktopLauncherInstances.values where launcher.isRunning {
                launcher.toggleLauncher()
            }
            activeScreenUuids.removeAll()
            Preferences.enabledWallpaperScreenUuids = []

        case .monitor:
            SaverLauncher.instance.stopScreensaver()

        case .none:
            break
        }

        playbackMode = .none
        isPlaying = false
        isPaused = false
    }

    /// Toggle pause/resume
    func togglePause() {
        guard playbackMode != .none else { return }

        // Click while battery-paused = "play despite battery". Clear
        // the battery flag, set an override that survives until the
        // next plug-in, and also clear any user-pause so a single
        // click reads as expected ("hit play, get video").
        if isBatteryPaused {
            debugLog("🔋 User overrode battery-pause via popover button")
            batteryOverrideForThisCycle = true
            isPaused = false
            applyBatteryStateChange(paused: false)
            broadcastUserPause(false)
            return
        }

        // Same deal for a thermal/Low Power Mode pause: hitting play
        // means "play despite the condition" for this episode.
        if isThermalPaused {
            debugLog("🌡️ User overrode thermal-pause via popover button")
            thermalOverrideForThisCycle = true
            isPaused = false
            applyThermalStateChange(cause: nil)
            broadcastUserPause(false)
            return
        }

        // And for a camera pause: play despite the running camera.
        if isCameraPaused {
            debugLog("📷 User overrode camera-pause via popover button")
            cameraOverrideForThisCycle = true
            isPaused = false
            applyCameraStateChange(paused: false)
            broadcastUserPause(false)
            return
        }

        isPaused.toggle()
        broadcastUserPause(isPaused)
    }

    /// Re-assert the manager's current pause decisions onto a freshly
    /// (re)created launcher, whose coordinator starts with an empty
    /// reason set. Caller supplies the target's `pause(reason:)`.
    private func reassertPauseReasons(via pause: (PauseReasons) -> Void) {
        if isPaused { pause(.user) }
        if isBatteryPaused { pause(.battery) }
        if isThermalPaused { pause(.thermal) }
        if isCameraPaused { pause(.camera) }
    }

    /// Broadcast a user-pause state to whichever launchers are active.
    /// Factored out of togglePause so the battery-override path can
    /// reuse the same dispatch logic.
    private func broadcastUserPause(_ newPaused: Bool) {
        switch playbackMode {
        case .desktop:
            for launcher in desktopLauncherInstances.values where launcher.isRunning {
                launcher.setUserPaused(newPaused)
            }
        case .monitor:
            SaverLauncher.instance.setUserPaused(newPaused)
        case .none:
            break
        }
    }

    // MARK: - Battery-aware pause

    /// Wired up once during init. Companion-only; the extension target
    /// doesn't compile `BatteryStateMonitor`.
    private func setupBatteryMonitor() {
        #if COMPANION_APP
        BatteryStateMonitor.shared.onChange = { [weak self] in
            Task { @MainActor in self?.evaluateBatteryState() }
        }
        BatteryStateMonitor.shared.start()

        // macOS sleep can flip battery state without an IOPS callback
        // (the canonical case is unplug-while-asleep). Re-evaluate on
        // wake so we catch transitions that happened off-clock.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluateBatteryState() }
        }

        // Initial check — if we're launched on battery and the pref is
        // on, pause the first frame we play rather than waiting for a
        // state transition.
        evaluateBatteryState()
        #endif
    }

    /// Re-read battery state + pref and apply the resulting pause/resume.
    /// Called on every IOPS notification, on wake, at startup, and
    /// whenever the user toggles the pref in Settings.
    func evaluateBatteryState() {
        guard Preferences.desktopPauseOnBattery else {
            // Pref is off — make sure we don't leave anything paused.
            if isBatteryPaused {
                applyBatteryStateChange(paused: false)
            }
            batteryOverrideForThisCycle = false
            return
        }

        let mode = Preferences.desktopPauseOnBatteryMode
        let shouldPause: Bool
        switch mode {
        case "lowBattery":
            // Only pause when the battery is genuinely depleting. If
            // it's plugged in and charging-from-low, no need to pause.
            shouldPause = Battery.isUnplugged() && Battery.isLow()
        case "anyBattery":
            fallthrough
        default:
            shouldPause = Battery.isUnplugged()
        }

        // Plug-back-in clears the override so the next unplug
        // re-engages battery-pause normally.
        if !shouldPause && batteryOverrideForThisCycle {
            batteryOverrideForThisCycle = false
            debugLog("🔋 Battery override cleared (back on AC)")
        }

        // Honor the user's session override.
        if shouldPause && batteryOverrideForThisCycle {
            return
        }

        if shouldPause != isBatteryPaused {
            applyBatteryStateChange(paused: shouldPause)
        }
    }

    /// Toggle the battery-paused state across all active launchers.
    /// Called from `evaluateBatteryState` (when the IOPS notification
    /// or pref change actually flips the rule) and from the override
    /// path inside `togglePause`.
    private func applyBatteryStateChange(paused: Bool) {
        isBatteryPaused = paused
        debugLog("🔋 PlaybackManager: isBatteryPaused = \(paused)")

        switch playbackMode {
        case .desktop:
            for launcher in desktopLauncherInstances.values where launcher.isRunning {
                paused ? launcher.pause(reason: .battery) : launcher.resume(reason: .battery)
            }
        case .monitor:
            paused ? SaverLauncher.instance.pause(reason: .battery) : SaverLauncher.instance.resume(reason: .battery)
        case .none:
            break
        }
    }

    // MARK: - Thermal / Low Power Mode pause

    /// Wired up once during init, mirroring `setupBatteryMonitor`. Both
    /// notifications arrive on arbitrary threads — hop to main.
    private func setupThermalMonitor() {
        #if COMPANION_APP
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluateThermalState() }
        }
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluateThermalState() }
        }
        // Wake can land with a different thermal/LPM state than we
        // slept with (e.g. LPM toggled from the lock screen).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluateThermalState() }
        }
        evaluateThermalState()
        #endif
    }

    /// Re-read thermal/LPM state + prefs and apply the resulting
    /// pause/resume. Called on both ProcessInfo notifications, on wake,
    /// at startup, and when the user toggles either pref in Settings.
    func evaluateThermalState() {
        let thermalState = ProcessInfo.processInfo.thermalState
        let thermalHot = Preferences.desktopPauseOnThermal
            && (thermalState == .serious || thermalState == .critical)
        let lowPower = Preferences.desktopPauseOnLowPower
            && ProcessInfo.processInfo.isLowPowerModeEnabled
        // Thermal pressure reported first — it's the more urgent story
        // if both hold.
        let cause: ThermalPauseCause? = thermalHot ? .thermalPressure
            : (lowPower ? .lowPowerMode : nil)

        // Condition cleared → drop the session override so the next
        // episode re-engages normally.
        if cause == nil && thermalOverrideForThisCycle {
            thermalOverrideForThisCycle = false
            debugLog("🌡️ Thermal override cleared (condition ended)")
        }

        // Honor the user's session override.
        if cause != nil && thermalOverrideForThisCycle {
            return
        }

        if cause != thermalPauseCause {
            if let cause {
                debugLog("🌡️ Pausing playback: \(cause == .thermalPressure ? "thermal state \(thermalState.rawValue)" : "Low Power Mode")")
            }
            applyThermalStateChange(cause: cause)
        }
    }

    /// Toggle the thermal-paused state across all active launchers.
    private func applyThermalStateChange(cause: ThermalPauseCause?) {
        thermalPauseCause = cause
        debugLog("🌡️ PlaybackManager: isThermalPaused = \(cause != nil)")

        switch playbackMode {
        case .desktop:
            for launcher in desktopLauncherInstances.values where launcher.isRunning {
                cause != nil ? launcher.pause(reason: .thermal) : launcher.resume(reason: .thermal)
            }
        case .monitor:
            cause != nil ? SaverLauncher.instance.pause(reason: .thermal) : SaverLauncher.instance.resume(reason: .thermal)
        case .none:
            break
        }
    }

    // MARK: - Camera-aware pause

    /// Wired up once during init. The CMIO listeners only run while the
    /// pref is on — `evaluateCameraState` starts/stops the monitor.
    private func setupCameraMonitor() {
        #if COMPANION_APP
        CameraUsageMonitor.shared.onChange = { [weak self] in
            Task { @MainActor in self?.evaluateCameraState() }
        }
        evaluateCameraState()
        #endif
    }

    /// Re-read camera state + pref and apply the resulting pause/resume.
    /// Called on every CMIO running-state change, at startup, and when
    /// the user toggles the pref in Settings.
    func evaluateCameraState() {
        guard Preferences.desktopPauseOnCamera else {
            CameraUsageMonitor.shared.stop()
            if isCameraPaused {
                applyCameraStateChange(paused: false)
            }
            cameraOverrideForThisCycle = false
            return
        }
        CameraUsageMonitor.shared.start()

        let shouldPause = CameraUsageMonitor.shared.anyCameraInUse

        // Camera stopped → drop the session override so the next call
        // re-engages normally.
        if !shouldPause && cameraOverrideForThisCycle {
            cameraOverrideForThisCycle = false
            debugLog("📷 Camera override cleared (camera off)")
        }

        // Honor the user's session override.
        if shouldPause && cameraOverrideForThisCycle {
            return
        }

        if shouldPause != isCameraPaused {
            applyCameraStateChange(paused: shouldPause)
        }
    }

    /// Toggle the camera-paused state across all active launchers.
    private func applyCameraStateChange(paused: Bool) {
        isCameraPaused = paused
        debugLog("📷 PlaybackManager: isCameraPaused = \(paused)")

        switch playbackMode {
        case .desktop:
            for launcher in desktopLauncherInstances.values where launcher.isRunning {
                paused ? launcher.pause(reason: .camera) : launcher.resume(reason: .camera)
            }
        case .monitor:
            paused ? SaverLauncher.instance.pause(reason: .camera) : SaverLauncher.instance.resume(reason: .camera)
        case .none:
            break
        }
    }

    /// Advance to the next entry using the natural forward-scan path
    /// (which honours time-of-day / availability filters). No-op when
    /// nothing is playing.
    func nextVideo() {
        switch playbackMode {
        case .desktop:
            if let uuid = effectiveScreenUUID {
                desktopLauncherInstances[uuid]?.skipToNext()
            } else {
                desktopLauncherInstances.values.first(where: { $0.isRunning })?.skipToNext()
            }
        case .monitor:
            SaverLauncher.instance.skipToNext()
        case .none:
            break
        }
    }

    /// Step back to the previous entry using the dedicated backward-
    /// scan path (`PlayerCoordinator.playPreviousVideo`). Going through
    /// the forward `playNextVideo` path produces the wrong result when
    /// a time-of-day filter rejects the prev entry. No-op when nothing
    /// is playing.
    func previousVideo() {
        switch playbackMode {
        case .desktop:
            if let uuid = effectiveScreenUUID {
                desktopLauncherInstances[uuid]?.skipToPrevious()
            } else {
                desktopLauncherInstances.values.first(where: { $0.isRunning })?.skipToPrevious()
            }
        case .monitor:
            SaverLauncher.instance.skipToPrevious()
        case .none:
            break
        }
    }

    /// Jump to a specific playlist entry on the appropriate screen(s).
    func skipTo(playlistIndex: Int, screenUUID: String?) {
        switch playbackMode {
        case .desktop:
            if let uuid = screenUUID {
                desktopLauncherInstances[uuid]?.skipTo(playlistIndex: playlistIndex)
            } else {
                desktopLauncherInstances.values.first(where: { $0.isRunning })?.skipTo(playlistIndex: playlistIndex)
            }
        case .monitor:
            SaverLauncher.instance.skipTo(playlistIndex: playlistIndex)
        case .none:
            break
        }
    }

    /// Refresh playback for a single screen (restart its desktop launcher).
    func refreshPlayback(for screenUUID: String) {
        guard playbackMode == .desktop,
              let launcher = desktopLauncherInstances[screenUUID],
              launcher.isRunning else { return }
        launcher.toggleLauncher()
        launcher.toggleLauncher()
        launcher.changeSpeed(globalSpeed)
    }

    /// Refresh playback after settings change
    func refreshPlayback() {
        switch playbackMode {
        case .desktop:
            for launcher in desktopLauncherInstances.values where launcher.isRunning {
                launcher.toggleLauncher()
                launcher.toggleLauncher()
                launcher.changeSpeed(globalSpeed)
            }

        case .monitor:
            SaverLauncher.instance.stopScreensaver()
            SaverLauncher.instance.windowMode()
            SaverLauncher.instance.changeSpeed(globalSpeed)

        case .none:
            break
        }
    }

    // MARK: - Playback Progress

    /// Start the 1 Hz timer that pushes progress updates into the
    /// popover's thumbnail progress bar. Called from `init` and runs
    /// for the lifetime of the singleton.
    private func startProgressTimer() {
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 1.0, repeating: 1.0)
        source.setEventHandler { [weak self] in
            self?.refreshPlaybackProgress()
        }
        source.resume()
        progressTimer = source
    }

    /// Recompute the current playback fraction (0...1) from the
    /// authoritative source for the current state:
    ///   - `.desktop` mode + a running launcher → live AVPlayer time
    ///     (`launcher.currentPosition`).
    ///   - Anything else → last persisted timestamp from
    ///     `PlaylistManager.currentPlaybackTimestamp(for:)`.
    /// In both cases the denominator is the current video's
    /// `AerialVideo.duration` (cached via `PrefsVideos.durationCache`
    /// + AVAsset probe). When duration is unknown or zero (e.g. live
    /// streams), progress is reported as 0 — the bar then hides.
    ///
    /// Only publishes into `PlaybackProgressModel` when the value differs by
    /// more than ~0.5 %. At a 1 Hz tick that's enough resolution for
    /// a 96 pt wide bar (≈0.5 pt of motion per tick) while avoiding
    /// pointless SwiftUI re-renders.
    @MainActor
    private func refreshPlaybackProgress() {
        // Visibility gate: the progress bars live only in the popover,
        // and a CLOSED popover's hosting view stays alive — publishing
        // into it re-rendered the whole invisible tree every second.
        // On reopen the next 1 Hz tick heals the bar.
        guard AppDelegate.shared?.popover.isShown == true else { return }

        // Nothing playing → nothing to recompute (the bar hides).
        guard playbackMode != .none else { return }

        let screenUUID = effectiveScreenUUID
        let progress: Double = {
            guard let video = PlaylistManager.shared.currentVideo(for: screenUUID),
                  video.duration > 0 else {
                return 0
            }
            let position: Double
            if playbackMode == .desktop,
               let launcher = activeLauncherForProgress(screenUUID: screenUUID),
               let live = launcher.currentPosition {
                position = live
            } else {
                position = PlaylistManager.shared.currentPlaybackTimestamp(for: screenUUID) ?? 0
            }
            return max(0, min(1, position / video.duration))
        }()
        if abs(progress - PlaybackProgressModel.shared.fraction) > 0.005 {
            PlaybackProgressModel.shared.fraction = progress
        }
    }

    /// Pick a launcher whose `currentPosition` should drive the progress
    /// bar. Independent mode: the launcher for the popover's screen.
    /// Shared modes: any running launcher will do (all play the same
    /// content) — pick the first stable one.
    private func activeLauncherForProgress(screenUUID: String?) -> DesktopLauncher? {
        if let screenUUID, let launcher = desktopLauncherInstances[screenUUID], launcher.isRunning {
            return launcher
        }
        return desktopLauncherInstances.values.first(where: { $0.isRunning })
    }

    // MARK: - Occlusion Coordination

    /// Called by every `DesktopLauncher` when its `DesktopOcclusionMonitor`
    /// reports a coverage transition. Independent mode applies the change
    /// to just the changing launcher (matches the prior per-screen
    /// behaviour). Shared modes (spanned/cloned/mirrored) apply the
    /// aggregate to every running launcher so the whole logical surface
    /// pauses/resumes together — any covered screen pauses every screen.
    func occlusionDidChange(forScreenUUID uuid: String, isOccluded: Bool) {
        let oldAggregate = computeAggregateOcclusion()
        perScreenOcclusion[uuid] = isOccluded
        let newAggregate = computeAggregateOcclusion()

        if PrefsDisplays.viewingMode == .independent {
            guard let launcher = desktopLauncherInstances[uuid], launcher.isRunning else { return }
            if isOccluded { launcher.applyOcclusionPause() }
            else { launcher.applyOcclusionResume() }
            return
        }

        // Shared modes: only act when the aggregate flips. Otherwise a
        // single screen's coverage wiggle would re-ramp every screen on
        // each individual change.
        guard newAggregate != oldAggregate else { return }
        for (_, launcher) in desktopLauncherInstances where launcher.isRunning {
            if newAggregate { launcher.applyOcclusionPause() }
            else { launcher.applyOcclusionResume() }
        }
    }

    /// Used by the screensaver-handoff path to register a launcher's
    /// initial occlusion state without firing a pause/resume cascade.
    /// The handoff owns its own ramp; the manager just needs the
    /// bookkeeping to be correct so a subsequent `occlusionDidChange`
    /// call computes the right aggregate.
    func seedOcclusionState(forScreenUUID uuid: String, isOccluded: Bool) {
        perScreenOcclusion[uuid] = isOccluded
    }

    /// Effective occlusion state for a screen, accounting for viewing
    /// mode. Independent: that screen's stored value. Shared modes: the
    /// aggregate (any running screen occluded → true). Used by the
    /// screensaver-handoff path to decide its post-ramp paused-landing.
    func effectiveOcclusionState(for uuid: String) -> Bool {
        if PrefsDisplays.viewingMode == .independent {
            return perScreenOcclusion[uuid] ?? false
        }
        return computeAggregateOcclusion()
    }

    private func computeAggregateOcclusion() -> Bool {
        desktopLauncherInstances.contains { (uuid, launcher) in
            launcher.isRunning && (perScreenOcclusion[uuid] == true)
        }
    }

    /// The system pause reason to surface in UI (icon + text), nil when
    /// nothing holds playback or the user paused deliberately. Battery
    /// wins over thermal/camera/coverage (it's the stickier story).
    /// `screenUUID` scopes the coverage check (nil = shared surface).
    func pauseMention(for screenUUID: String?) -> (icon: String, text: String)? {
        guard isPlaying, !isPaused else { return nil }
        if isBatteryPaused {
            return ("battery.25percent", "Paused — on battery")
        }
        switch thermalPauseCause {
        case .thermalPressure:
            return ("thermometer.medium", "Paused — thermal pressure")
        case .lowPowerMode:
            return ("bolt.circle", "Paused — Low Power Mode")
        case nil:
            break
        }
        if isCameraPaused {
            return ("video.fill", "Paused — camera in use")
        }
        if effectiveOcclusionState(for: screenUUID ?? "") {
            return ("macwindow", "Paused — display covered")
        }
        return nil
    }

    // MARK: - State Updates (called from external sources)

    /// Called when window mode playback stops (e.g., window closed)
    func windowModeDidStop() {
        if playbackMode == .monitor {
            playbackMode = .none
            isPlaying = false
            isPaused = false
        }
    }

    /// Update the popover screen UUID based on the current key window's screen.
    func updatePopoverScreen() {
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            popoverScreenUUID = screen.screenUuid
        }
    }

    // MARK: - Private Helpers

    private func handleScreenConfigurationChange() {
        let currentScreenUuids = Set(NSScreen.screens.map { $0.screenUuid })
        let previousScreenUuids = Set(availableScreens.map { $0.uuid })

        // Skip if nothing actually changed (notification can fire for other reasons)
        guard currentScreenUuids != previousScreenUuids else {
            refreshScreenList()
            return
        }

        // --- Snapshot intent BEFORE cleanup ---
        // "All screens" intent = every previously-available screen was playing
        let wasAllScreensActive = playbackMode == .desktop
            && !previousScreenUuids.isEmpty
            && previousScreenUuids.isSubset(of: activeScreenUuids)

        // --- Handle disconnected screens ---
        let disconnectedUuids = activeScreenUuids.subtracting(currentScreenUuids)
        for uuid in disconnectedUuids {
            debugLog("🖥️ Screen disconnected: \(uuid)")
            if let launcher = desktopLauncherInstances[uuid] {
                launcher.cleanupForDisconnect()
            }
            desktopLauncherInstances.removeValue(forKey: uuid)
            // Forget any cached occlusion state for the gone screen.
            // Keeping a stale `true` here would freeze the remaining
            // launcher(s) paused indefinitely in shared viewing modes.
            perScreenOcclusion.removeValue(forKey: uuid)
            activeScreenUuids.remove(uuid)
            // NOTE: intentionally keep UUID in enabledWallpaperScreenUuids for reconnection
        }

        // Update playback state after disconnects
        if !disconnectedUuids.isEmpty {
            updatePlaybackModeFromActiveScreens()
        }

        // --- Handle newly connected screens ---
        let newScreenUuids = currentScreenUuids.subtracting(previousScreenUuids)
        if playbackMode == .desktop || wasAllScreensActive {
            for uuid in newScreenUuids {
                let wasEnabled = Preferences.enabledWallpaperScreenUuids.contains(uuid)
                if wasEnabled || wasAllScreensActive {
                    debugLog("🖥️ Screen connected, starting playback: \(uuid)")
                    toggleDesktopLauncher(for: uuid)
                } else {
                    debugLog("🖥️ Screen connected (not enabled for playback): \(uuid)")
                }
            }
        }

        // Log any connections that didn't trigger playback
        for uuid in newScreenUuids where !activeScreenUuids.contains(uuid) {
            debugLog("🖥️ Screen connected: \(uuid)")
        }

        // Catch enabled screens that are present in the OS but have no
        // launcher — handles the case where a prior orphan-detect dropped
        // a launcher and we need to recreate it.
        reconcileLaunchersWithScreens()

        // Refresh UI list last
        refreshScreenList()
    }

    /// Called by the orphan-detect notification from `AerialSaverView`. The
    /// view's window has settled on a screen whose UUID doesn't match the
    /// launcher's target; the launcher is misrouted and unrecoverable in
    /// place. Drop it cleanly; the deferred reconcile will rebuild once the
    /// OS's NSScreen / UUID mapping has stabilised. Intentionally does NOT
    /// touch `Preferences.enabledWallpaperScreenUuids` — the user still
    /// wants this screen running, we just need to retry the placement.
    private func handleLauncherOrphanDetected(uuid: String) {
        debugLog("🖥️ Launcher orphan detected for \(uuid) — tearing down and queueing reconcile")
        if let launcher = desktopLauncherInstances[uuid] {
            launcher.cleanupForDisconnect()
        }
        desktopLauncherInstances.removeValue(forKey: uuid)
        perScreenOcclusion.removeValue(forKey: uuid)
        activeScreenUuids.remove(uuid)

        // Defer the recreate so the OS has a chance to finish its display
        // reconfigure pass — if we recreate immediately while NSScreen state
        // is still volatile, the new launcher can land on the wrong screen
        // again, fire orphan-detect, and we loop. 0.5 s is enough to ride
        // out the typical hot-plug / lid-close transient without being
        // user-visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Task { @MainActor in
                self?.reconcileLaunchersWithScreens()
            }
        }
    }

    /// Walks `enabledWallpaperScreenUuids` and creates a launcher for any
    /// enabled screen that is currently present in `NSScreen.screens` but
    /// has no entry in `desktopLauncherInstances`. Idempotent — does
    /// nothing in the steady state where every enabled screen has a
    /// launcher. Called at the end of `handleScreenConfigurationChange`
    /// and from the deferred orphan-recovery path.
    private func reconcileLaunchersWithScreens() {
        guard playbackMode == .desktop else { return }
        let currentScreenUuids = Set(NSScreen.screens.map { $0.screenUuid })
        for uuid in Preferences.enabledWallpaperScreenUuids
            where currentScreenUuids.contains(uuid) && desktopLauncherInstances[uuid] == nil {
            debugLog("🖥️ Reconcile: \(uuid) is enabled and present but unattached — starting launcher")
            toggleDesktopLauncher(for: uuid)
        }
    }

    private func updateActiveScreens(_ uuid: String, isActive: Bool) {
        if isActive {
            activeScreenUuids.insert(uuid)
            if !Preferences.enabledWallpaperScreenUuids.contains(uuid) {
                Preferences.enabledWallpaperScreenUuids.append(uuid)
            }
        } else {
            activeScreenUuids.remove(uuid)
            Preferences.enabledWallpaperScreenUuids = Preferences.enabledWallpaperScreenUuids.filter { $0 != uuid }
        }
    }

    private func updatePlaybackModeFromActiveScreens() {
        if activeScreenUuids.isEmpty {
            playbackMode = .none
            isPlaying = false
            // Only a full stop clears the user pause. Resetting it on every
            // call silently dropped a held pause whenever a screen was
            // toggled, reconnected, or reconciled.
            isPaused = false
        } else {
            playbackMode = .desktop
            isPlaying = true
        }
    }

    private func updatePlaybackSpeed() {
        switch playbackMode {
        case .desktop:
            for launcher in desktopLauncherInstances.values where launcher.isRunning {
                launcher.changeSpeed(globalSpeed)
            }

        case .monitor:
            SaverLauncher.instance.changeSpeed(globalSpeed)

        case .none:
            break
        }
    }

    private func restoreActiveScreens() {
        for uuid in Preferences.enabledWallpaperScreenUuids {
            if NSScreen.getScreenByUuid(uuid) != nil {
                toggleDesktopLauncher(for: uuid)
            }
        }
    }
}

/// The 1 Hz playback-progress fraction, isolated from PlaybackManager.
/// As a @Published on the manager, every per-second progress tick
/// re-rendered EVERY observer of the whole object — including a closed
/// popover's still-alive hosting view (~5% CPU while playing). Only the
/// leaf progress bars (`PlaybackProgressBar`) observe this model.
@MainActor
final class PlaybackProgressModel: ObservableObject {
    static let shared = PlaybackProgressModel()

    /// Playback progress (0.0 to 1.0) for the current video.
    @Published fileprivate(set) var fraction: Double = 0.0

    private init() {}
}

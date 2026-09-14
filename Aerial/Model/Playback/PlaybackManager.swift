//
//  PlaybackManager.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//
//  macOS 15+ only. The live wallpaper (and the screensaver) is the
//  `Aerial4WallpaperExtension`, hosted by WallpaperAgent — the Companion
//  never plays video in-process. This manager is a thin controller over
//  the extension's control channel (`WallpaperControl`) plus a little
//  shared UI state (speed, popover screen, battery pause, progress).
//

import Foundation
import Combine
import AppKit

/// Central state manager for playback controls
@MainActor
class PlaybackManager: ObservableObject {

    // MARK: - Singleton

    static let shared = PlaybackManager()

    // MARK: - Published State

    /// User pause intent, mirrored from the extension control channel
    /// (`WallpaperControl.paused`) — static ↔ animated wallpaper.
    @Published private(set) var isPaused: Bool = WallpaperControl.shared.currentPaused

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
    /// Both causes ride the extension's single `.thermal` reason; the
    /// split only exists so the UI can say WHICH condition paused it.
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
            // Mirror to the wallpaper extension (no-op write when unchanged).
            WallpaperControl.shared.setSpeed(Self.rate(forGlobalSpeed: globalSpeed))
        }
    }

    /// Slider value → playback rate. The wallpaper extension maps the
    /// same way (see `WallpaperControlListener`).
    static func rate(forGlobalSpeed speed: Int) -> Double {
        switch speed {
        case 80: return 2.0 / 3.0
        case 60: return 0.5
        case 40: return 1.0 / 3.0
        case 20: return 0.25
        case 0:  return 0.125
        default: return 1.0
        }
    }

    /// Available screens with their UUIDs and names
    @Published private(set) var availableScreens: [ScreenInfo] = []

    /// UUID of the screen the popover is currently displayed on
    @Published private(set) var popoverScreenUUID: String? = nil

    // MARK: - Types

    struct ScreenInfo: Identifiable, Equatable {
        let uuid: String
        let name: String
        let width: CGFloat
        let height: CGFloat
        let isMain: Bool
        var id: String { uuid }
        var aspect: CGFloat { height > 0 ? width / height : 16.0 / 9.0 }
    }

    /// Effective screen UUID for playlist queries — non-nil only in independent mode.
    var effectiveScreenUUID: String? {
        guard PrefsDisplays.viewingMode == .independent else { return nil }
        return popoverScreenUUID
    }

    // MARK: - Private Properties

    /// 1 Hz timer that refreshes `playbackProgress` for the popover's
    /// thumbnail progress bar from `PlaylistManager`'s persisted timestamp
    /// (the extension owns the live position; we observe it). Trivial cost,
    /// so we leave it running always.
    private var progressTimer: DispatchSourceTimer?
    /// `status.lastSeen` at the last progress recompute — lets the 1 Hz
    /// tick skip work while everything is paused AND the extension has
    /// written nothing new (a jump-while-paused writes status, so the
    /// bar still updates within a tick).
    private var progressStatusSeen: Date?

    /// 60s wall-clock check for the auto-advance cadence (running only
    /// while the setting is on). A wall-clock deadline instead of an
    /// exact-interval timer makes sleep self-healing: an advance that came
    /// due during sleep fires once on the first tick after wake.
    private var autoAdvanceTimer: Timer?
    /// Last moment the countdown (re)started: an auto or manual video
    /// change, or a settings change. The next auto-advance is due
    /// `desktopAutoAdvanceMinutes` after this.
    private var lastAutoAdvanceReset = Date()

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private init() {
        self.globalSpeed = Preferences.globalSpeed
        refreshScreenList()
        startProgressTimer()
        reevaluateAutoAdvance()

        // Listen for screen configuration changes (UI list only — the
        // extension handles its own per-display reconfigure).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshScreenList()
            }
        }

        // Keep `isPaused` in sync with the extension's authoritative pause
        // intent whenever the status channel updates.
        WallpaperStatusMonitor.shared.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isPaused = WallpaperControl.shared.currentPaused
            }
            .store(in: &cancellables)

        // Battery-aware pause: subscribe to power-source change events,
        // re-evaluate on system wake (macOS can change battery state
        // during sleep without firing the IOPS callback), and check
        // initial state so a launch-on-battery doesn't play for a few
        // seconds before the first transition.
        setupBatteryMonitor()
        setupThermalMonitor()
        setupCameraMonitor()

        // (The old `com.glouel.aerial.nextvideo` distributed-notification
        // observer died with the AVPlayer screensaver stack — nothing
        // posts it. Organic video changes now arrive via the status
        // channel: WallpaperStatusMonitor → applyExtensionNowPlaying.)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        progressTimer?.cancel()
        autoAdvanceTimer?.invalidate()
    }

    // MARK: - Screen Management

    /// Refresh the list of available screens
    func refreshScreenList() {
        availableScreens = NSScreen.screens.map { screen in
            ScreenInfo(uuid: screen.screenUuid,
                       name: screen.localizedName,
                       width: screen.frame.width,
                       height: screen.frame.height,
                       isMain: screen.frame.origin == .zero)
        }
    }

    // MARK: - Start Actions

    /// Start the screensaver immediately (the OS screensaver, which on
    /// macOS 15+ renders Aerial via the wallpaper extension's idle mode).
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

    // MARK: - Playback Controls

    /// Toggle pause/resume of the wallpaper extension (static ↔ animated).
    func togglePause() {
        // Click while battery-paused = "play despite battery". Clear
        // the battery flag, set an override that survives until the
        // next plug-in, and also clear any user-pause so a single
        // click reads as expected ("hit play, get video").
        if isBatteryPaused {
            debugLog("🔋 User overrode battery-pause via popover button")
            batteryOverrideForThisCycle = true
            isPaused = false
            applyBatteryStateChange(paused: false)
            WallpaperControl.shared.setPaused(false)
            return
        }

        // Same deal for a thermal/Low Power Mode pause: hitting play
        // means "play despite the condition" for this episode.
        if isThermalPaused {
            debugLog("🌡️ User overrode thermal-pause via popover button")
            thermalOverrideForThisCycle = true
            isPaused = false
            applyThermalStateChange(cause: nil)
            WallpaperControl.shared.setPaused(false)
            return
        }

        // And for a camera pause: play despite the running camera.
        if isCameraPaused {
            debugLog("📷 User overrode camera-pause via popover button")
            cameraOverrideForThisCycle = true
            isPaused = false
            applyCameraStateChange(paused: false)
            WallpaperControl.shared.setPaused(false)
            return
        }

        // Base the new state on the extension's authoritative value, not
        // the possibly-stale local mirror.
        let newPaused = !WallpaperControl.shared.currentPaused
        isPaused = newPaused
        WallpaperControl.shared.setPaused(newPaused)
    }

    /// Advance to the next entry. No-arg variant targets the popover's
    /// effective screen; the `screenUUID:` variant lets a Dashboard
    /// mini-player drive its own display (`nil` = shared playback).
    func nextVideo() {
        nextVideo(screenUUID: effectiveScreenUUID)
    }

    func nextVideo(screenUUID: String?) {
        WallpaperControl.shared.advanceVideo(screenUUID: screenUUID)
    }

    /// Step back to the previous entry (the extension uses the dedicated
    /// backward-scan path that honours time-of-day filters).
    func previousVideo() {
        previousVideo(screenUUID: effectiveScreenUUID)
    }

    func previousVideo(screenUUID: String?) {
        WallpaperControl.shared.regressVideo(screenUUID: screenUUID)
    }

    /// Jump to a specific playlist entry on the appropriate screen(s).
    func skipTo(playlistIndex: Int, screenUUID: String?) {
        WallpaperControl.shared.jumpToVideo(index: playlistIndex, screenUUID: screenUUID)
    }

    // MARK: - Auto-Advance

    /// (Re)start or stop the auto-advance countdown from the current
    /// settings. Called at init and from the settings UI — any change
    /// (enable, cadence) restarts the countdown, so enabling never
    /// advances instantly.
    func reevaluateAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
        guard Preferences.desktopAutoAdvance else { return }
        lastAutoAdvanceReset = Date()
        autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.autoAdvanceTick()
            }
        }
    }

    /// Restart the countdown — any video change (manual next/previous,
    /// playlist jump, or the auto-advance itself) counts as "the video
    /// just changed". `WallpaperControl` calls this from its navigation
    /// entry points.
    func noteVideoChanged() {
        lastAutoAdvanceReset = Date()
    }

    private func autoAdvanceTick() {
        // Dark wakes run timers too — never advance while asleep.
        guard !SystemSleepState.shared.isAsleep else { return }
        let interval = Double(Preferences.desktopAutoAdvanceMinutes) * 60
        guard Date().timeIntervalSince(lastAutoAdvanceReset) >= interval else { return }
        // One advance per tick, however overdue — a long sleep shouldn't
        // fast-forward the playlist.
        lastAutoAdvanceReset = Date()
        debugLog("⏭ Auto-advance: \(Preferences.desktopAutoAdvanceMinutes)min elapsed, advancing all screens")
        WallpaperControl.shared.advanceVideo(screenUUID: nil)
    }

    /// Re-apply playback after a settings/playlist change. The extension
    /// reloads on its own when the playlist generation or display config
    /// bumps (callers always pair this with `PlaylistManager.regenerate`
    /// or `WallpaperControl.displaysConfigDidChange`), so this is a no-op
    /// kept for call-site compatibility.
    func refreshPlayback() {}
    func refreshPlayback(for screenUUID: String) {}

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

    /// Route battery pause to the wallpaper extension through the control
    /// channel's dedicated battery flag — separate from the user's
    /// static/animated `paused` intent.
    private func applyBatteryStateChange(paused: Bool) {
        isBatteryPaused = paused
        debugLog("🔋 PlaybackManager: isBatteryPaused = \(paused)")
        WallpaperControl.shared.setBatteryPaused(paused)
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
                debugLog("🌡️ Pausing wallpaper: \(cause == .thermalPressure ? "thermal state \(thermalState.rawValue)" : "Low Power Mode")")
            }
            applyThermalStateChange(cause: cause)
        }
    }

    /// Route thermal/LPM pause to the wallpaper extension through the
    /// control channel's dedicated thermal flag.
    private func applyThermalStateChange(cause: ThermalPauseCause?) {
        thermalPauseCause = cause
        debugLog("🌡️ PlaybackManager: isThermalPaused = \(cause != nil)")
        WallpaperControl.shared.setThermalPaused(cause != nil)
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

    /// Route camera pause to the wallpaper extension through the control
    /// channel's dedicated camera flag.
    private func applyCameraStateChange(paused: Bool) {
        isCameraPaused = paused
        debugLog("📷 PlaybackManager: isCameraPaused = \(paused)")
        WallpaperControl.shared.setCameraPaused(paused)
    }

    // MARK: - Playback Progress

    /// Start the 1 Hz timer that pushes `playbackProgress` updates into
    /// the popover's thumbnail progress bar. Called from `init` and runs
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

    /// Recompute the current playback fraction (0...1) from the last
    /// persisted timestamp (`PlaylistManager.currentPlaybackTimestamp`),
    /// which the extension keeps current. When duration is unknown or
    /// zero (e.g. live streams), progress is reported as 0 — the bar
    /// then hides. Only assigns when the value moves by >~0.5 % to avoid
    /// pointless SwiftUI re-renders.
    @MainActor
    private func refreshPlaybackProgress() {
        // Visibility gate: the progress bars live in the popover and in
        // the Video Library's Home cards. A CLOSED popover's hosting view
        // stays alive — publishing into it re-rendered the whole
        // invisible tree every second. On reopen the next tick heals the
        // bar (the extension's 30 s heartbeat guarantees the status gate
        // below re-opens).
        guard PopoverVisibility.shared.isShown
                || AppPresentationController.shared.isLibraryWindowVisible else { return }

        // Idle gate: with every renderer at rate 0 the interpolation
        // can't move, so only recompute when the extension has written
        // a fresh status since the last pass (video change, reconcile,
        // 30 s heartbeat). Playing (any nonzero rate) recomputes every
        // tick as before.
        let gateStatus = WallpaperStatusMonitor.shared.status
        let anyPlaying = gateStatus.map { !$0.nowPlayingRate.values.allSatisfy { $0 == 0 } } ?? false
        if !anyPlaying && gateStatus?.lastSeen == progressStatusSeen {
            return
        }
        progressStatusSeen = gateStatus?.lastSeen

        let screenUUID = effectiveScreenUUID
        let progress: Double = {
            guard let video = PlaylistManager.shared.currentVideo(for: screenUUID),
                  video.duration > 0 else {
                return 0
            }
            // Interpolate from the extension's status echo: position at
            // `lastSeen` + elapsed × timebase rate. The rate is the real
            // slope (0 when paused, 1.0 in saver mode, nominal
            // otherwise) and the basis refreshes on every video change,
            // reconcile, and 30 s periodic write — a live bar with no
            // per-second IPC.
            let monitor = WallpaperStatusMonitor.shared
            let key = screenUUID ?? "broadcast"   // extension's shared-renderer key
            if monitor.isRunning,
               let status = monitor.status,
               let basis = status.nowPlayingPosition[key],
               Date().timeIntervalSince(status.lastSeen) < 45 {
                let rate = status.nowPlayingRate[key] ?? 0
                let position = basis + Date().timeIntervalSince(status.lastSeen) * rate
                return max(0, min(1, position / video.duration))
            }
            // Fallback (older extension build / extension not running):
            // the persisted playlist timestamp — static, but honest.
            let position = PlaylistManager.shared.currentPlaybackTimestamp(for: screenUUID) ?? 0
            return max(0, min(1, position / video.duration))
        }()
        if abs(progress - PlaybackProgressModel.shared.fraction) > 0.005 {
            PlaybackProgressModel.shared.fraction = progress
        }
    }

    /// The system pause reason to surface in UI (icon + text), nil when
    /// nothing holds playback or the user paused deliberately. One
    /// source of truth for the Dashboard cards and the popover —
    /// battery wins over thermal/camera/coverage (it's the stickier
    /// story). `screenUUID` scopes the coverage check (nil = shared).
    func pauseMention(for screenUUID: String?) -> (icon: String, text: String)? {
        guard WallpaperStatusMonitor.shared.isRunning, !isPaused else { return nil }
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
        if isCoveragePaused(for: screenUUID) {
            return ("macwindow", "Paused — display covered")
        }
        return nil
    }

    /// Whether playback on this scope is currently auto-paused because the
    /// desktop is covered by a window. `nil` = the shared surface (any
    /// covered screen). Sourced from the extension's status channel
    /// (`WallpaperAutoPauseCoordinator` drives the flags).
    func isCoveragePaused(for screenUUID: String?) -> Bool {
        guard let auto = WallpaperStatusMonitor.shared.status?.autoPausedScreens,
              !auto.isEmpty else { return false }
        if let uuid = screenUUID { return auto.contains(uuid) }
        return true
    }

    // MARK: - State Updates (called from external sources)

    /// Scope the popover to the display it opened on (where the menu-bar
    /// item was clicked) so independent mode reflects/controls that
    /// display. `preferredScreen` is the status-item button's window
    /// screen; fall back to the display under the pointer, then main.
    func updatePopoverScreen(preferredScreen: NSScreen? = nil) {
        let screen = preferredScreen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        if let screen {
            popoverScreenUUID = screen.screenUuid
        }
    }
}

/// The 1 Hz playback-progress fraction, isolated from PlaybackManager.
/// As a @Published on the manager, every per-second progress tick
/// re-rendered EVERY observer of the whole object — including a closed
/// popover's still-alive hosting view (~5% CPU while playing,
/// 2026-07-24 sample). Only the leaf progress bars
/// (`PlaybackProgressBar`) observe this model.
@MainActor
final class PlaybackProgressModel: ObservableObject {
    static let shared = PlaybackProgressModel()

    /// Playback progress (0.0 to 1.0) for the current video.
    @Published fileprivate(set) var fraction: Double = 0.0

    private init() {}
}

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

    /// Global playback speed (0-100, maps to slider values)
    @Published var globalSpeed: Int {
        didSet {
            Preferences.globalSpeed = globalSpeed
            updatePlaybackSpeed()
        }
    }

    /// Set of screen UUIDs that have active desktop wallpaper
    @Published private(set) var activeScreenUuids: Set<String> = []

    /// Playback progress (0.0 to 1.0) for current video
    @Published private(set) var playbackProgress: Double = 0.0

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
    private var perScreenOcclusion: [String: Bool] = [:]

    // MARK: - Initialization

    private init() {
        self.globalSpeed = Preferences.globalSpeed
        refreshScreenList()

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
        isPaused.toggle()
        let newPaused = isPaused

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

        // Refresh UI list last
        refreshScreenList()
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
        } else {
            playbackMode = .desktop
            isPlaying = true
        }
        isPaused = false
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

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
/// Replaces the state management previously in CompanionPopoverViewController
@available(macOS 11.0, *)
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

    /// Whether an update is available
    @Published var hasUpdate: Bool = false

    /// Available screens with their UUIDs and names
    @Published private(set) var availableScreens: [ScreenInfo] = []

    // MARK: - Types

    struct ScreenInfo: Identifiable, Equatable {
        let uuid: String
        let name: String
        var id: String { uuid }
    }

    // MARK: - Private Properties

    /// Desktop launcher instances keyed by screen UUID
    private var desktopLauncherInstances: [String: DesktopLauncher] = [:]

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
                self?.refreshScreenList()
            }
        }

        // Restore active screens on launch if preference is enabled
        if Preferences.restartBackground {
            restoreActiveScreens()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Screen Management

    /// Refresh the list of available screens
    func refreshScreenList() {
        availableScreens = NSScreen.screens.map { screen in
            let name: String
            if #available(macOS 10.15, *) {
                name = screen.localizedName
            } else {
                name = screen.displayName
            }
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
        // Use private API via dlopen (existing pattern from CompanionPopoverViewController)
        if let libHandle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY) {
            let sym = dlsym(libHandle, "SACScreenSaverStartNow")
            typealias myFunction = @convention(c) () -> Void
            let SACLockScreenImmediate = unsafeBitCast(sym, to: myFunction.self)
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
        switch playbackMode {
        case .desktop:
            for launcher in desktopLauncherInstances.values where launcher.isRunning {
                launcher.togglePause()
            }

        case .monitor:
            SaverLauncher.instance.togglePause()

        case .none:
            break
        }

        isPaused.toggle()
    }

    /// Skip to next video
    func skip() {
        switch playbackMode {
        case .desktop:
            for launcher in desktopLauncherInstances.values where launcher.isRunning {
                launcher.nextVideo()
            }

        case .monitor:
            SaverLauncher.instance.nextVideo()

        case .none:
            break
        }
    }

    /// Skip and hide current video (won't be shown again)
    func hide() {
        switch playbackMode {
        case .desktop:
            for launcher in desktopLauncherInstances.values where launcher.isRunning {
                launcher.skipAndHide()
            }

        case .monitor:
            SaverLauncher.instance.skipAndHide()

        case .none:
            break
        }
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

    // MARK: - State Updates (called from external sources)

    /// Called when window mode playback stops (e.g., window closed)
    func windowModeDidStop() {
        if playbackMode == .monitor {
            playbackMode = .none
            isPlaying = false
            isPaused = false
        }
    }

    /// Called when settings panel closes
    func settingsDidClose() {
        refreshPlayback()
    }

    // MARK: - Private Helpers

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

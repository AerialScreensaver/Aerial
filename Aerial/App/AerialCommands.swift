//
//  AerialCommands.swift
//  Aerial Companion
//
//  The app's main menu. It is only VISIBLE in the Dock presentation (an
//  accessory app has no menu bar), but its key equivalents — ⌘, ⌘Q ⌘W
//  and the Playback shortcuts — work in both presentations whenever one
//  of our windows is key.
//
//  Replaces the stock storyboard menu that shipped (unused) since the
//  AerialUpdater days.
//

import Combine
import SwiftUI

struct AerialCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Aerial menu
        CommandGroup(replacing: .appInfo) {
            Button("About Aerial") {
                AppPresentationController.shared.showAbout()
            }
        }
        CommandGroup(after: .appInfo) {
            CheckForUpdatesMenuItem()
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                SettingsWindowController.show(via: openWindow)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        // Playback menu
        CommandMenu("Playback") {
            PlaybackMenuItems()
        }

        // Help menu
        CommandGroup(replacing: .help) {
            Button("Aerial Website") {
                NSWorkspace.shared.open(AboutContent.AboutLinks.website)
            }
            Button("Aerial Discord") {
                NSWorkspace.shared.open(AboutContent.AboutLinks.discord)
            }
            Divider()
            Button("What's New in Aerial…") {
                ReleaseNotesWindowController.show()
            }
            Button("Export Diagnostics…") {
                DiagnosticsExporter.exportInteractively()
            }
        }
    }
}

// MARK: - Check for Updates

/// Mirrors Sparkle's `canCheckForUpdates` KVO flag for the menu item's
/// enabled state (same publisher `AutoUpdatesPanel` uses).
final class UpdaterMenuState: ObservableObject {
    static let shared = UpdaterMenuState()

    @Published private(set) var canCheckForUpdates = false
    private var cancellable: AnyCancellable?

    private init() {
        guard let updater = AppDelegate.shared?.sparkleController.updater else { return }
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }
}

private struct CheckForUpdatesMenuItem: View {
    @ObservedObject private var state = UpdaterMenuState.shared

    var body: some View {
        Button("Check for Updates…") {
            AppDelegate.shared?.sparkleController.updater.checkForUpdates()
        }
        .disabled(!state.canCheckForUpdates)
    }
}

// MARK: - Playback

/// Menu-item state for the Playback menu. Deliberately does NOT touch
/// `PlaybackManager.shared` / `WallpaperStatusMonitor.shared` at
/// construction: SwiftUI builds the main menu while the app is still
/// launching — before `UnifiedPaths.ensureBaseDirectory()` and the
/// first-launch wizard — and those singletons read/write the shared
/// Aerial directory at init. `bind()` runs once startup reaches
/// `AppPresentationController.installSurfaces()`; until then the
/// transport items are simply disabled.
final class PlaybackMenuModel: ObservableObject {
    static let shared = PlaybackMenuModel()

    @Published private(set) var isPaused = false
    @Published private(set) var isRunning = false
    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    @MainActor
    func bind() {
        guard cancellables.isEmpty else { return }
        PlaybackManager.shared.$isPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isPaused = $0 }
            .store(in: &cancellables)
        WallpaperStatusMonitor.shared.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isRunning = $0 }
            .store(in: &cancellables)
    }
}

/// Same calls as the global hotkeys and the Dock menu — the no-arg
/// `PlaybackManager` transport, so all three share scope semantics.
private struct PlaybackMenuItems: View {
    @ObservedObject private var model = PlaybackMenuModel.shared

    var body: some View {
        Button(model.isPaused ? "Resume Wallpaper" : "Pause Wallpaper") {
            PlaybackManager.shared.togglePause()
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(!model.isRunning)

        Button("Next Video") {
            PlaybackManager.shared.nextVideo()
        }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
        .disabled(!model.isRunning)

        Button("Previous Video") {
            PlaybackManager.shared.previousVideo()
        }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
        .disabled(!model.isRunning)

        Divider()

        Button("Start Screensaver") {
            PlaybackManager.shared.startScreensaver()
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])

        Divider()

        Button("Open Video Library") {
            AppPresentationController.shared.openVideoLibrary(reason: "menu")
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}

//
//  AppDelegate.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 24/07/2020.
//

import Cocoa
import Sparkle
import SwiftUI

enum IconMode {
    case normal, updating, notification
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    let popover = NSPopover()

    private var downloadDot: NSView?

    // Sparkle
    let sparkleGentleDelegate = SparkleGentleDelegate()
    var sparkleController : SPUStandardUpdaterController

    override init() {
        sparkleController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: sparkleGentleDelegate, userDriverDelegate: sparkleGentleDelegate)
        super.init()
        AppDelegate.shared = self

        LogBridge.configure(AerialLogger(config: LoggerConfiguration(
            logFileName: "app.txt",
            supportPath: { UnifiedPaths.logsPath() },
            category: "Companion"
        )))
    }
    
    // MARK: - Lifecycle
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments

        // Migration + first-launch wizard are now consolidated into a
        // single window — `FirstLaunchWizardView` starts on a Welcome
        // step that lets the user opt into (or skip) the legacy probe.
        // Calling `PathMigration.needsMigration()` here would fire the
        // macOS file-access TCC prompt before any UI is visible, so we
        // gate ONLY on `FirstLaunch.shouldShowWizard` (which checks
        // `firstLaunchCompleted` and never touches the legacy path).
        // The wizard itself probes only after the user clicks "Go ahead".
        if FirstLaunch.shouldShowWizard {
            debugLog("First launch / migration wizard needed")
            runFirstLaunchWizard { [weak self] in
                self?.continueStartup()
            }
            return
        }

        // No migration, no wizard — continue with normal startup
        continueStartup()
    }

    /// Show the unified setup wizard (which handles container migration
    /// as step 0 when needed). Blocks startup until the user finishes.
    private func runFirstLaunchWizard(_ then: @escaping () -> Void) {
        let controller = FirstLaunchWizardWindowController()
        controller.windowDidLoad()
        controller.showModal {
            debugLog("First-launch wizard complete, continuing startup")
            then()
        }
    }

    private func continueStartup() {
        // CRITICAL: Initialize unified path FIRST, before any file operations
        guard UnifiedPaths.ensureBaseDirectory() else {
            // Fatal error - cannot continue without proper directory structure
            // Error dialog has already been shown by UnifiedPaths
            NSApplication.shared.terminate(self)
            return
        }

        // One-time cleanup of legacy LaunchAgent plist and UserDefaults keys
        LaunchAgent.removeLegacyAgentIfNeeded()
        cleanupLegacyUserDefaults()

        // One-time cleanup of obsolete `{id}-large.jpg` thumbnails
        // (pre-single-file refactor). Idempotent — once the directory
        // is clean, subsequent launches do nothing.
        Thumbnails.cleanupLegacyLargeFiles()

        // Ensure the default "My Videos" source is created and enabled
        SourceList.ensureDefaultLocalSource()

        // Regenerate the "Live Feeds" source folder from live-feeds.json.
        // Safe when there are no feeds — writes an empty manifest and lets
        // the source sit dormant until the user adds something.
        LiveFeedsSourceSync.shared.syncFromManager()

        // Kick off a resolution pass for any YouTube feeds whose cached
        // HLS URL has expired. Fires and forgets — updates propagate via
        // LiveFeedManager.updateResolution when they come back.
        LiveFeedResolver.shared.resolveAllIfNeeded()

        // Backfill thumbnails for any feeds that don't have one yet
        // (e.g. first run after upgrading to a build that added them).
        for feed in LiveFeedManager.shared.allFeeds() {
            LiveFeedThumbnailer.shared.ensureThumbnail(for: feed)
        }

        // Check if we're running under Companion (affects logging paths for screensaver code)
        Aerial.helper.checkCompanion()

        // Start location provider if any overlay or time mode needs coordinates
        LocationProvider.shared.startIfNeeded()

        // Start now-playing coordinator for music overlays
        NowPlayingCoordinator.shared.startIfNeeded()

        // Wire willSleep observer for the wallpaper-continuity feature.
        // No-op at runtime when Preferences.replaceWallpaper is OFF.
        WallpaperContinuity.shared.start()

        // Register system-wide hotkeys when the master pref is on.
        // Idempotent — same call fires from the toggle's onChange.
        GlobalShortcutsManager.refresh()

        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        debugLog("Version \(Helpers.version) (\(build)) launched on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        // Ensure not in bundle
        ensureNotInBundle()

        // Clean up mistaken folder from 3.9.9alpha2
        checkAndCleanupMistakenFolder()

        if !Preferences.restartBackground {
            Preferences.enabledWallpaperScreenUuids = []
        }

        // Start Sparkle updater explicitly so we can catch and log errors
        do {
            try sparkleController.updater.start()
            debugLog("Sparkle updater started successfully")
        } catch {
            errorLog("Sparkle updater failed to start: \(error)")
        }

        // Set the icon
        setIcon(mode: .normal)

        setupPopover()

        // Action button
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            // VoiceOver: announce as "Aerial" when the user walks the
            // menu bar instead of the SF Symbol's accessibility name.
            button.setAccessibilityLabel("Aerial")
        }

        // Install playlist manager override once VideoList is loaded
        VideoList.instance.addCallback {
            PlaylistManager.shared.installVideoOverride()

            // Fresh-install bootstrap: on the first run the persisted
            // `newShouldPlayString` is `[]`, which the filter treats as
            // "nothing selected" and yields an empty playlist. The popover's
            // onChange handler already bounces empty → "all" on user action,
            // but it never fires on initial mount. Populate the default
            // selection here so the persisted state matches what "All" looks
            // like in the UI.
            Self.bootstrapDefaultSelectionIfNeeded()

            // Only regenerate filter-based playlists; preserve active user playlists
            if !PlaylistManager.shared.isUserPlaylistActive(for: nil) {
                PlaylistManager.shared.regenerate()
            }
            if PrefsDisplays.viewingMode == .independent {
                for screen in NSScreen.screens {
                    let uuid = screen.screenUuid
                    if !PlaylistManager.shared.isUserPlaylistActive(for: uuid) {
                        PlaylistManager.shared.regenerate(for: uuid)
                    }
                }
            }
            // Trigger download evaluation — critical for fresh installs where no
            // videos are cached yet. Uses the existing debounced path.
            DownloadCoordinator.shared.selectionDidChange()

            // Sweep .mov files in /Cache/ whose filename is not referenced by
            // any current manifest. Runs at launch and after every manifest
            // refresh (same callback channel), gated by an idempotency check
            // so consecutive callbacks don't re-walk the directory.
            // VideoList delivers callbacks via OperationQueue.main, so the
            // MainActor hop is just a type-system formality.
            MainActor.assumeIsolated {
                CacheOrphanReaper.shared.maybeReap()
            }
        }

        // Initialize DownloadTracker and observe download state for menubar badge
        _ = DownloadTracker.shared
        _ = DownloadCoordinator.shared
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDownloadingDidChange(_:)),
            name: DownloadTracker.isDownloadingDidChangeNotification,
            object: nil
        )
    }
    
    // MARK: - Bootstrap Helpers

    /// Populate `newShouldPlayString` with every source of the current filter
    /// mode when it is empty. This is the "Locations > All" default state the
    /// popover shows after a fresh install, but there's no persisted selection
    /// yet — so the filter matches nothing and the playlist comes up empty.
    /// Skipped for `.favorites` (empty is the legitimate default there).
    private static func bootstrapDefaultSelectionIfNeeded() {
        guard PrefsVideos.newShouldPlayString.isEmpty else { return }
        let mode = PrefsVideos.newShouldPlay
        let filterMode: VideoList.FilterMode
        switch mode {
        case .location: filterMode = .location
        case .time:     filterMode = .time
        case .scene:    filterMode = .scene
        case .source, .expansions: filterMode = .source
        case .favorites, .liveFeeds: return
        }
        let sources = VideoList.instance.getSources(mode: filterMode)
        guard !sources.isEmpty else { return }
        let prefix = String(describing: filterMode) + ":"
        PrefsVideos.newShouldPlayString = sources.map { prefix + $0 }
        debugLog("🚀 bootstrap: populated newShouldPlayString with \(sources.count) \(prefix) entries")
    }

    // MARK: - Popover Setup

    private func setupPopover() {
        setupSwiftUIPopover()

        // Common popover configuration
        popover.behavior = .transient
        popover.animates = false  // Disable animation for instant opening
    }

    private func setupSwiftUIPopover() {
        let playbackManager = PlaybackManager.shared

        let popoverView = MainPopoverView(
            playbackManager: playbackManager,
            onOpenVideoBrowser: { [weak self] in
                // The Video Library window is opened directly from
                // `BottomBarView` via `@Environment(\.openWindow)` —
                // we just need to dismiss the popover here.
                self?.closePopover(sender: nil)
            },
            onOpenCompanionSettings: { [weak self] in
                // The Settings window is opened directly from
                // `BottomBarView` via `@Environment(\.openWindow)` —
                // we just need to dismiss the popover here.
                self?.closePopover(sender: nil)
            },
            onOpenInfo: { [weak self] in
                self?.openInfoWindow()
                self?.closePopover(sender: nil)
            },
            onExit: {
                NSApplication.shared.terminate(nil)
            },
            onDismiss: { [weak self] in
                self?.closePopover(sender: nil)
            },
            onSetAsDefault: {
                await AerialPluginManager.shared.enableScreensaver()
            }
        )

        let hostingController = NSHostingController(rootView: popoverView)
        popover.contentViewController = hostingController
    }

    // MARK: - Popover Handling

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover(sender: sender)
        } else {
            showPopover(sender: sender)
        }
    }

    func showPopover(sender: Any?) {
        if let button = statusItem.button {
            // Refresh content before showing
            Task { @MainActor in
                PlaybackManager.shared.refreshScreenList()
            }

            popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)

            Task { @MainActor in
                PlaybackManager.shared.updatePopoverScreen()
            }
        }
    }

    func closePopover(sender: Any?) {
        popover.performClose(sender)
    }

    // MARK: - Window Actions (for SwiftUI callbacks)

    private lazy var infoWindowController = InfoWindowController()

    private func openInfoWindow() {
        infoWindowController.showAboutWindow()
    }

    func checkAndCleanupMistakenFolder() {
        let mistakenPath = NSHomeDirectory().appending("/Library/Application Support/Aerial")

        if FileManager.default.fileExists(atPath: mistakenPath) {
            debugLog("Found mistaken folder from 3.9.9alpha2 at \(mistakenPath)")

            NSApp.activate(ignoringOtherApps: true)
            let result = Helpers.showAlert(
                question: "Oops",
                text: "version 3.9.9alpha2 put some files in the wrong place in your Application Support directory, do you want me to remove them? You can also do that manually if you prefer.",
                button1: "Yes, remove them",
                button2: "No, I'll do it manually"
            )

            if result {
                debugLog("User chose to remove mistaken folder")
                do {
                    try FileManager.default.removeItem(at: URL(fileURLWithPath: mistakenPath))
                    debugLog("Successfully removed mistaken folder")
                } catch {
                    errorLog("Failed to remove mistaken folder: \(error)")
                    Helpers.showErrorAlert(
                        question: "Cleanup Failed",
                        text: "Could not remove the folder at ~/Library/Application Support/Aerial. You may need to delete it manually.\n\nError: \(error.localizedDescription)"
                    )
                }
            } else {
                debugLog("User chose to manually remove mistaken folder")
            }
        }
    }
    
    func ensureNotInBundle() {
        do {
            let info = try Bundle.main.bundleURL.resourceValues(forKeys: [.volumeNameKey])
            if let volume = info.volumeName {
                if volume.starts(with: "Aerial") {
                    Helpers.showErrorAlert(question: "Oops", text: "Aerial can only be run from the Applications folder. Drag Aerial to Applications, then open Applications and run it again.", button: "Ok")
                    
                    NSApplication.shared.terminate(self)
                }
            }
        } catch {
            errorLog("Ensure bundle error")
        }
    }
    
    private func cleanupLegacyUserDefaults() {
        let legacyKeys = [
            "enabledWallpaperScreenUuids",
            "firstTimeSetup",
            "intLaunchMode",
            "intUpdateMode",
            "wasRunningBackground",
            "debugMode",
            "restartBackground",
            "globalSpeed",
            "intDesiredVersion",
        ]
        let defaults = UserDefaults.standard
        for key in legacyKeys {
            defaults.removeObject(forKey: key)
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Remember if desktop wallpaper was running for restart
        Preferences.wasRunningBackground = PlaybackManager.shared.playbackMode == .desktop

        // Shut down every ffmpeg child + the loopback HTTP server so we
        // don't leak subprocesses. Swift's Process doesn't propagate
        // termination automatically.
        LiveFeedTransmuxerManager.shared.stopAll()
    }
    
    // MARK: - Download Badge

    @objc private func handleDownloadingDidChange(_ notification: Notification) {
        let isDownloading = (notification.object as? Bool) ?? false
        DispatchQueue.main.async {
            self.showDownloadBadge(isDownloading)
        }
    }

    private func showDownloadBadge(_ show: Bool) {
        if show {
            guard downloadDot == nil, let button = statusItem.button else { return }
            let dot = NSView(frame: NSRect(x: button.bounds.width - 10, y: 1, width: 9, height: 9))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            dot.layer?.cornerRadius = 4.5
            button.addSubview(dot)
            downloadDot = dot
        } else {
            downloadDot?.removeFromSuperview()
            downloadDot = nil
        }
    }

    // Change the icon based on status
    func setIcon(mode: IconMode) {
        
        DispatchQueue.main.async {
            print("setIcon \(mode)")
            switch mode {
            case .normal:
                self.statusItem.image = NSImage(named: "Status48")
            case .updating:
                self.statusItem.image = NSImage(named: "StatusTransp48")
            case .notification:
                self.statusItem.image = NSImage(named: "Status48Attention")
            }
            
            self.statusItem.image?.size.width = 17
            self.statusItem.image?.size.height = 17
        }
    }
    
}


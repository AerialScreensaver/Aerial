//
//  AppDelegate.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 24/07/2020.
//

import Cocoa
import Sparkle
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!

    /// Menu bar vs Dock — status item, popover, activation policy,
    /// Dock menu and window presentation all live there.
    private var presentation: AppPresentationController { AppPresentationController.shared }

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

    /// Earliest hook: the Dock presentation switches the LSUIElement app
    /// to `.regular` BEFORE AppKit finishes launching, so the Dock icon
    /// and main menu come up cleanly (doing it later needs an activation
    /// bounce). Verified forwarded by the SwiftUI adaptor via the log line.
    func applicationWillFinishLaunching(_ notification: Notification) {
        presentation.applyLaunchPolicy(phase: "willFinishLaunching")
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Launch Apple event inspection must precede anything that spins
        // the run loop; the policy call is a no-op when the earlier hook
        // already ran.
        presentation.noteLaunchContext()
        presentation.applyLaunchPolicy(phase: "didFinishLaunching")

        // Single-instance, newest wins: the login item and an Xcode run
        // CAN coexist (Xcode spawns the binary directly, bypassing
        // LaunchServices dedup) — two instances mean two control-channel
        // writers with independent version counters fighting over the
        // extension. Terminate the older instances before spinning up
        // any writer. (Deliberately NOT LSMultipleInstancesProhibited:
        // that would make the new launch fail instead of replace.)
        terminateOlderInstances()

        // App-hosted unit tests (XCTest injects into this process): never
        // block on modal onboarding UI, and don't present windows.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if isTestHost {
            continueStartup()
            return
        }

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
                // The wizard's presentation step always records a choice.
                self?.finishStartup(userJustChosePresentation: true)
            }
            return
        }

        // No migration, no wizard — continue with normal startup
        continueStartup()

        // Existing users may still owe one-time decisions introduced by
        // 4.1 (wallpaper mode, menu bar vs Dock) — one window, only the
        // pending pages. New installs decide in the wizard, whose steps
        // set the same sentinels, so the gate excludes them.
        maybeShowUpgradePrompt { [weak self] chosePresentation in
            self?.finishStartup(userJustChosePresentation: chosePresentation)
        }
    }

    /// Last step of startup, after any modal wizard / upgrade prompt:
    /// let the presentation controller present the main window (Dock
    /// presentation, user-initiated launch). Deferred one runloop turn so
    /// the SwiftUI scene machinery is fully up and the modal session has
    /// unwound.
    private func finishStartup(userJustChosePresentation: Bool) {
        DispatchQueue.main.async {
            self.presentation.finishStartup(userJustChose: userJustChosePresentation)
        }
    }

    /// Newest wins: terminate any OLDER running instance of this app
    /// (same bundle ID, different pid). An Xcode debug run cleanly
    /// replaces the login-item copy instead of the two fighting over
    /// the wallpaper control channel. Instances with a strictly newer
    /// `launchDate` are left alone (pathological race — never kill the
    /// newer one; it will kill us).
    private func terminateOlderInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myLaunch = NSRunningApplication.current.launchDate ?? Date()
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where other.processIdentifier != NSRunningApplication.current.processIdentifier {
            if let otherLaunch = other.launchDate, otherLaunch > myLaunch { continue }
            debugLog("Terminating older instance pid=\(other.processIdentifier) (newest wins)")
            other.terminate()
        }
    }

    /// One-time upgrade prompt for existing users (those who never went
    /// through the wizard steps that set the sentinels). Each page is
    /// gated on its own sentinel — see `UpgradePromptPage.pending()` —
    /// so a user is asked exactly once per decision, all in one window.
    /// `completion` receives whether the presentation page was shown.
    private func maybeShowUpgradePrompt(completion: @escaping (Bool) -> Void) {
        let pages = UpgradePromptPage.pending()
        guard !pages.isEmpty else {
            completion(false)
            return
        }
        // Defer one runloop turn so the menu bar / main UI is up first —
        // through the RUN LOOP, never `DispatchQueue.main.async`: the
        // modal session (`NSApp.runModal`) nests a run loop, and when
        // that nesting happens inside a main-queue drain, libdispatch
        // (which does not re-enter its drain) starves every other
        // main-queue block — including Swift main-actor hops — until the
        // window closes. The external-cache page's conversion is async
        // and sat forever at "Creating the disk image…" that way.
        RunLoop.main.perform {
            let controller = UpgradePromptWindowController(pages: pages)
            controller.windowDidLoad()
            controller.showModal {
                completion(pages.contains(.presentation))
            }
        }
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

        // External-drive cache: attach the disk image BEFORE anything
        // consumes `Cache.path` (VideoList init, playlists, downloads,
        // reaper). Synchronous (~1 s) and a no-op for everyone else.
        ExternalCacheImage.shared.attachAtLaunch()

        // One-time cleanup of legacy LaunchAgent plist and UserDefaults keys
        LaunchAgent.removeLegacyAgentIfNeeded()
        cleanupLegacyUserDefaults()
        enableTvOS26IfNeeded()
        // "macOS 26" → "macOS" in sourcesEnabled / rotation filters /
        // persisted playlists. Before VideoList and PlaylistManager
        // exist — they'd otherwise read the stale names first.
        AppleSourceMigration.applyIfNeeded()

        // One-time cleanup of obsolete `{id}-large.jpg` thumbnails
        // (pre-single-file refactor). Idempotent — once the directory
        // is clean, subsequent launches do nothing.
        Thumbnails.cleanupLegacyLargeFiles()

        // One-time cleanup of the legacy third log file: aerial.txt was
        // the pre-configure fallback's target before the logging
        // consolidation (the extension's shared code wrote there). Only
        // app.txt and wallpaper.txt exist now.
        try? FileManager.default.removeItem(atPath: UnifiedPaths.logsPath() + "/aerial.txt")

        // Ensure the default "My Videos" source is created and enabled
        SourceList.ensureDefaultLocalSource()

        // Keep the library in sync with Finder drops into My Videos.
        MyVideosWatcher.shared.startIfNeeded()

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

        // Shell-script / text-file message overlays: the sandboxed
        // extension can't produce these — Companion runs them and
        // relays the text via message-content.json.
        MessageContentProvider.shared.startIfNeeded()

        // Prune macOS's own wallpaper-agent image-frame cache (macOS 26+).
        WallpaperCacheCleaner.shared.bootstrap()

        // Instantiate the wallpaper-extension control channel now so its
        // overlay-config observer is registered from launch (overlay
        // edits must reach the long-lived extension process).
        _ = WallpaperControl.shared

        // Reverse status channel (is the extension running, what's
        // playing) + coverage auto-pause for the wallpaper extension.
        // (Launch path runs on the main thread; the hop is a type-system
        // formality, same as the CacheOrphanReaper call below.)
        MainActor.assumeIsolated {
            _ = WallpaperStatusMonitor.shared
            WallpaperAutoPauseCoordinator.shared.start()
        }

        // Diagnostic: dump WallpaperAgent-band window geometry around
        // saver start/stop — the only vantage point that can see the
        // "second saver window in a corner" reports' actual frames.
        WallpaperWindowDump.register()

        // Track system sleep/wake so background maintenance (downloads,
        // location refresh) stands down during sleep — including the
        // periodic dark wakes macOS performs under Power Nap.
        SystemSleepState.shared.start()

        // Optional, opt-in: reclaim macOS's own downloaded wallpaper-video
        // cache at launch. Off by default; silent (logs only).
        if Preferences.reclaimMacOSWallpaperVideosAtStartup {
            DispatchQueue.global(qos: .utility).async {
                MacOSWallpaperVideoCache.reclaim()
            }
        }

        // Register system-wide hotkeys when the master pref is on.
        // Idempotent — same call fires from the toggle's onChange.
        GlobalShortcutsManager.refresh()

        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        debugLog("Version \(Helpers.version) (\(build)) launched on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        // Record the marketing version seen this launch (upgrade
        // detection). The one-time Sonoma+ wallpaper-mode prompt is gated
        // separately on `wallpaperModeChosen`; this is for logging and any
        // future "what's new on upgrade" logic.
        if Preferences.lastLaunchedVersion != Helpers.version {
            if let previous = Preferences.lastLaunchedVersion {
                debugLog("Upgraded from \(previous) to \(Helpers.version)")
            }
            Preferences.lastLaunchedVersion = Helpers.version
        }

        // Ensure not in bundle
        ensureNotInBundle()

        // Clean up mistaken folder from 3.9.9alpha2
        checkAndCleanupMistakenFolder()

        // Start Sparkle updater explicitly so we can catch and log errors
        do {
            try sparkleController.updater.start()
            debugLog("Sparkle updater started successfully")
        } catch {
            errorLog("Sparkle updater failed to start: \(error)")
        }

        // Status item + popover (menu-bar presentation) — or nothing but
        // a Dock badge reconcile (Dock presentation).
        presentation.installSurfaces()

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

        // Initialize DownloadTracker and mirror its queue into the
        // status-item dot / Dock badge.
        _ = DownloadTracker.shared
        _ = DownloadCoordinator.shared
        presentation.observeDownloads()

        // External-drive cache image: follow its backing drive. Attach
        // when it (re)appears; detach before a Finder eject; clear the
        // zombie mount after a yank. State changes post
        // `stateDidChangeNotification` → `refreshConsumers` below, which
        // also rescans the sources roots — Expansion packs kept at the
        // cache location live inside the image and follow it.
        let workspaceNC = NSWorkspace.shared.notificationCenter
        let mountEvents = [NSWorkspace.didMountNotification,
                           NSWorkspace.willUnmountNotification,
                           NSWorkspace.didUnmountNotification]
        for name in mountEvents {
            workspaceNC.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let volumeURL = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                if Cache.isExternalImageMode {
                    guard ExternalCacheImage.shared.isBackingVolume(volumeURL) else { return }
                    switch name {
                    case NSWorkspace.didMountNotification:
                        ExternalCacheImage.shared.attachIfNeeded(reason: "drive mounted")
                    case NSWorkspace.willUnmountNotification:
                        // Best effort and polite: the notification is delivered
                        // asynchronously, so blocking here would not delay
                        // Finder anyway, and forcing would yank the image from
                        // under the extension.
                        Task { await ExternalCacheImage.shared.detachIfAttached(reason: "drive unmounting", mode: .polite) }
                    default:
                        Task { await ExternalCacheImage.shared.detachIfAttached(reason: "drive removed", mode: .force) }
                    }
                } else if let legacy = Cache.legacyExternalFolderPath,
                          LegacyExternalCacheMigration.folder(legacy, isOn: volumeURL) {
                    // 4.0-style external folder: the memoized `Cache.path`
                    // and `isAvailable` must follow the drive, and a drive
                    // that shows up after launch gets the conversion offer
                    // (unless the user already said "later" this session).
                    let mounted = (name == NSWorkspace.didMountNotification)
                    Cache.invalidateCachePath()
                    ExternalCacheImage.refreshConsumers(reason: mounted ? "legacy cache drive mounted" : "legacy cache drive unmounted")
                    if mounted, !LegacyExternalCacheMigration.deferredThisSession {
                        self?.maybeShowUpgradePrompt { _ in }
                    }
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: ExternalCacheImage.stateDidChangeNotification, object: nil, queue: .main
        ) { _ in
            ExternalCacheImage.refreshConsumers(reason: "image state changed")
        }
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
        // Everything ignores filter strings entirely; favorites' empty
        // selection is its legitimate default.
        case .everything, .favorites, .liveFeeds: return
        }
        let sources = VideoList.instance.getSources(mode: filterMode)
        guard !sources.isEmpty else { return }
        let prefix = String(describing: filterMode) + ":"
        PrefsVideos.newShouldPlayString = sources.map { prefix + $0 }
        debugLog("🚀 bootstrap: populated newShouldPlayString with \(sources.count) \(prefix) entries")
    }

    // MARK: - Presentation forwarding

    // Reopen = the user double-clicked Aerial.app, clicked the Dock icon
    // or `open`ed us while already running. Menu-bar presentation: show
    // the popover. Dock presentation: front the Video Library.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentation.handleReopen(hasVisibleWindows: flag)
    }

    // Closing the Video Library must never quit: the wallpaper control
    // channel, downloads and overlay data providers outlive windows. (The
    // AppKit default is already false; explicit because a regular app
    // with a main window invites the opposite assumption.)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Dock presentation: one-time "Aerial keeps working in the background"
    // explanation on the first in-process ⌘Q.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        presentation.shouldTerminate()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        presentation.dockMenu()
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

    /// One-time migration: early v4 builds shipped with `tvOS 26` disabled
    /// by default in `ScreensaverSettings.default.sourcesEnabled`. That
    /// surfaced as a cache-wipe for migrating users whose Aerial 3 cache
    /// referenced tvOS 26 video IDs — those IDs weren't in any active
    /// manifest, so `CacheOrphanReaper` evicted the files. The default is
    /// now `true`, but that only helps fresh installs. This pass enables
    /// the source for existing users who were on the old default. Marked
    /// done in `UserDefaults` so it runs exactly once.
    ///
    /// Trade-off: a user who actively disabled tvOS 26 will see it
    /// re-enabled here. They can flip it back in Settings → Sources. The
    /// "few users actively disabled it" assumption is the conscious call.
    private func enableTvOS26IfNeeded() {
        let key = "tvOS26DefaultMigrationApplied"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        var sources = PrefsVideos.enabledSources
        if sources["tvOS 26"] != true {
            sources["tvOS 26"] = true
            PrefsVideos.enabledSources = sources
            debugLog("Enabled tvOS 26 source via one-time migration")
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        presentation.persistWindowState()

        // External-drive cache image: detach unless another Companion
        // instance is taking over (dev handover).
        ExternalCacheImage.shared.detachOnTerminate()

        // Shut down every ffmpeg child + the loopback HTTP server so we
        // don't leak subprocesses. Swift's Process doesn't propagate
        // termination automatically.
        LiveFeedTransmuxerManager.shared.stopAll()
    }
    
}


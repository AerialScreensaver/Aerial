//
//  AppPresentationController.swift
//  Aerial Companion
//
//  Owns everything that depends on WHERE the Companion app lives — the
//  menu bar (status item + popover, the historical shape) or the Dock
//  (regular app whose main window is the Video Library). See
//  `AppPresentation` in Preferences.swift.
//
//  AppDelegate forwards lifecycle events here; nothing else in the app
//  should touch `NSApp.setActivationPolicy`, the status item or the
//  Dock tile directly. The status-item / popover code is a straight
//  move out of AppDelegate — menu-bar mode must stay pixel-identical.
//
//  Threading: main thread only, like AppDelegate. The few entry points
//  that may be reached from Sparkle / notification callbacks hop to
//  main themselves (`setIcon`, `setDownloading`, `setUpdateAvailable`).
//

import Cocoa
import Combine
import ServiceManagement
import SwiftUI

enum IconMode {
    case normal, updating, notification
}

final class AppPresentationController: NSObject {
    static let shared = AppPresentationController()

    // MARK: - State

    /// The presentation currently in effect. Usually equals the pref;
    /// `apply(_:reason:)` keeps the two in line when the user switches.
    private(set) var current: AppPresentation = Preferences.appPresentation

    /// True when this process was launched by the login item rather than
    /// by the user (Finder / Dock / Spotlight / `open`). The Dock
    /// presentation only auto-presents the Video Library for
    /// user-initiated launches — a window at every login would be rude.
    private(set) var launchedAsLoginItem = false

    /// Set by `finishStartup` — user-facing behaviours that assume a
    /// fully running app (window presentation, the ⌘Q explanation) only
    /// engage once startup, including any modal wizard, is complete.
    private(set) var startupFinished = false

    private var launchPolicyApplied = false
    private var surfacesInstalled = false

    /// Set when the app became `.regular` AFTER AppKit finished
    /// launching (live switch, or the willFinishLaunching hook not
    /// firing). AppKit then doesn't install our main menu until the app
    /// is re-activated from another app — see `bounceActivation()`.
    private var needsActivationBounce = false

    // Menu-bar presentation: status item + popover
    private(set) var statusItem: NSStatusItem?
    let popover = NSPopover()
    private var popoverConfigured = false
    private var downloadDot: NSView?
    private var iconMode: IconMode = .normal

    // Download / update indicators
    private var isDownloading = false
    private var downloadCount = 0
    private var updateAvailable = false
    private var downloadObserver: AnyCancellable?

    // Window plumbing
    private var openWindowAction: OpenWindowAction?
    private weak var libraryWindow: NSWindow?
    private var libraryWindowObservers: [NSObjectProtocol] = []
    private lazy var infoWindowController = InfoWindowController()

    /// UserDefaults key for the Video Library's last frame. Owned here
    /// rather than left to SwiftUI: a `Window` scene only brings the
    /// user's size back through state restoration, which is disabled
    /// (a login-item launch must stay windowless) — without this the
    /// window opened at its minimum size on every launch.
    private static let libraryFrameKey = "AerialVideoLibraryWindowFrame"

    private override init() {
        super.init()
    }

    // MARK: - Launch

    /// Apply the launch-time activation policy. Called from
    /// `applicationWillFinishLaunching` — switching an LSUIElement app to
    /// `.regular` BEFORE AppKit finishes launching is the one timing where
    /// the Dock icon and the main menu come up cleanly. Also called (as a
    /// no-op when the first call happened) from `applicationDidFinishLaunching`
    /// in case the adaptor doesn't forward the earlier hook; that late
    /// path needs the activation bounce.
    func applyLaunchPolicy(phase: String) {
        guard !launchPolicyApplied else { return }
        launchPolicyApplied = true
        if current.showsDockIcon {
            NSApp.setActivationPolicy(.regular)
            if phase != "willFinishLaunching" { needsActivationBounce = true }
            debugLog("🪟 presentation=\(current) → activation policy .regular (\(phase))")
        } else {
            debugLog("🪟 presentation=\(current) → staying .accessory (LSUIElement)")
        }
    }

    /// Detect a login-item launch. Must run first thing in
    /// `applicationDidFinishLaunching`, while the launch Apple event is
    /// still the current event: LaunchServices tags an `oapp` event sent
    /// to a login item with `keyAELaunchedAsLogInItem` ('lgit') in its
    /// `keyAEPropData` ('prdt') parameter. Whether `SMAppService.mainApp`
    /// launches carry the tag is what the log line below answers; the
    /// uptime heuristic backs it up (false positive = no auto-window,
    /// one Dock click fixes it; false negative = a window at login).
    func noteLaunchContext() {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isOpenApp = event?.eventClass == fourCC("aevt") && event?.eventID == fourCC("oapp")
        let propData = event?.paramDescriptor(forKeyword: fourCC("prdt"))?.enumCodeValue
        let taggedAsLoginItem = isOpenApp && propData == fourCC("lgit")

        let loginItemEnabled = SMAppService.mainApp.status == .enabled
        let uptime = ProcessInfo.processInfo.systemUptime
        let heuristic = loginItemEnabled && uptime < 180

        launchedAsLoginItem = taggedAsLoginItem || heuristic
        let eventDesc = event.map { "class=\(fourCCString($0.eventClass)) id=\(fourCCString($0.eventID))" } ?? "none"
        let propDesc = propData.map { fourCCString($0) } ?? "nil"
        debugLog("🪟 launch context: event=\(eventDesc) prdt=\(propDesc) lgit=\(taggedAsLoginItem) loginItem=\(loginItemEnabled) uptime=\(Int(uptime))s → launchedAsLoginItem=\(launchedAsLoginItem)")
    }

    /// Install the presentation's surfaces. Called from `continueStartup()`
    /// where the status item used to be wired — the menu-bar presentation
    /// gets its status item + popover here; the Dock presentation gets
    /// nothing but a badge reconcile.
    func installSurfaces() {
        surfacesInstalled = true
        reconcileSurfaces()
        // The Playback menu's live state — bound only now, once the
        // singletons it mirrors are safe to create (see PlaybackMenuModel).
        MainActor.assumeIsolated { PlaybackMenuModel.shared.bind() }
    }

    /// Last startup step, after any modal wizard / upgrade prompt.
    /// `userJustChose` = the presentation was picked interactively this
    /// launch, so the user is clearly at the keyboard — present even on a
    /// login-item launch.
    func finishStartup(userJustChose: Bool) {
        startupFinished = true
        guard current.showsDockIcon else { return }
        if launchedAsLoginItem && !userJustChose {
            debugLog("🪟 Dock presentation, login-item launch — not presenting the Video Library")
            return
        }
        openVideoLibrary(reason: userJustChose ? "chosen" : "launch")
    }

    // MARK: - Switching

    /// Switch presentation at runtime (Settings picker, wizard step,
    /// upgrade prompt). Writes the pref + sentinel, then reconciles the
    /// activation policy and the surfaces. Idempotent.
    func apply(_ presentation: AppPresentation, reason: String) {
        Preferences.appPresentation = presentation
        Preferences.appPresentationChosen = true
        guard presentation != current else {
            debugLog("🪟 apply(\(presentation), \(reason)) — already current")
            return
        }
        debugLog("🪟 switching presentation \(current) → \(presentation) (\(reason))")
        current = presentation
        switchPolicy()
        reconcileSurfaces()

        if presentation.showsDockIcon {
            // Before startup completes (wizard / upgrade prompt), the
            // window is presented by `finishStartup(userJustChose: true)`.
            if startupFinished { openVideoLibrary(reason: "switch") }
        } else {
            // Back to the menu bar: an accessory app's windows can lose
            // key status on the policy flip — keep whatever window the
            // user switched from (Settings) usable.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func switchPolicy() {
        let target: NSApplication.ActivationPolicy = current.showsDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        if target == .regular { needsActivationBounce = true }
        debugLog("🪟 activation policy → \(target == .regular ? ".regular" : ".accessory")")
    }

    private func reconcileSurfaces() {
        guard surfacesInstalled else { return }
        if current.showsStatusItem {
            installStatusItemIfNeeded()
        } else {
            removeStatusItemIfNeeded()
        }
        reconcileDockBadge()
    }

    /// AppKit only installs the main menu of an app that became `.regular`
    /// after launch once it has been activated from ANOTHER app (until
    /// then the menu bar keeps showing the previous app's menus). Yield to
    /// Finder for a beat, then take activation back.
    private func bounceActivation() {
        needsActivationBounce = false
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        debugLog("🪟 activation bounce via Finder")
        NSApp.yieldActivation(to: finder)
        finder.activate(from: .current, options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.libraryWindow?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Windows

    /// Registered once by `AerialCompanionApp.body` — the sanctioned way
    /// for AppKit-side code to open a SwiftUI `Window` scene.
    func register(openWindow: OpenWindowAction) {
        if openWindowAction == nil { debugLog("🪟 openWindow action registered") }
        openWindowAction = openWindow
    }

    /// Registered by the Video Library scene's `WindowContentGate` once
    /// its NSWindow exists. SwiftUI keeps the window alive across closes,
    /// so after the first open this is a direct handle for re-fronting.
    func registerLibraryWindow(_ window: NSWindow) {
        guard libraryWindow !== window else { return }
        libraryWindow = window
        debugLog("🪟 Video Library window registered (identifier=\(window.identifier?.rawValue ?? "nil"))")

        // Restore the last frame now (window under construction, not yet
        // on screen) and once more after SwiftUI's own initial sizing
        // pass, which otherwise wins with `.defaultSize`.
        restoreLibraryFrame(into: window, phase: "register")
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.restoreLibraryFrame(into: window, phase: "deferred")
        }

        // Save on user resizes and whenever the window goes away; a
        // move-only change is captured by the close / quit saves (the
        // programmatic placement at creation must not be persisted).
        let center = NotificationCenter.default
        libraryWindowObservers.forEach { center.removeObserver($0) }
        libraryWindowObservers = [
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                self?.saveLibraryFrame(window, reason: "resize")
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                self?.saveLibraryFrame(window, reason: "close")
            },
        ]
    }

    /// Called from `applicationWillTerminate` — the frame at quit is the
    /// user's last state when the window is still open.
    func persistWindowState() {
        if let libraryWindow, libraryWindow.isVisible {
            saveLibraryFrame(libraryWindow, reason: "quit")
        }
    }

    private func saveLibraryFrame(_ window: NSWindow, reason: String) {
        guard window.frame.width >= 100, window.frame.height >= 100 else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.libraryFrameKey)
        debugLog("🪟 Video Library frame saved (\(reason)): \(NSStringFromRect(window.frame))")
    }

    private func restoreLibraryFrame(into window: NSWindow, phase: String) {
        guard let saved = UserDefaults.standard.string(forKey: Self.libraryFrameKey) else { return }
        var frame = NSRectFromString(saved)
        guard frame.width >= 100, frame.height >= 100 else { return }

        // Displays change between sessions: shrink to the screen and pull
        // the window back on it if its saved position is nowhere visible.
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            if !visible.intersects(frame) {
                frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
            }
            frame = window.constrainFrameRect(frame, to: screen)
        }
        guard window.frame != frame else { return }
        window.setFrame(frame, display: true)
        debugLog("🪟 Video Library frame restored (\(phase)): \(NSStringFromRect(frame))")
    }

    /// Whether the Video Library is on screen — lets the 1 Hz playback
    /// progress refresh run for Home the way it does for the popover.
    var isLibraryWindowVisible: Bool {
        libraryWindow?.isVisible ?? false
    }

    func openVideoLibrary(reason: String) {
        debugLog("🪟 openVideoLibrary(\(reason)) action=\(openWindowAction != nil) window=\(libraryWindow != nil)")
        if let openWindowAction {
            openWindowAction(id: "videoBrowser")
        } else if let libraryWindow {
            libraryWindow.makeKeyAndOrderFront(nil)
        } else {
            errorLog("🪟 cannot open the Video Library — no openWindow action registered yet")
            return
        }
        // Make it key, not just ordered front: WindowContentGate remounts
        // the dismounted content on didBecomeKey.
        libraryWindow?.makeKeyAndOrderFront(nil)
        activateForWindow()
    }

    func openSettings() {
        guard let openWindowAction else {
            errorLog("🪟 cannot open Settings — no openWindow action registered yet")
            return
        }
        MainActor.assumeIsolated { SettingsWindowController.show(via: openWindowAction) }
        activateForWindow()
    }

    func showAbout() {
        infoWindowController.showAboutWindow()
    }

    private func activateForWindow() {
        if needsActivationBounce {
            bounceActivation()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Reopen

    /// `applicationShouldHandleReopen` — the user double-clicked Aerial.app,
    /// clicked the Dock icon, or `open`ed us while running.
    func handleReopen(hasVisibleWindows: Bool) -> Bool {
        if current.showsDockIcon {
            if !hasVisibleWindows { openVideoLibrary(reason: "reopen") }
            // We handled it — keep AppKit / SwiftUI from also opening
            // something.
            return false
        }
        // Menu-bar presentation: the popover is the main surface.
        if !popover.isShown, statusItem?.button != nil {
            showPopover(sender: nil)
        }
        return true
    }

    // MARK: - Quit

    /// Dock presentation: the first in-process ⌘Q gets a one-time
    /// explanation that Aerial keeps working in the background. Never
    /// shown for quits arriving as Apple events — logout / shutdown, the
    /// Dock menu's Quit, the newest-wins instance replacement —
    /// `currentAppleEvent` is nil only on the in-process menu/shortcut path.
    func shouldTerminate() -> NSApplication.TerminateReply {
        guard current.showsDockIcon,
              startupFinished,
              !Preferences.dockQuitExplained,
              NSAppleEventManager.shared().currentAppleEvent == nil else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Quit Aerial?"
        alert.informativeText = """
            Your wallpaper and screensaver keep running — they live in a macOS extension, not in this app.

            Quitting Aerial stops what the app itself takes care of in the background: video downloads, automatic pause when windows cover the wallpaper, live overlay data (weather, now playing) and keyboard shortcuts.

            You can close the window instead and keep Aerial running in the Dock.
            """
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Close Window Instead")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.suppressionButton?.state = .on
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            Preferences.dockQuitExplained = true
        }
        if response == .alertFirstButtonReturn {
            debugLog("🪟 quit explanation → Quit")
            return .terminateNow
        }
        debugLog("🪟 quit explanation → Close Window Instead")
        (NSApp.mainWindow ?? libraryWindow)?.close()
        return .terminateCancel
    }

    // MARK: - Dock menu

    /// Right-click menu on the Dock icon. Rebuilt on every request, so
    /// the titles reflect the live state. Mirrors the global shortcuts'
    /// calls exactly (no-arg `PlaybackManager` transport = same scope
    /// semantics as the hotkeys).
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let running = MainActor.assumeIsolated { WallpaperStatusMonitor.shared.isRunning }
        let paused = MainActor.assumeIsolated { PlaybackManager.shared.isPaused }

        func item(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            return item
        }

        menu.addItem(item(paused ? "Resume Wallpaper" : "Pause Wallpaper", #selector(dockTogglePause(_:)), enabled: running))
        menu.addItem(item("Next Video", #selector(dockNextVideo(_:)), enabled: running))
        menu.addItem(item("Previous Video", #selector(dockPreviousVideo(_:)), enabled: running))
        menu.addItem(.separator())
        menu.addItem(item("Start Screensaver", #selector(dockStartScreensaver(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Open Video Library", #selector(dockOpenLibrary(_:))))
        menu.addItem(item("Settings…", #selector(dockOpenSettings(_:))))
        return menu
    }

    @objc private func dockTogglePause(_ sender: Any?) {
        MainActor.assumeIsolated { PlaybackManager.shared.togglePause() }
    }

    @objc private func dockNextVideo(_ sender: Any?) {
        MainActor.assumeIsolated { PlaybackManager.shared.nextVideo() }
    }

    @objc private func dockPreviousVideo(_ sender: Any?) {
        MainActor.assumeIsolated { PlaybackManager.shared.previousVideo() }
    }

    @objc private func dockStartScreensaver(_ sender: Any?) {
        MainActor.assumeIsolated { PlaybackManager.shared.startScreensaver() }
    }

    @objc private func dockOpenLibrary(_ sender: Any?) {
        openVideoLibrary(reason: "dock menu")
    }

    @objc private func dockOpenSettings(_ sender: Any?) {
        openSettings()
    }

    // MARK: - Status item (menu-bar presentation)

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        applyIcon(iconMode)
        configurePopoverIfNeeded()

        // Action button
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            // VoiceOver: announce as "Aerial" when the user walks the
            // menu bar instead of the SF Symbol's accessibility name.
            button.setAccessibilityLabel("Aerial")
        }
        if isDownloading { showDownloadDot(true) }
        debugLog("🪟 status item installed")
    }

    private func removeStatusItemIfNeeded() {
        guard let item = statusItem else { return }
        if popover.isShown { popover.performClose(nil) }
        downloadDot?.removeFromSuperview()
        downloadDot = nil
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        debugLog("🪟 status item removed")
    }

    // Change the icon based on status. Safe from any thread (Sparkle
    // delegate callbacks) — hops to main.
    func setIcon(mode: IconMode) {
        DispatchQueue.main.async {
            self.iconMode = mode
            self.applyIcon(mode)
        }
    }

    private func applyIcon(_ mode: IconMode) {
        guard let statusItem else { return }
        switch mode {
        case .normal:
            statusItem.image = NSImage(named: "Status48")
        case .updating:
            statusItem.image = NSImage(named: "StatusTransp48")
        case .notification:
            statusItem.image = NSImage(named: "Status48Attention")
        }
        statusItem.image?.size.width = 17
        statusItem.image?.size.height = 17
    }

    // MARK: - Popover (menu-bar presentation)

    private func configurePopoverIfNeeded() {
        guard !popoverConfigured else { return }
        popoverConfigured = true

        let popoverView = MainPopoverView(
            playbackManager: PlaybackManager.shared,
            onOpenVideoBrowser: { [weak self] in
                // The Video Library window is opened directly from
                // `BottomBarView` via `@Environment(\.openWindow)` —
                // we just need to dismiss the popover here.
                self?.closePopover(sender: nil)
            },
            onOpenCompanionSettings: { [weak self] in
                // Same — `BottomBarView` opens Settings itself.
                self?.closePopover(sender: nil)
            },
            onOpenInfo: { [weak self] in
                self?.showAbout()
                self?.closePopover(sender: nil)
            },
            onExit: {
                NSApplication.shared.terminate(nil)
            },
            onDismiss: { [weak self] in
                self?.closePopover(sender: nil)
            }
        )
        popover.contentViewController = NSHostingController(rootView: popoverView)

        // Common popover configuration
        popover.behavior = .transient
        popover.animates = false  // Disable animation for instant opening

        // Content-dismount gate: MainPopoverView unmounts its whole
        // tree while closed (see PopoverVisibility). didClose is the
        // one signal that covers EVERY close path, including the
        // transient outside-click dismiss.
        NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: popover, queue: .main
        ) { _ in
            MainActor.assumeIsolated { PopoverVisibility.shared.isShown = false }
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover(sender: sender)
        } else {
            showPopover(sender: sender)
        }
    }

    func showPopover(sender: Any?) {
        guard let button = statusItem?.button else { return }
        // Refresh the screen list and scope the popover to the display
        // it's opening on (the menu-bar item's display) BEFORE showing,
        // so independent mode renders the right display on the first
        // frame instead of briefly falling back to the shared playlist.
        // We're on the main thread here (UI action).
        MainActor.assumeIsolated {
            PlaybackManager.shared.refreshScreenList()
            PlaybackManager.shared.updatePopoverScreen(preferredScreen: button.window?.screen)
            // Mount the content BEFORE show so the first frame has
            // the real tree (the closed popover keeps only a
            // placeholder — see PopoverVisibility).
            PopoverVisibility.shared.isShown = true
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePopover(sender: Any?) {
        popover.performClose(sender)
    }

    // MARK: - Badges

    /// Mirror the download queue. Called from `continueStartup()` right
    /// after `DownloadTracker` exists (its init hooks `VideoManager`, so
    /// it must not be created any earlier). Drives both indicators: the
    /// blue dot on the status item (menu-bar presentation) and, when
    /// `Preferences.dockDownloadBadge` is on, a Dock badge with the
    /// number of videos left (Dock presentation).
    func observeDownloads() {
        // Main thread (launch path); DownloadTracker is MainActor-isolated.
        downloadObserver = MainActor.assumeIsolated {
            DownloadTracker.shared.$downloadingVideoIds
                .map(\.count)
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] count in self?.setDownloadCount(count) }
        }
    }

    private func setDownloadCount(_ count: Int) {
        downloadCount = count
        isDownloading = count > 0
        showDownloadDot(isDownloading)
        reconcileDockBadge()
    }

    /// Re-evaluate the Dock badge after a pref change (the Settings →
    /// Cache toggle). Safe from any thread.
    func refreshDockBadge() {
        DispatchQueue.main.async { self.reconcileDockBadge() }
    }

    private func showDownloadDot(_ show: Bool) {
        if show {
            guard downloadDot == nil, let button = statusItem?.button else { return }
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

    /// Sparkle "gentle reminder" indicator. Menu-bar presentation: the
    /// historical temporary Dock presence — the app flips to `.regular`
    /// just so there's a Dock tile to badge, and back to `.accessory`
    /// once the user has seen the update dialog. Dock presentation: the
    /// tile is already there, only the badge changes and the activation
    /// policy is never touched. Safe from any thread.
    func setUpdateAvailable(_ available: Bool) {
        DispatchQueue.main.async {
            self.updateAvailable = available
            if !self.current.showsDockIcon {
                NSApp.setActivationPolicy(available ? .regular : .accessory)
            }
            self.reconcileDockBadge()
        }
    }

    /// Single owner of `NSApp.dockTile.badgeLabel`: a pending update
    /// wins (it's what the gentle reminder promised), then the download
    /// count in the Dock presentation when the option is on.
    private func reconcileDockBadge() {
        let label: String
        if updateAvailable {
            label = "1"
        } else if current.showsDockIcon, Preferences.dockDownloadBadge, downloadCount > 0 {
            label = String(downloadCount)
        } else {
            label = ""
        }
        if NSApp.dockTile.badgeLabel != label {
            NSApp.dockTile.badgeLabel = label
        }
    }

    // MARK: - Four-char codes

    private func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func fourCCString(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(code)
    }
}

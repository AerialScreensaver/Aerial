//
//  AerialSaverView.swift
//  AerialScreenSaverExtension
//
//  The main screensaver view that displays Aerial video content.
//

import ScreenSaver
import QuartzCore
import AVFoundation
import CoreImage
import SwiftUI

/// The main screensaver view that displays Aerial video content.
@objc(AerialSaverView)
final class AerialSaverView: ScreenSaverView {

    // MARK: - Video Playback Properties

    /// The PlayerCoordinator managing the AVQueuePlayer
    private var coordinator: PlayerCoordinator?

    /// The AVPlayerLayer that displays the video
    private var playerLayer: AVPlayerLayer?

    /// The current video being played (mirrored from coordinator via delegate)
    private var currentVideo: AerialVideo?

    /// Timer for fallback color animation (when no videos)
    private var colorTimer: Timer?
    private var colorIndex: Int = 0

    /// Label shown in the center during color-fallback mode.
    private var fallbackLabel: NSTextField?

    /// Unified SwiftUI overlay state
    private var overlayState: OverlayState?

    /// SwiftUI hosting view for all overlays
    private var overlayHostingView: NSHostingView<OverlayRootView>?

    /// Fallback colors when no videos are available. Six hues from the
    /// original (1977–1998) Apple rainbow logo, top-to-bottom:
    /// green, yellow, orange, red, purple, blue.
    private let colors: [NSColor] = [
        NSColor(red: 0x61 / 255.0, green: 0xBB / 255.0, blue: 0x46 / 255.0, alpha: 1.0), // green
        NSColor(red: 0xFD / 255.0, green: 0xB8 / 255.0, blue: 0x27 / 255.0, alpha: 1.0), // yellow
        NSColor(red: 0xF5 / 255.0, green: 0x82 / 255.0, blue: 0x1F / 255.0, alpha: 1.0), // orange
        NSColor(red: 0xE0 / 255.0, green: 0x3A / 255.0, blue: 0x3E / 255.0, alpha: 1.0), // red
        NSColor(red: 0x96 / 255.0, green: 0x3D / 255.0, blue: 0x97 / 255.0, alpha: 1.0), // purple
        NSColor(red: 0x00 / 255.0, green: 0x9D / 255.0, blue: 0xDC / 255.0, alpha: 1.0), // blue
    ]

    // MARK: - Display Detection Properties

    /// The detected screen for this view
    private var foundScreen: Screen?

    /// Weak set of all live instantiated views (for multi-monitor coordination —
    /// keyboard skip, mirrored-mode flip, nextVideo/previousVideo broadcasts).
    /// Weak so views aren't retained past their windows' teardown. Use
    /// `liveViews()` to materialize the snapshot.
    private static let _instanciatedViews = NSHashTable<AerialSaverView>.weakObjects()

    /// Snapshot of currently-live views, ordered by their `viewOrdinal` so
    /// callers (e.g. `commonInit` count log, mirrored-mode flip parity) see a
    /// stable, deterministic order regardless of NSHashTable's internal
    /// enumeration. The cost is O(n log n) per call — n is single digits.
    static func liveViews() -> [AerialSaverView] {
        return _instanciatedViews.allObjects.sorted { $0.viewOrdinal < $1.viewOrdinal }
    }

    /// Process-wide monotonic counter handed to each new view. Combined with
    /// the weak set above, this gives every view a stable identity that
    /// survives across activations without leaking — important for mirrored
    /// mode's `viewOrdinal % 2 == 1` flip rule, which would otherwise flicker
    /// if the index were derived from a re-orderable container.
    private static var nextViewOrdinal: Int = 0
    fileprivate let viewOrdinal: Int

    /// Display detection singleton reference
    private var displayDetection: DisplayDetection {
        return DisplayDetection.sharedInstance
    }

    // MARK: - Keyboard Skip Support

    /// Lock to prevent multiple rapid skips
    private var isQuickFading = false

    /// Screen UUID for this view, set by the Companion app at init when this
    /// view runs in desktop-wallpaper mode. Always nil in the extension; the
    /// extension uses geometric detection (window.frame midpoint) instead.
    private var companionDisplayUUID: String?

    /// True when running inside Companion (not the screensaver extension).
    private(set) var isUnderCompanion = false

    /// Periodic timer to save playback position to the progress sidecar (extension only)
    private var progressTimer: Timer?

    // MARK: - Initialization

    override init?(frame: NSRect, isPreview: Bool) {
        self.isUnderCompanion = false
        self.viewOrdinal = AerialSaverView.nextViewOrdinal
        AerialSaverView.nextViewOrdinal += 1
        super.init(frame: frame, isPreview: isPreview)
        debugLog("AerialSaverView.init(frame: \(frame.size.width)x\(frame.size.height), isPreview: \(isPreview))")
        commonInit()
    }

    /// Companion-specific init — passes the screen UUID directly, skips bridge/battery/brightness.
    init?(frame: NSRect, screenUUID: String) {
        self.isUnderCompanion = true
        self.viewOrdinal = AerialSaverView.nextViewOrdinal
        AerialSaverView.nextViewOrdinal += 1
        super.init(frame: frame, isPreview: false)
        self.companionDisplayUUID = screenUUID
        debugLog("AerialSaverView.init(frame: \(frame.size.width)x\(frame.size.height), screenUUID: \(screenUUID))")
        commonInit()
    }

    required init?(coder: NSCoder) {
        self.viewOrdinal = AerialSaverView.nextViewOrdinal
        AerialSaverView.nextViewOrdinal += 1
        super.init(coder: coder)
        debugLog("AerialSaverView.init(coder:)")
        commonInit()
    }

    deinit {
        stopPlayback()
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
        // _instanciatedViews holds weak references — the slot zeros itself
        // automatically when this view deallocates. We just need to fire the
        // shared-coordinator reset when we're the last one out. Inside deinit
        // the weak slot may or may not still resolve to self depending on
        // Swift's deinit/dealloc ordering, so count remaining views by
        // filtering self out explicitly.
        let remaining = AerialSaverView._instanciatedViews.allObjects.filter { $0 !== self }.count
        if remaining == 0 {
            PlayerCoordinator.resetShared()
        }
        debugLog("AerialSaverView.deinit - \(remaining) views remaining")
    }

    private func commonInit() {
        wantsLayer = true
        animationTimeInterval = 1.0 / 60.0

        // Track this instance for multi-monitor support. Weak set means the
        // entry vanishes automatically when the view dies, so we don't need
        // to (and historically couldn't — strong array prevented deinit from
        // ever firing) reach back in to remove ourselves.
        AerialSaverView._instanciatedViews.add(self)
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        self.identifier = NSUserInterfaceItemIdentifier("\(ptr)")
        debugLog("AerialSaverView.commonInit() completed - id=\(ptr) ord=\(viewOrdinal) \(AerialSaverView._instanciatedViews.count) views total")
    }

    // MARK: - Layer Setup

    override func makeBackingLayer() -> CALayer {
        debugLog("AerialSaverView.makeBackingLayer()")
        let layer = CALayer()
        layer.backgroundColor = NSColor.black.cgColor
        layer.isOpaque = true
        return layer
    }

    // MARK: - ScreenSaverView Overrides

    // IMPORTANT: In the screensaver extension (.appex) context, startAnimation() and stopAnimation()
    // are NOT reliably called. All playback logic is handled in viewDidMoveToWindow() instead.

    override func startAnimation() {
        super.startAnimation()
        debugLog("AerialSaverView.startAnimation() - playback handled in viewDidMoveToWindow")
    }

    override func stopAnimation() {
        debugLog("AerialSaverView.stopAnimation()")
        stopPlayback()
        super.stopAnimation()
    }

    override func animateOneFrame() {
        // Video playback is handled by AVPlayer
    }

    override var hasConfigureSheet: Bool {
        return true
    }

    override var configureSheet: NSWindow? {
        return nil
    }

    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        let ptr = Unmanaged.passUnretained(self).toOpaque()
        debugLog("[\(ptr)] AerialSaverView.viewDidMoveToWindow() - hasWindow: \(self.window != nil)")

        // Maintain the window-screen-change observer in lockstep with the
        // window. Tear it down whether the window is going away or being
        // replaced, then re-attach for the new window if there is one.
        // Diagnostic: we want to know whether macOS migrates the window's
        // screen after viewDidMoveToWindow fires (a known suspect when
        // both windows initially land on the primary).
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeScreenNotification,
            object: nil)
        if let win = self.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeScreen(_:)),
                name: NSWindow.didChangeScreenNotification,
                object: win)
        }

        if window != nil {
            // Window appeared - detect screen and setup playback.
            // This is the main entry point for the extension since
            // startAnimation() is not reliably called.
            //
            // The previous "advanced screen detection" path queried Companion
            // over a TCP loopback bridge to disambiguate same-size displays.
            // It's been replaced by the window.frame midpoint detection in
            // detectScreen() + the NSWindow.didChangeScreenNotification
            // observer above, which together handle the case where macOS
            // initially places both windows on the primary then migrates one.
            continueWindowSetup()
        } else {
            // Window disappeared - stop playback
            stopPlayback()
        }
    }

    /// Second half of `viewDidMoveToWindow`, called once the Companion
    /// bridge query has returned (or immediately when the bridge isn't used).
    private func continueWindowSetup() {
        // Detect which screen this view is on
        detectScreen()

        // Compute dark mode (after screen detection)
        Aerial.helper.computeDarkMode(view: self)
        debugLog("📺 Dark mode: \(Aerial.helper.darkMode)")

        // Check if this screen should display video based on display mode settings
        guard shouldDisplayOnThisScreen() else {
            debugLog("Screen not active per display mode settings - showing blank")
            return
        }

        // Check battery status
        guard shouldPlayOnBattery() else {
            debugLog("🔋 Disabled due to battery settings - showing blank")
            return
        }

        if !isUnderCompanion || OverlayConfigManager.shared.config.separateDesktopConfig {
            setupOverlays()
        }

        // Start video playback, fall back to color animation if no videos
        if ExtensionVideoLoader.shared.hasCachedVideos {
            setupPlayerLayer()

            // Get or create the coordinator for this viewing mode
            let isVertical = (foundScreen != nil) ? foundScreen!.height > foundScreen!.width : false
            // Under Companion, companionDisplayUUID is authoritative (set at
            // init from the target screen). Using it directly avoids a
            // round-trip through foundScreen → display ID → UUID, which
            // can fail on hot-plug when DisplayDetection is stale. The
            // extension path still derives from foundScreen.
            var screenUUID: String? = isUnderCompanion ? companionDisplayUUID : nil
            if screenUUID == nil, let screen = foundScreen {
                let cfUUID = CGDisplayCreateUUIDFromDisplayID(screen.id)
                if let uuid = cfUUID?.takeRetainedValue() {
                    screenUUID = CFUUIDCreateString(nil, uuid) as String
                    debugLog("📺 Derived screenUUID: \(screenUUID!) for display \(screen.id)")
                }
            }
            let coord = PlayerCoordinator.forCurrentMode(isVerticalScreen: isVertical, screenUUID: screenUUID, isDesktop: isUnderCompanion)
            coordinator = coord

            // Register first so isLeader() can find us in the delegates list
            let player = coord.register(delegate: self)
            playerLayer?.player = player

            let amLeader = coord.isLeader(self)
            debugLog("Coordinator mode: leader=\(amLeader)")

            // Only the leader resets the playlist cache and starts playback
            if amLeader {
                ExtensionVideoLoader.shared.resetPlaylistCache()
                coord.playNextVideo()
            }
        } else {
            startColorAnimation()
        }
    }

    // MARK: - Overlay Setup

    private func setupOverlays() {
        guard overlayHostingView == nil else { return }

        let state = OverlayState(isPreview: isPreview)

        // Resolve the screen UUID for per-screen layouts
        var screenUUID: String? = isUnderCompanion ? companionDisplayUUID : nil
        if screenUUID == nil, let screen = foundScreen {
            let cfUUID = CGDisplayCreateUUIDFromDisplayID(screen.id)
            if let uuid = cfUUID?.takeRetainedValue() {
                screenUUID = CFUUIDCreateString(nil, uuid) as String
            }
        }

        let layout = OverlayConfigManager.shared.layout(for: screenUUID, isDesktop: isUnderCompanion)
        if !layout.allInstances.isEmpty {
            state.startFromConfig(layout: layout)
            debugLog("Overlay system: using config-based layout (\(layout.allInstances.count) overlays)")
        } else {
            debugLog("Overlay system: layout is empty, no overlays to show")
        }
        state.showVersionIfNeeded()

        overlayState = state

        #if COMPANION_APP
        // Under Companion (desktop wallpaper mode), shift overlays away from
        // the dock so they don't get hidden behind it.
        if isUnderCompanion {
            applyDockInsetForCurrentScreen()
        }
        #endif

        let rootView = OverlayRootView(state: state)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        overlayHostingView = hostingView
        debugLog("Overlay system setup complete")

        // Observe login shield (password prompt) to hide overlays
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(loginShieldDidShow),
            name: Notification.Name("com.apple.screenLockUIIsShown"),
            object: nil)
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(loginShieldDidHide),
            name: Notification.Name("com.apple.screenLockUIIsHidden"),
            object: nil)
        // Extension-only: catch the "screensaver about to exit" notification
        // so we flush the progress sidecar before legacyScreenSaver tears us
        // down. `stopPlayback()` is unreliable — this is the last guaranteed
        // point where our process is still alive with a valid position.
        if !isUnderCompanion {
            DistributedNotificationCenter.default.addObserver(
                self,
                selector: #selector(screensaverWillStop),
                name: Notification.Name("com.apple.screensaver.willstop"),
                object: nil)
        }
    }

    #if COMPANION_APP
    /// Re-detect the dock for this view's screen and apply the inset to the overlay state.
    /// Called from setupOverlays() and from SwiftAerialDesktop on screen-parameter changes.
    func applyDockInsetForCurrentScreen() {
        guard let state = overlayState else { return }
        let nsScreen: NSScreen? = (companionDisplayUUID.flatMap { NSScreen.getScreenByUuid($0) })
            ?? window?.screen
        if let screen = nsScreen {
            let info = DockInfo.detect(for: screen)
            state.dockInset = info.swiftUIInsets
            debugLog("📐 Dock detected: edge=\(info.edge.rawValue) thickness=\(info.thickness)")
        }
    }
    #endif

    @objc private func loginShieldDidShow(_ notification: Notification) {
        debugLog("🛡️ Login shield shown")
        // Belt-and-suspenders save — in the common case willstop fires
        // a moment earlier, but on macOS configurations where willstop
        // isn't delivered reliably this is still a guaranteed pre-death
        // hook since we observed the shield successfully.
        if !isUnderCompanion { saveProgress() }
        guard OverlayConfigManager.shared.config.hideOverlaysDuringLogin else { return }
        guard let view = overlayHostingView else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.allowsImplicitAnimation = true
            view.animator().alphaValue = 0
        }
    }

    @objc private func loginShieldDidHide(_ notification: Notification) {
        debugLog("🛡️ Login shield hidden")
        guard let view = overlayHostingView else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.allowsImplicitAnimation = true
            view.animator().alphaValue = 1
        }
    }

    @objc private func screensaverWillStop(_ notification: Notification) {
        debugLog("🛑 Screensaver will stop — flushing progress")
        saveProgress()
    }

    /// macOS sometimes places the screensaver window on one screen at
    /// `viewDidMoveToWindow` time and migrates it to its real target
    /// screen later. When that happens our cached `foundScreen` (and the
    /// resulting spanned-mode layer offset) is stale — the screen this
    /// view is now on doesn't match what we computed during initial setup.
    /// Re-run detection and rebuild the player layer frame so spanned
    /// mode tracks the new screen.
    @objc private func windowDidChangeScreen(_ notification: Notification) {
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        let beforeID = foundScreen?.id.description ?? "nil"
        let beforeOrigin = foundScreen.map { "\($0.zeroedOrigin)" } ?? "nil"
        let winFrameDesc = self.window.map { "\($0.frame)" } ?? "nil"
        debugLog("🔁 [\(ptr)] windowDidChangeScreen — wf:\(winFrameDesc) was id=\(beforeID) zorig=\(beforeOrigin)")

        detectScreen()

        let afterID = foundScreen?.id.description ?? "nil"
        let afterOrigin = foundScreen.map { "\($0.zeroedOrigin)" } ?? "nil"
        let changed = beforeID != afterID
        debugLog("🔁 [\(ptr)] windowDidChangeScreen — now id=\(afterID) zorig=\(afterOrigin) changed=\(changed)")

        if changed {
            if let layer = playerLayer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                configurePlayerLayerFrame(layer)
                CATransaction.commit()
            }

            // Re-resolve the per-screen overlay layout. macOS sometimes
            // moves a window to its real target screen after
            // viewDidMoveToWindow has already fired setupOverlays() —
            // without this swap, the migrated view keeps the original
            // screen's per-screen layout, so a multi-screen user with
            // `perScreen: true` sees the primary's overlays mirrored on
            // every screen instead of each screen's own configuration.
            if let state = overlayState, let screen = foundScreen {
                let cfUUID = CGDisplayCreateUUIDFromDisplayID(screen.id)
                if let uuid = cfUUID?.takeRetainedValue() {
                    let newUUID = CFUUIDCreateString(nil, uuid) as String
                    let layout = OverlayConfigManager.shared.layout(for: newUUID,
                                                                    isDesktop: isUnderCompanion)
                    state.replaceLayout(layout)
                    debugLog("🔁 [\(ptr)] overlay layout reapplied for new screen \(newUUID) (\(layout.allInstances.count) overlays)")
                }
            }
        }
    }

    // MARK: - Display Detection

    /// Detect which screen this view is displayed on
    private func detectScreen() {
        // The DisplayDetection singleton is process-wide and persists across
        // screensaver activations in the same appex process. `unusedScreens`
        // gets depleted by previous detection passes (and never refilled),
        // which would otherwise defeat the FIFO-by-size fallback used below.
        // Refresh on every detection — cheap, idempotent, and matches the
        // hot-plug refresh that already happens further down.
        displayDetection.detectDisplays()

        let ptr = Unmanaged.passUnretained(self).toOpaque()

        let winFrameDesc = self.window.map { "\($0.frame)" } ?? "nil"
        debugLog("[\(ptr)] w: \(self.window) wf:\(winFrameDesc) s:\(self.window?.screen)");

        // 1. Match by the window's global midpoint. `window.frame` is in
        //    global coordinates, so the midpoint always lands inside exactly
        //    one screen. This is preferred over the bridge UUID below because
        //    the bridge protocol assigns UUIDs by request order, which doesn't
        //    necessarily match the window→screen pairing macOS chose — a
        //    mismatch produces left/right inversion in spanned mode.
        if let win = self.window {
            let probe = CGPoint(x: win.frame.midX, y: win.frame.midY)
            if let screen = displayDetection.findScreenContaining(globalPoint: probe) {
                foundScreen = screen
                displayDetection.markScreenAsUsed(id: screen.id)
                debugLog("📺 Screen detected via window.frame midpoint \(probe): \(screen.description)")
                return
            }
        }

        // 2. Companion-mode UUID. When the view runs under the Companion app
        //    (desktop wallpaper mode), the screen UUID is passed in at init
        //    and we can resolve it directly. This branch never fires in the
        //    extension — it only has effect when companionDisplayUUID is set.
        if let uuidString = companionDisplayUUID,
           let cfUUID = CFUUIDCreateFromString(nil, uuidString as CFString) {
            let displayID = CGDisplayGetDisplayIDFromUUID(cfUUID)
            if displayID != kCGNullDirectDisplay,
               let screen = displayDetection.findScreenWith(id: displayID) {
                foundScreen = screen
                displayDetection.markScreenAsUsed(id: screen.id)
                debugLog("📺 Screen detected via Companion UUID: \(uuidString) → display \(displayID) → \(screen.description)")
                return
            } else if displayID != kCGNullDirectDisplay {
                // CG knows the display but DisplayDetection's cached list
                // doesn't — refresh and retry before giving up.
                debugLog("📺 Companion UUID \(uuidString) resolved to display \(displayID) but DisplayDetection has stale cache — refreshing")
                displayDetection.detectDisplays()
                if let screen = displayDetection.findScreenWith(id: displayID) {
                    foundScreen = screen
                    displayDetection.markScreenAsUsed(id: screen.id)
                    debugLog("📺 Screen detected via Companion UUID after refresh: \(uuidString) → display \(displayID) → \(screen.description)")
                    return
                }
                debugLog("📺 Companion UUID \(uuidString) still unmatched after refresh (displayID=\(displayID))")
            } else {
                debugLog("📺 Companion UUID \(uuidString) did not resolve to a display (displayID=\(displayID))")
            }
        }

        // 3. Fallback: FIFO depletion by size. Helps when window.frame is
        //    nil (rare) and we have no other signal.
        if let screen = displayDetection.alternateFindScreenWith(frame: self.frame) {
            foundScreen = screen
            debugLog("📺 Screen detected (FIFO fallback): \(screen.description)")
        } else if let screen = displayDetection.findScreenWith(frame: self.frame) {
            // 4. Last-resort: exact frame match. Known-broken on multi-display
            //    setups (matches only screens at origin (0,0)), kept solely so
            //    single-display users keep working if everything above missed.
            foundScreen = screen
            displayDetection.markScreenAsUsed(id: screen.id)
            debugLog("📺 Screen detected (frame fallback): \(screen.description)")
        } else {
            debugLog("📺 Could not detect screen for frame: \(self.frame)")
        }
    }

    /// Check if video should display on this screen based on preferences
    private func shouldDisplayOnThisScreen() -> Bool {
        // Under Companion, always display (Companion already chose this screen)
        if isUnderCompanion {
            return true
        }

        // In preview mode, always show
        if isPreview {
            return true
        }

        // Check display mode setting
        guard let screen = foundScreen else {
            // No screen detected, allow playback anyway
            return true
        }

        return displayDetection.isScreenActive(id: screen.id)
    }

    override func layout() {
        super.layout()

        // Update player layer frame based on viewing mode
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer = playerLayer {
            configurePlayerLayerFrame(layer)
        }
        CATransaction.commit()
    }

    // MARK: - Video Playback

    private func setupPlayerLayer() {
        guard playerLayer == nil, let parentLayer = self.layer else { return }

        let newPlayerLayer = AVPlayerLayer()
        newPlayerLayer.backgroundColor = NSColor.black.cgColor

        // Set video gravity based on aspect mode preference
        if PrefsDisplays.aspectMode == .fill {
            newPlayerLayer.videoGravity = .resizeAspectFill
        } else {
            newPlayerLayer.videoGravity = .resizeAspect
        }

        // Configure player layer frame based on viewing mode
        configurePlayerLayerFrame(newPlayerLayer)

        parentLayer.insertSublayer(newPlayerLayer, at: 0)
        newPlayerLayer.opacity = 0  // Start hidden; coordinator sets opacity when ready
        playerLayer = newPlayerLayer

        debugLog("Player layer created with viewing mode: \(PrefsDisplays.viewingMode), aspect mode: \(PrefsDisplays.aspectMode)")
    }

    /// Read the invertColors flag directly from companion.json (extension doesn't have Preferences).
    static func readInvertColorsFromCompanionJSON() -> Bool {
        let url = URL(fileURLWithPath: AerialPaths.baseDirectory)
            .appendingPathComponent("companion.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["invertColors"] as? Bool ?? false
    }

    /// Configure player layer frame based on viewing mode (independent, spanned, mirrored)
    private func configurePlayerLayerFrame(_ layer: AVPlayerLayer) {
        let viewingMode = PrefsDisplays.viewingMode

        switch viewingMode {
        case .spanned:
            // In spanned mode, calculate the layer position to show a portion of the full video
            if !isPreview, let screen = foundScreen {
                let zRect = displayDetection.getZeroedActiveSpannedRect()
                let tRect = CGRect(
                    x: zRect.origin.x - screen.zeroedOrigin.x,
                    y: zRect.origin.y - screen.zeroedOrigin.y,
                    width: zRect.width,
                    height: zRect.height
                )
                layer.frame = tRect
                debugLog("📺 Spanned mode - layer frame: \(tRect)")
            } else {
                layer.frame = bounds
            }

        case .mirrored:
            // In mirrored mode, flip every other display horizontally. Use
            // the per-view ordinal (assigned at init) instead of the array
            // index — the index would change as other views come and go,
            // causing a flicker on layout. The ordinal is stable per view.
            layer.frame = bounds
            if viewOrdinal % 2 == 1 {
                layer.transform = CATransform3DMakeAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
                debugLog("📺 Mirrored mode - view ord=\(viewOrdinal) flipped horizontally")
            }

        case .cloned, .independent:
            // Normal mode - each screen plays independently
            layer.frame = bounds
        }
    }

    private func stopPlayback() {
        // Save final progress before cleanup (extension only)
        if !isUnderCompanion, let position = coordinator?.getCurrentPosition() {
            ExtensionVideoLoader.shared.updateProgress(timestamp: position, screenUUID: coordinator?.screenUUID)
        }
        progressTimer?.invalidate()
        progressTimer = nil

        // Stop color animation
        colorTimer?.invalidate()
        colorTimer = nil
        fallbackLabel?.removeFromSuperview()
        fallbackLabel = nil

        // Reset opacity
        playerLayer?.opacity = 1.0

        // Clean up overlay system
        DistributedNotificationCenter.default.removeObserver(self)
        overlayState?.cleanup()
        overlayState = nil
        overlayHostingView?.removeFromSuperview()
        overlayHostingView = nil

        // Unregister from coordinator (coordinator handles player/looper/observer cleanup)
        coordinator?.unregister(delegate: self)
        coordinator = nil
        playerLayer?.player = nil

        debugLog("Playback stopped")
    }

    // MARK: - Battery Management

    /// Check if playback should be allowed based on battery status
    private func shouldPlayOnBattery() -> Bool {
        // Companion manages its own lifecycle — always allow
        if isUnderCompanion {
            return true
        }

        // In preview mode, always allow
        if isPreview {
            return true
        }

        let batteryMode = PrefsVideos.onBatteryMode

        switch batteryMode {
        case .keepEnabled:
            return true
        case .alwaysDisabled:
            if Battery.isUnplugged() {
                debugLog("🔋 On battery power - playback disabled (alwaysDisabled mode)")
                return false
            }
            return true
        case .disableOnLow:
            if Battery.isLow() {
                debugLog("🔋 Battery low (<20%) - playback disabled (disableOnLow mode)")
                return false
            }
            return true
        }
    }

    // MARK: - Fallback Color Animation

    private func startColorAnimation() {
        guard colorTimer == nil else { return }

        debugLog("Starting fallback color animation")

        showFallbackLabel()

        colorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.animateToNextColor()
        }
        animateToNextColor()
    }

    private func showFallbackLabel() {
        guard fallbackLabel == nil else { return }

        let label = NSTextField(labelWithString: "No videos found, please check your settings or download videos in Aerial.app")
        label.font = NSFont.systemFont(ofSize: 22, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        label.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.6)
            s.shadowBlurRadius = 6
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()

        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
        ])

        fallbackLabel = label
    }

    private func animateToNextColor() {
        colorIndex = (colorIndex + 1) % colors.count
        let nextColor = colors[colorIndex]

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 2.0
            let animation = CABasicAnimation(keyPath: "backgroundColor")
            animation.fromValue = self.layer?.backgroundColor
            animation.toValue = nextColor.cgColor
            animation.duration = 2.0
            self.layer?.add(animation, forKey: "backgroundColorAnimation")
            self.layer?.backgroundColor = nextColor.cgColor
        }
    }

    // MARK: - Keyboard Skip Support

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func keyDown(with event: NSEvent) {
        debugLog("⌨️ keyDown: keyCode=\(event.keyCode)")

        // Check if skips are allowed
        guard PrefsVideos.allowSkips else {
            self.nextResponder?.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 124:  // Right arrow - skip to next video
            if !isQuickFading {
                debugLog("⌨️ Right arrow - skipping to next video")
                let others = AerialSaverView.liveViews().filter { $0 !== self }
                if !others.isEmpty {
                    for view in others {
                        view.fastFadeOut(andPlayNext: false)
                    }
                    fastFadeOut(andPlayNext: true)
                } else {
                    fastFadeOut(andPlayNext: true)
                }
            } else {
                debugLog("⌨️ Right arrow locked (fade in progress)")
            }

        case 123:  // Left arrow - skip to previous video
            if !isQuickFading {
                debugLog("⌨️ Left arrow - skipping to previous video")
                let others = AerialSaverView.liveViews().filter { $0 !== self }
                if !others.isEmpty {
                    for view in others {
                        view.fastFadeOut(andPlayPrevious: false)
                    }
                    fastFadeOut(andPlayPrevious: true)
                } else {
                    fastFadeOut(andPlayPrevious: true)
                }
            } else {
                debugLog("⌨️ Left arrow locked (fade in progress)")
            }

        default:
            // Pass other keys to responder chain
            self.nextResponder?.keyDown(with: event)
        }
    }

    /// Quick fade out animation for video skip.
    /// - Parameters:
    ///   - andPlayNext: If true, plays the next video after fade completes.
    ///   - andPlayPrevious: If true, plays the previous video after fade completes.
    ///   Pass both as false for follower views that just fade without triggering playback.
    private func fastFadeOut(andPlayNext: Bool = false, andPlayPrevious: Bool = false) {
        guard let layer = playerLayer else { return }

        isQuickFading = true
        layer.removeAllAnimations()

        let fadeOutAnimation = CAKeyframeAnimation(keyPath: "opacity")
        fadeOutAnimation.values = [1, 0]
        fadeOutAnimation.keyTimes = [0, 1]
        fadeOutAnimation.duration = PrefsVideos.fadeDuration > 0 ? PrefsVideos.fadeDuration : 0.5
        fadeOutAnimation.delegate = self
        fadeOutAnimation.isRemovedOnCompletion = false
        fadeOutAnimation.calculationMode = .cubic

        let animName: String
        if andPlayNext {
            animName = "quickfadeandnext"
        } else if andPlayPrevious {
            animName = "quickfadeandprevious"
        } else {
            animName = "quickfade"
        }
        // Set model layer to final value BEFORE adding animation.
        // Without this, when the animation ends (default fillMode = .removed),
        // the presentation layer snaps to the stale model value (1.0) for one
        // frame before animationDidStop fires — causing a visible flash.
        layer.opacity = 0

        fadeOutAnimation.setValue(animName, forKey: "animationName")
        layer.add(fadeOutAnimation, forKey: animName)
    }

    // MARK: - Companion Control API

    func setUserPaused(_ paused: Bool) {
        coordinator?.setUserPaused(paused)
        #if COMPANION_APP
        if paused, isUnderCompanion {
            WallpaperContinuity.shared.refreshDesktopWallpaper(view: self)
        }
        #endif
    }
    func isUserPaused() -> Bool        { coordinator?.isPaused ?? false }
    func screensaverPause()            { coordinator?.screensaverPause() }
    func screensaverResume()           { coordinator?.screensaverResume() }
    func occlusionPause() {
        coordinator?.occlusionPause()
        #if COMPANION_APP
        if isUnderCompanion {
            WallpaperContinuity.shared.refreshDesktopWallpaper(view: self)
        }
        #endif
    }
    func occlusionResume()             { coordinator?.occlusionResume() }
    func batteryPause() {
        coordinator?.batteryPause()
        #if COMPANION_APP
        if isUnderCompanion {
            WallpaperContinuity.shared.refreshDesktopWallpaper(view: self)
        }
        #endif
    }
    func batteryResume()               { coordinator?.batteryResume() }

    func skipTo(playlistIndex: Int) {
        ExtensionVideoLoader.shared.seekPlaylist(to: playlistIndex, screenUUID: coordinator?.screenUUID)
        coordinator?.playNextVideo(skipFade: true)
    }

    /// Advance to the next playlist entry using the natural forward-
    /// scan semantics (honours time-of-day / availability filters).
    func skipToNext() {
        coordinator?.playNextVideo(skipFade: true)
    }

    /// Step back to the previous playlist entry using the dedicated
    /// backward-scan path (`popPreviousFromPlaylist`). Going through
    /// `playNextVideo` for this would scan FORWARD and produce wrong
    /// results once a time-of-day filter rejects the prev entry.
    func skipToPrevious() {
        coordinator?.playPreviousVideo(skipFade: true)
    }

    func getGlobalSpeed() -> Float  { coordinator?.getPlaybackSpeed() ?? 1.0 }
    func setGlobalSpeed(_ speed: Float) { coordinator?.setPlaybackSpeed(speed) }
    func setPlaybackRate(_ rate: Float) { coordinator?.setPlaybackRate(rate) }
    func getVideoFrameRate() -> Float { coordinator?.currentVideoFrameRate ?? 24.0 }

    func getCurrentPosition() -> Double? { coordinator?.getCurrentPosition() }
    func getCurrentVideoId() -> String? { currentVideo?.id }

    func seekTo(timestamp: Double) {
        let seekTime = CMTime(seconds: timestamp, preferredTimescale: 600)
        coordinator?.player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func reloadFromPlaylist(resumeTimestamp: Double?) {
        coordinator?.playNextVideo(skipFade: true, resumeTimestamp: resumeTimestamp)
    }

    // MARK: - Progress Timer (Extension)

    private func startProgressTimer() {
        // 2 s cadence: the sidecar write is atomic and tiny (~100 B),
        // so I/O churn is negligible, and it caps the worst-case resume
        // gap for users where no pre-death notification (willstop,
        // login shield) fires reliably.
        progressTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.saveProgress()
        }
    }

    private func saveProgress() {
        guard let position = coordinator?.getCurrentPosition() else { return }
        ExtensionVideoLoader.shared.updateProgress(timestamp: position, screenUUID: coordinator?.screenUUID)
    }

    #if COMPANION_APP
    /// One-shot accessor used by `WallpaperContinuity` (Companion-only).
    /// Returns the current pixel buffer plus the screen identity needed
    /// to address the matching wallpaper. Nil unless this view is running
    /// under Companion and its player has decoded at least one frame.
    func wallpaperContinuitySnapshot() -> (buffer: CVPixelBuffer, screenUUID: String, screen: NSScreen)? {
        guard isUnderCompanion,
              let buffer = coordinator?.captureCurrentFrame(),
              let uuid = companionDisplayUUID,
              let screen = NSScreen.getScreenByUuid(uuid) else { return nil }
        return (buffer, uuid, screen)
    }

    /// Cheap metadata accessor used by `WallpaperContinuity` to decide
    /// whether a planned write would be a no-op before doing the
    /// expensive pixel-buffer copy + JPEG encode. Returns the current
    /// video id, playhead in ms, and screen identity. Nil unless this
    /// view is running under Companion and has a video registered.
    func wallpaperContinuityIdentity() -> (videoID: String, timestampMs: Int64,
                                           screenUUID: String, screen: NSScreen)? {
        guard isUnderCompanion,
              let video = currentVideo,
              let coordinator = coordinator,
              let uuid = companionDisplayUUID,
              let screen = NSScreen.getScreenByUuid(uuid) else { return nil }
        let seconds = coordinator.player.currentTime().seconds
        let ms: Int64 = seconds.isFinite ? Int64(seconds * 1000) : 0
        return (video.id, ms, uuid, screen)
    }
    #endif

}

// MARK: - CAAnimationDelegate

extension AerialSaverView: CAAnimationDelegate {
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        isQuickFading = false
        playerLayer?.opacity = 0

        if let name = anim.value(forKey: "animationName") as? String {
            if name == "quickfadeandnext" {
                debugLog("⌨️ Fade complete - playing next video")
                playerLayer?.removeAllAnimations()
                coordinator?.playNextVideo(skipFade: true)
            } else if name == "quickfadeandprevious" {
                debugLog("⌨️ Fade complete - playing previous video")
                playerLayer?.removeAllAnimations()
                coordinator?.playPreviousVideo(skipFade: true)
            } else {
                debugLog("⌨️ Fade complete")
                playerLayer?.removeAllAnimations()
            }
        }
    }
}

// MARK: - PlayerCoordinatorDelegate

extension AerialSaverView: PlayerCoordinatorDelegate {
    func coordinatorDidStartVideo(_ video: AerialVideo, player: AVPlayer) {
        currentVideo = video
        // Opacity is managed by the coordinator (fade observer or skipFade)
        overlayState?.setVideo(video: video, player: player)

        // Start progress timer for position persistence (extension only, first video only)
        if !isUnderCompanion && progressTimer == nil {
            startProgressTimer()
        }

        // Wallpaper continuity refresh (Companion-only, gated inside the manager
        // by Preferences.replaceWallpaper).
        #if COMPANION_APP
        if isUnderCompanion {
            WallpaperContinuity.shared.handleNewDesktopVideo(view: self)
        }
        #endif

        debugLog("Coordinator: started \(video.secondaryName)")
    }

    func coordinatorDidUpdateFadeOpacity(_ opacity: Float) {
        guard !isQuickFading else { return }
        playerLayer?.opacity = opacity
    }

    func coordinatorDidFailToFindVideo() {
        debugLog("No video available — falling back to color animation")
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        startColorAnimation()
    }
}

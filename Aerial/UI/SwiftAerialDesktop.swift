//
//  SwiftAerialDesktop.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 15/08/2025.
//  Swift replacement for ObjC AerialDesktop, using direct compilation instead of dlopen
//

import Cocoa

class SwiftAerialDesktop: NSWindowController {
    private var aerialView: AerialSaverView?

    /// Authoritative target screen, set by `DesktopLauncher` before
    /// `windowDidLoad()` runs. Preferred over `window.screen`, which
    /// can resolve to the wrong display at hot-plug time while the
    /// nib-sized window's geometry is still settling — producing a
    /// mismatched UUID in `AerialSaverView` and the wrong playlist.
    var targetScreen: NSScreen?

    override var windowNibName: NSNib.Name? {
        return NSNib.Name("AerialDesktop")
    }

    override func windowDidLoad() {
        super.windowDidLoad()

        guard let window = window, let screen = targetScreen ?? window.screen else {
            errorLog("SwiftAerialDesktop: No window or screen available")
            return
        }

        // Create a new AerialSaverView with the screen UUID
        let frame = CGRect(x: 0, y: 0,
                          width: screen.frame.size.width,
                          height: screen.frame.size.height)

        let screenUUID = screen.screenUuid
        aerialView = AerialSaverView(frame: frame, screenUUID: screenUUID)

        guard let aerialView = aerialView else {
            errorLog("SwiftAerialDesktop: Failed to create AerialSaverView")
            return
        }

        // Set the aerial view as the window's content view
        // viewDidMoveToWindow() will trigger playback automatically
        window.contentView = aerialView

        // Suppress implicit Core Animation actions on the wallpaper
        // layer. When the screensaver dismisses, AppKit may relayer
        // / re-show our window, which without this triggers default
        // CAActions on `contents` / `opacity` / `bounds` — exactly
        // the "weird fade-in" the user is seeing. Populating the
        // `actions` dict with NSNull short-circuits the action
        // lookup chain (delegate → actions dict → defaultAction →
        // style) at the dictionary step so no animation is ever
        // produced for these property changes.
        aerialView.wantsLayer = true
        let nullAction = NSNull()
        aerialView.layer?.actions = [
            "contents":   nullAction,
            "opacity":    nullAction,
            "position":   nullAction,
            "bounds":     nullAction,
            "transform":  nullAction,
            "hidden":     nullAction,
            "onOrderIn":  nullAction,
            "onOrderOut": nullAction,
            "sublayers":  nullAction
        ]

        // Configure window for desktop wallpaper mode
        window.setFrame(screen.frame, display: true, animate: false)

        // Set window level below desktop icons
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)

        // Configure window behavior for desktop wallpaper.
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .transient,
            .ignoresCycle
        ]
        window.hasShadow = false
        window.canHide = false
        window.isOpaque = true
        window.isReleasedWhenClosed = false
        //window.canBecomeKey = false

        // Suppress AppKit's appear/disappear animation entirely. Set
        // here (after the nib has built the window) as belt-and-
        // braces in case `DesktopLauncher` set it earlier and
        // something else overwrote it.
        window.animationBehavior = .none

        // Ensure window content resizes with window
        window.contentView?.autoresizesSubviews = true

        // Refresh the dock-aware overlay shift when the screen layout changes
        // (user moves dock, toggles autohide, plugs/unplugs displays).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    //override var canBecomeKey: Bool { false }
    
    @objc private func screenParametersChanged() {
        aerialView?.applyDockInsetForCurrentScreen()
    }

    // MARK: - Control Methods

    func setUserPaused(_ paused: Bool) {
        aerialView?.setUserPaused(paused)
    }

    func screensaverPause() {
        rampTimer?.invalidate()
        rampTimer = nil
        aerialView?.screensaverPause()
    }

    func screensaverResume() {
        aerialView?.screensaverResume()
    }

    func occlusionPause() {
        aerialView?.occlusionPause()
    }

    func skipTo(playlistIndex: Int) {
        aerialView?.skipTo(playlistIndex: playlistIndex)
    }

    func skipToNext() {
        aerialView?.skipToNext()
    }

    func skipToPrevious() {
        aerialView?.skipToPrevious()
    }

    func getVideoFrameRate() -> Float {
        return aerialView?.getVideoFrameRate() ?? 24.0
    }

    func changeSpeed(_ speed: Float) {
        aerialView?.setGlobalSpeed(speed)
    }

    func stopScreensaver() {
        aerialView?.stopAnimation()
        aerialView = nil
    }

    func getSpeed() -> Float {
        return aerialView?.getGlobalSpeed() ?? 1.0
    }

    func getCurrentPosition() -> Double? {
        return aerialView?.getCurrentPosition()
    }

    func getCurrentVideoId() -> String? {
        return aerialView?.getCurrentVideoId()
    }

    func seekTo(timestamp: Double?) {
        guard let ts = timestamp, ts > 1.0 else { return }
        aerialView?.seekTo(timestamp: ts)
    }

    /// Reload video from playlist and optionally seek to a timestamp (for screensaver handoff).
    func reloadVideo(resumeTimestamp: Double?) {
        aerialView?.reloadFromPlaylist(resumeTimestamp: resumeTimestamp)
    }

    // MARK: - Animated Pause/Resume (Speed Ramp)

    private var rampTimer: Timer?

    /// Is the user holding an explicit pause? `nil` if the view isn't
    /// set up yet. Lets `DesktopLauncher` skip screensaver-transition
    /// speed ramps when the desktop should simply stay paused.
    func isUserPaused() -> Bool {
        aerialView?.isUserPaused() ?? false
    }

    /// Cubic ease-out: `1 - (1-t)³`. Most of the rate change happens in
    /// the first quarter of the ramp, with a barely-visible tail near
    /// the target. Used for both acceleration and deceleration so the
    /// video commits quickly to its new rate in either direction.
    private static func easeOutCubic(_ t: Float) -> Float {
        let inv = 1.0 - t
        return 1.0 - inv * inv * inv
    }

    /// `true` when the user has asked the system to reduce motion in
    /// Settings → Accessibility → Display. We honour this by snapping
    /// to target rates instead of running the ease-out timer.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Ramp the player rate from `startRate` to `target` over `duration`
    /// using a cubic ease-out so the new rate is reached quickly and
    /// settles gently. `completion` runs on the main thread once the
    /// target rate has been applied (or the ramp was interrupted). The
    /// existing `rampDownAndPause` / `resumeAndRampUp` remain the
    /// occlusion-path primitives.
    func rampRate(from startRate: Float,
                  to target: Float,
                  duration: TimeInterval,
                  completion: @escaping () -> Void = {}) {
        rampTimer?.invalidate()

        // Reduce Motion: skip the animation entirely.
        if reduceMotion {
            aerialView?.setPlaybackRate(max(target, 0.0))
            completion()
            return
        }

        aerialView?.setPlaybackRate(max(startRate, 0.0))
        let startTime = CACurrentMediaTime()

        rampTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(Float(elapsed / duration), 1.0)
            let eased = Self.easeOutCubic(t)
            let rate = startRate + (target - startRate) * eased

            if t >= 1.0 {
                timer.invalidate()
                self.rampTimer = nil
                self.aerialView?.setPlaybackRate(max(target, 0.0))
                completion()
            } else {
                self.aerialView?.setPlaybackRate(max(rate, 0.0))
            }
        }
    }

    func rampDownAndPause(duration: TimeInterval) {
        rampTimer?.invalidate()

        if reduceMotion {
            aerialView?.occlusionPause()
            return
        }

        let startRate = getSpeed()
        let startTime = CACurrentMediaTime()

        rampTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(Float(elapsed / duration), 1.0)
            let eased = Self.easeOutCubic(t)
            let rate = startRate * (1.0 - eased)

            if t >= 1.0 {
                timer.invalidate()
                self.rampTimer = nil
                self.aerialView?.occlusionPause()
            } else {
                self.aerialView?.setPlaybackRate(max(rate, 0.01))
            }
        }
    }

    func resumeAndRampUp(duration: TimeInterval) {
        rampTimer?.invalidate()

        if reduceMotion {
            let targetSpeed = getSpeed()
            aerialView?.occlusionResume()
            aerialView?.setGlobalSpeed(targetSpeed)
            return
        }

        let targetSpeed = getSpeed()
        aerialView?.occlusionResume()
        aerialView?.setPlaybackRate(0.01)
        let startTime = CACurrentMediaTime()

        rampTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(Float(elapsed / duration), 1.0)
            let eased = Self.easeOutCubic(t)
            let rate = targetSpeed * eased

            if t >= 1.0 {
                timer.invalidate()
                self.rampTimer = nil
                self.aerialView?.setGlobalSpeed(targetSpeed)
            } else {
                self.aerialView?.setPlaybackRate(max(rate, 0.01))
            }
        }
    }

}

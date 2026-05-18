//
//  DesktopLauncher.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 02/12/2020.
//

import AppKit

class DesktopLauncher : NSObject, NSWindowDelegate, DesktopOcclusionDelegate {
    let targetScreen: NSScreen
    let aerialDesktopController = SwiftAerialDesktop()
    var isRunning = false
    private var occlusionMonitor: DesktopOcclusionMonitor?
    private var positionTimer: Timer?

    /// Guards the screensaver-start handler against firing twice when
    /// both `willstart` and `didstart` are delivered.
    private var screensaverStartHandled = false

    /// Held while desktop mode is active to opt out of App Nap.
    /// Aerial's desktop window is never key (sits at `desktopWindow - 1`),
    /// so without this assertion macOS coalesces timers and throttles
    /// the rate at which AVFoundation pushes frames to AVPlayerLayer —
    /// visible as stutter even though `player.rate == 1.0`.
    /// `.latencyCritical` asks the scheduler for prompt, low-jitter
    /// servicing; `.userInitiatedAllowingIdleSystemSleep` lets the
    /// user's display-sleep preferences still apply.
    private var activityToken: NSObjectProtocol?

    /// Stable identifier for this launcher's screen, derived once from
    /// `targetScreen`'s CGDirectDisplayID. Exposed (not `private`) so
    /// PlaybackManager can key its per-screen occlusion map by it.
    var screenUUID: String? {
        guard let screenNumber = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        let cfUUID = CGDisplayCreateUUIDFromDisplayID(screenNumber)
        guard let uuid = cfUUID?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
    
    init(screen: NSScreen = NSScreen.main!) {
        self.targetScreen = screen
    }

    func toggleLauncher() {
        if !isRunning {
            // Consume any progress the extension wrote on its way out
            // while Companion kept running — otherwise we'd launch with
            // stale in-memory state and start from the wrong position.
            // Also mark for resume so popNextVideo honors the merged
            // playbackTimestamp on the first pop.
            PlaylistManager.shared.consumeExtensionProgressIfAvailable()
            PlaylistManager.shared.markForResume()

            // Set the authoritative target screen, then run the
            // wallpaper-mode setup. `setupWallpaperMode()` reads
            // `targetScreen` to derive screen.frame and the
            // AerialSaverView's UUID, so the assignment must come
            // first. The setup method is idempotent and internally
            // calls `window.setFrame(screen.frame, ...)` which gives
            // the correct full-screen origin AND size for the target
            // screen — no further setFrameOrigin needed afterwards
            // (a prior `setFrameOrigin(visibleFrame.origin)` here was
            // a leftover from the XIB flow where it ran BEFORE
            // windowDidLoad and got harmlessly overwritten; in the
            // programmatic flow it runs AFTER setupWallpaperMode and
            // would offset the window by the dock strip).
            aerialDesktopController.targetScreen = self.targetScreen
            aerialDesktopController.setupWallpaperMode()

            // Belt-and-braces — init and setupWallpaperMode both
            // set animationBehavior, but re-assert in case AppKit
            // defaults flipped somewhere between.
            aerialDesktopController.window!.animationBehavior = .none

            aerialDesktopController.showWindow(self)
            aerialDesktopController.window!.delegate = self
            aerialDesktopController.window!.toggleFullScreen(nil)
            aerialDesktopController.window!.makeKeyAndOrderFront(nil)
            aerialDesktopController.window!.level = NSWindow.Level.init(rawValue: Int(CGWindowLevelForKey(CGWindowLevelKey.desktopWindow)) - 1)
            NSApp.activate(ignoringOtherApps: true)

            // `willstart` arrives before the screensaver fade-in covers
            // the desktop, so we get a window to visibly ramp speed.
            // `didstart` is kept as a fallback — whichever fires first
            // wins via `screensaverStartHandled`.
            DistributedNotificationCenter.default().addObserver(self,
                selector: #selector(screensaverWillStart),
                name: Notification.Name("com.apple.screensaver.willstart"), object: nil)
            DistributedNotificationCenter.default().addObserver(self,
                selector: #selector(screensaverDidStart),
                name: Notification.Name("com.apple.screensaver.didstart"), object: nil)
            DistributedNotificationCenter.default().addObserver(self,
                selector: #selector(screensaverWillStop),
                name: Notification.Name("com.apple.screensaver.willstop"), object: nil)

            isRunning = true
            beginActivityIfNeeded()
            startOcclusionMonitorIfNeeded()
            positionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.saveDesktopPosition()
            }
        } else {
            // Flush the final position before tearing down — the player is
            // still alive here, which it won't be a few lines below.
            saveDesktopPosition()
            positionTimer?.invalidate()
            positionTimer = nil
            stopOcclusionMonitor()
            DistributedNotificationCenter.default().removeObserver(self)
            aerialDesktopController.window!.close()
            isRunning = false
        }
    }
    
    /// Safe teardown when the screen has been physically disconnected.
    /// Unlike toggleLauncher(), this doesn't force-unwrap the window.
    func cleanupForDisconnect() {
        guard isRunning else { return }
        // Capture wallpaper continuity frame(s) while the player is still
        // alive. No-op when the screen UUID has just been pulled — the
        // snapshot lookup will fail silently and we move on.
        WallpaperContinuity.shared.refreshAllActiveDesktopWallpapers()
        endActivityIfNeeded()
        positionTimer?.invalidate()
        positionTimer = nil
        stopOcclusionMonitor()
        DistributedNotificationCenter.default().removeObserver(self)
        aerialDesktopController.stopScreensaver()
        if let window = aerialDesktopController.window {
            window.close()
        }
        isRunning = false
    }

    func windowWillClose(_ notification: Notification) {
        debugLog("🖱️ windowWillClose")
        // Capture wallpaper continuity frame(s) before saveDesktopPosition /
        // stopScreensaver tear the AVPlayer down.
        WallpaperContinuity.shared.refreshAllActiveDesktopWallpapers()
        endActivityIfNeeded()
        // Capture the final position while the AVPlayer is still alive —
        // stopScreensaver below will tear it down.
        saveDesktopPosition()
        positionTimer?.invalidate()
        positionTimer = nil
        DistributedNotificationCenter.default().removeObserver(self)
        aerialDesktopController.stopScreensaver()
    }

    // MARK: - App Nap opt-out

    private func beginActivityIfNeeded() {
        guard activityToken == nil else { return }
        let options: ProcessInfo.ActivityOptions = [
            .userInitiated,
            .latencyCritical,
            .userInitiatedAllowingIdleSystemSleep
        ]
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: options,
            reason: "Aerial desktop playback")
        debugLog("DesktopLauncher: beginActivity (App Nap opt-out)")
    }

    private func endActivityIfNeeded() {
        guard let token = activityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        activityToken = nil
        debugLog("DesktopLauncher: endActivity")
    }
    
    func setUserPaused(_ paused: Bool) {
        debugLog("🖱️ set user paused: \(paused)")
        aerialDesktopController.setUserPaused(paused)
    }
    
    func skipTo(playlistIndex: Int) {
        debugLog("🖱️ skip to playlist index \(playlistIndex)")
        aerialDesktopController.skipTo(playlistIndex: playlistIndex)
    }

    func skipToNext() {
        debugLog("🖱️ skip to next")
        aerialDesktopController.skipToNext()
    }

    func skipToPrevious() {
        debugLog("🖱️ skip to previous")
        aerialDesktopController.skipToPrevious()
    }

    func changeSpeed(_ speed: Int) {
        debugLog("🖱️ Change speed")
        var fSpeed: Float  = 1.0
        if speed == 80 {
            fSpeed = 2/3
        } else if speed == 60 {
            fSpeed = 1/2
        } else if speed == 40 {
            fSpeed = 1/3
        } else if speed == 20 {
            fSpeed = 1/4
        } else if speed == 0 {
            fSpeed = 1/8
        }
        
        aerialDesktopController.changeSpeed(fSpeed)
    }

    // MARK: - Screensaver Notifications

    @objc private func screensaverWillStart(_ notification: Notification) {
        handleScreensaverStart()
    }

    @objc private func screensaverDidStart(_ notification: Notification) {
        handleScreensaverStart()
    }

    private func handleScreensaverStart() {
        guard !screensaverStartHandled else { return }
        screensaverStartHandled = true

        debugLog("Screensaver starting — saving position and pausing desktop")
        saveDesktopPosition()
        positionTimer?.invalidate()
        positionTimer = nil
        stopOcclusionMonitor()

        // Extension always plays at 1x; ease the desktop UP to 1.0 so
        // the visible handoff doesn't snap speeds. Start rate is 0 when
        // the desktop is user-paused (ease from paused to 1x) or the
        // user's desktop speed otherwise. The `isPaused` flag stays
        // true across the ramp — driving `rate` directly is enough for
        // the visual; `screensaverPause()` after the ramp restores the
        // "system paused" bookkeeping.
        let startRate: Float = aerialDesktopController.isUserPaused()
            ? 0.0
            : aerialDesktopController.getSpeed()

        // Write a handoff hint so the extension can continue the visual
        // ease from the same starting rate up to 1x. Drop the file if
        // writing fails — the extension falls back to a hard start.
        let handoff = PlaybackHandoff(startRate: startRate, writtenAt: Date())
        if let data = try? JSONEncoder().encode(handoff) {
            try? data.write(to: PlaybackHandoff.fileURL, options: .atomic)
            debugLog("Screensaver handoff hint: startRate=\(startRate)")
        }

        aerialDesktopController.rampRate(from: startRate, to: 1.0, duration: Self.screensaverRampDuration) { [weak self] in
            self?.aerialDesktopController.screensaverPause()
        }
    }

    @objc private func screensaverWillStop(_ notification: Notification) {
        // Arm the next cycle's start handler.
        screensaverStartHandled = false

        // Merge extension's progress sidecar (gets latest video + position)
        PlaylistManager.shared.syncFromExtension()

        // Delete stale sidecar so it doesn't overwrite desktop positions
        // on next extension activation
        JSONPreferencesStore.shared.delete(at: PlaylistProgressState.fileURL)

        let extensionTimestamp = PlaylistManager.shared.currentPlaybackTimestamp(for: screenUUID)
        let extensionEntry = PlaylistManager.shared.currentEntry(for: screenUUID)
        let desktopVideoId = aerialDesktopController.getCurrentVideoId()

        let tsText = extensionTimestamp.map { String(format: "%.1fs", $0) } ?? "nil"
        debugLog("Screensaver stopping — syncing from extension: \(extensionEntry?.videoName ?? "?") @ \(tsText)")

        if let entry = extensionEntry, let deskId = desktopVideoId, entry.videoId == deskId {
            // Same video — just seek and resume
            aerialDesktopController.seekTo(timestamp: extensionTimestamp)
        } else if extensionEntry != nil {
            // Different video — reload from playlist
            PlaylistManager.shared.markForResume()
            aerialDesktopController.reloadVideo(resumeTimestamp: extensionTimestamp)
        }

        // Compute occlusion BEFORE restarting monitor. Seed our local
        // state into PlaybackManager so the aggregate sees this screen,
        // then read back the *effective* state — in independent mode it's
        // just our own value, in shared modes it OR's across all active
        // screens, so a covered neighbour pauses us too.
        let isCurrentlyOccluded: Bool
        if Preferences.desktopAutoPause {
            let coverage = DesktopOcclusionMonitor.coverage(for: targetScreen.frame)
            let localOccluded = coverage >= Preferences.desktopAutoPauseThreshold
            // PlaybackManager is @MainActor; this call site runs from a
            // notification handler on the main thread (screensaver
            // willstart/didstart), so we can synchronously assume the
            // isolation rather than spinning up a Task that would defer
            // the seed past the launcher's own ramp setup below.
            isCurrentlyOccluded = MainActor.assumeIsolated {
                PlaybackManager.shared.seedOcclusionState(forScreenUUID: screenUUID ?? "",
                                                         isOccluded: localOccluded)
                return PlaybackManager.shared.effectiveOcclusionState(for: screenUUID ?? "")
            }
        } else {
            isCurrentlyOccluded = false
        }

        // Clear the screensaver pause flag up-front so the player is
        // free to run the ramp. The occlusion-pause flag, when
        // applicable, is applied *after* the ramp so the deceleration
        // is visible on whatever portion of the desktop isn't covered.
        aerialDesktopController.screensaverResume()

        // Ease the rate from 1.0 (what the extension was playing at)
        // down to the user's target. Target is the user's configured
        // desktop speed when playing, 0 when user-paused or occluded.
        // In the paused/occluded cases `isPaused` / post-ramp
        // `isOcclusionPaused` supply the semantic state; the ramp is
        // the visual deceleration, the final rate=0 matches it.
        let needsPausedLanding = aerialDesktopController.isUserPaused() || isCurrentlyOccluded
        let targetRate: Float = needsPausedLanding ? 0.0 : aerialDesktopController.getSpeed()
        aerialDesktopController.rampRate(from: 1.0, to: targetRate, duration: Self.screensaverRampDuration) { [weak self] in
            // After the ramp, restore the occlusion-paused bookkeeping
            // when applicable so subsequent monitor events see the
            // correct state. (User-paused needs no post-ramp action —
            // `isPaused` was already true from before the screensaver.)
            if isCurrentlyOccluded {
                self?.aerialDesktopController.occlusionPause()
            }
        }
        if isCurrentlyOccluded {
            debugLog("Desktop occluded (\(Int(DesktopOcclusionMonitor.coverage(for: targetScreen.frame) * 100))%) — ramping 1.0 → 0 then applying occlusion pause")
        }

        // Restart monitor with correct initial state + cooldown to prevent
        // immediate re-triggering during transition animations
        startOcclusionMonitorIfNeeded(initialOccluded: isCurrentlyOccluded)
        occlusionMonitor?.cooldown(seconds: rampCooldown)

        // Restart position timer
        positionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.saveDesktopPosition()
        }
    }

    private func saveDesktopPosition() {
        let position = aerialDesktopController.getCurrentPosition()
        PlaylistManager.shared.updatePlaybackTimestamp(position, for: screenUUID)
        // Desktop just wrote the authoritative position into
        // playlists.json. Drop any leftover sidecar so the next
        // extension activation doesn't override our fresh timestamp
        // with a stale one (mergeSidecarProgress compares updatedAt to
        // the playlist's generatedAt, which doesn't track position
        // updates — see the resume planning doc).
        JSONPreferencesStore.shared.delete(at: PlaylistProgressState.fileURL)
    }

    // MARK: - Occlusion Monitor

    private func startOcclusionMonitorIfNeeded(initialOccluded: Bool = false) {
        guard Preferences.desktopAutoPause else { return }
        let monitor = DesktopOcclusionMonitor(screenFrame: targetScreen.frame, initialOccluded: initialOccluded)
        monitor.delegate = self
        monitor.start()
        occlusionMonitor = monitor
    }

    private func stopOcclusionMonitor() {
        occlusionMonitor?.stop()
        occlusionMonitor = nil
    }

    // MARK: - Ramp Duration

    private var rampDuration: TimeInterval {
        aerialDesktopController.getVideoFrameRate() >= 60 ? 1.0 : 0.25
    }
    private var rampCooldown: TimeInterval { rampDuration + 5.0 }

    /// Duration for the speed ramp that bridges the desktop / extension
    /// transition. Long enough to feel like a genuine deceleration /
    /// acceleration rather than a visual snap.
    private static let screensaverRampDuration: TimeInterval = 1.5

    // MARK: - DesktopOcclusionDelegate

    func occlusionDidChange(isOccluded: Bool) {
        // Forward to PlaybackManager which owns the policy: in independent
        // mode this routes back to just our own apply* methods; in shared
        // viewing modes (spanned/cloned/mirrored) the manager applies the
        // aggregate to every running launcher so all screens pause/resume
        // together. The monitor delegate fires from a main-thread dispatch
        // (DesktopOcclusionMonitor.swift:72), so the synchronous
        // MainActor isolation hop is safe here.
        MainActor.assumeIsolated {
            PlaybackManager.shared.occlusionDidChange(forScreenUUID: screenUUID ?? "",
                                                     isOccluded: isOccluded)
        }
        occlusionMonitor?.cooldown(seconds: rampCooldown)
    }

    /// Apply the pause-on-occlusion ramp to this launcher's player.
    /// Called by PlaybackManager once it has decided this launcher should
    /// pause — either because its own screen is occluded (independent
    /// mode) or because some screen in the shared group is.
    func applyOcclusionPause() {
        debugLog("🖥️ Desktop occluded — ramping down and pausing (\(rampDuration))")
        aerialDesktopController.rampDownAndPause(duration: rampDuration)
    }

    /// Apply the resume ramp. Called by PlaybackManager when the
    /// effective occlusion state for this launcher's screen flips back
    /// to visible.
    func applyOcclusionResume() {
        debugLog("🖥️ Desktop visible — resuming and ramping up (\(rampDuration))")
        aerialDesktopController.resumeAndRampUp(duration: rampDuration)
    }

    /// Battery-driven pause. Direct (no ramp) because battery state
    /// changes are user-initiated events (plug/unplug, threshold cross)
    /// where an immediate state change reads as "Aerial noticed and
    /// reacted" rather than abrupt.
    func applyBatteryPause() {
        debugLog("🔋 Desktop battery pause — pausing playback")
        aerialDesktopController.batteryPause()
    }

    func applyBatteryResume() {
        debugLog("🔋 Desktop battery resume — resuming playback")
        aerialDesktopController.batteryResume()
    }

}

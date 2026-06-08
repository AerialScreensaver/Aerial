//
//  PlayerCoordinator.swift
//  AerialScreenSaverExtension
//
//  Owns the AVQueuePlayer and manages video selection, item replacement,
//  end-of-video observation, looping, and fading timing.
//
//  Two modes via factory method:
//  - Shared mode (cloned/mirrored/spanned): one static instance, single decode pipeline.
//  - Independent mode: each view gets its own instance.
//

import AVFoundation
import CoreImage
import AppKit
import QuartzCore

// MARK: - Delegate Protocol

protocol PlayerCoordinatorDelegate: AnyObject {
    /// New video started. View should update overlays.
    func coordinatorDidStartVideo(_ video: AerialVideo, player: AVPlayer)
    /// Fade opacity changed (driven by playback position). View should set playerLayer.opacity.
    func coordinatorDidUpdateFadeOpacity(_ opacity: Float)
    /// No video could be found. View should fall back to non-video content.
    func coordinatorDidFailToFindVideo()
}

// MARK: - PlayerCoordinator

final class PlayerCoordinator {

    // MARK: - Shared Instance

    private static var sharedInstance: PlayerCoordinator?

    /// Factory — returns shared singleton or new instance based on viewing mode.
    static func forCurrentMode(isVerticalScreen: Bool, screenUUID: String? = nil, isDesktop: Bool = false) -> PlayerCoordinator {
        let viewingMode = PrefsDisplays.viewingMode
        switch viewingMode {
        case .cloned, .mirrored, .spanned:
            if let existing = sharedInstance {
                return existing
            }
            let coordinator = PlayerCoordinator(isVertical: isVerticalScreen, isDesktop: isDesktop)
            sharedInstance = coordinator
            return coordinator
        case .independent:
            return PlayerCoordinator(isVertical: isVerticalScreen, screenUUID: screenUUID, isDesktop: isDesktop)
        }
    }

    /// Reset shared state (call when all views are torn down).
    static func resetShared() {
        sharedInstance?.cleanup()
        sharedInstance = nil
    }

    // MARK: - Properties

    /// The managed player (read-only externally).
    private(set) var player: AVQueuePlayer

    /// Current video being played.
    private(set) var currentVideo: AerialVideo?

    /// Pixel-buffer tap on the active item, used by the wallpaper-continuity
    /// feature in Companion. Attached when the AVPlayerItem is created in
    /// playVideo(); nil between videos.
    private var videoOutput: AVPlayerItemVideoOutput?

    /// Desired playback speed (persisted across video transitions).
    private var desiredSpeed: Float = 1.0

    /// Whether current playback is looping a single video.
    private var shouldLoop = false

    /// Looper for seamless single-video looping.
    private var playerLooper: AVPlayerLooper?

    /// Pending seek position for the "loop + resume" handoff:
    /// `AVPlayerLooper.init` doesn't synchronously populate
    /// `player.currentItem`, so a seek issued right after it is silently
    /// dropped. We stash the target here and apply it once the looper's
    /// first item actually becomes current (see `currentItemObserver`).
    private var pendingResumeSeek: CMTime?

    /// KVO observer on `player.currentItem`, installed only for the
    /// loop + resume case while we wait for the looper's first item to
    /// land. Self-invalidates once the seek + play sequence runs.
    private var currentItemObserver: NSKeyValueObservation?

    /// Observer for video-end notification.
    private var playerEndObserver: NSObjectProtocol?

    /// Periodic time observer token for position-driven fades.
    private var fadeObserverToken: Any?

    /// Duration of the current video (for fade calculations).
    private var currentVideoDuration: Double = 0

    // MARK: Bounded loop (per-video play-duration override)

    /// Periodic time observer driving the bounded-loop playtime accumulator.
    /// Separate from `fadeObserverToken` so teardown is independent. Installed
    /// only when an entry carries a `playDuration` override (multi-entry playlists).
    private var boundedLoopObserverToken: Any?

    /// Target playtime (video-content seconds) for the current bounded loop, or
    /// nil when the current video isn't bound-looping.
    private var boundedLoopTargetPlaytime: Double?

    /// Accumulated playtime (speed-factored video-content seconds) for the
    /// current bounded loop. Runtime-only; never persisted. Reset per video.
    private var boundedLoopAccumulatedPlaytime: Double = 0

    /// Monotonic timestamp (CACurrentMediaTime) of the previous accumulator
    /// tick. 0 means "seed on next tick" (also re-seeded across pauses).
    private var boundedLoopLastTick: CFTimeInterval = 0

    /// Guards against a re-entrant advance when the threshold is crossed on
    /// consecutive ticks before teardown runs.
    private var boundedLoopAdvancing = false

    /// Timer that advances to the next video when a live-stream entry
    /// has been playing for its configured duration. Live streams are
    /// indefinite so they never fire AVPlayerItemDidPlayToEndTime.
    private var liveAdvanceTimer: DispatchSourceTimer?

    /// Diagnostics attached for the current live entry. Tracks AVPlayer
    /// and AVPlayerItem state so a failed stream leaves breadcrumbs in
    /// the log instead of silently showing black.
    private var liveDiagnostics: LivePlaybackDiagnostics?

    /// Armed when AVPlayer enters a waiting/stalled state during live
    /// playback; fires after `liveStallTimeout` seconds to advance the
    /// playlist so we don't sit on a dead stream for the full
    /// `livePlaybackSeconds` window. Cancelled on any recovery event.
    private var liveStallWatchdog: DispatchSourceTimer?

    /// Ramps `player.rate` from whatever desktop hand us up to 1.0 on
    /// the first video of an extension activation. Consumes the
    /// `playback-handoff.json` hint that `DesktopLauncher` writes when
    /// the screensaver starts.
    private var handoffRampTimer: DispatchSourceTimer?

    /// True until the first `playVideo` in this coordinator's life has
    /// started. Guards the handoff ramp so rotation / skip don't each
    /// re-ramp mid-session.
    private var hasStartedFirstVideo = false

    /// Duration of the handoff ease-in on the extension side. Matches
    /// the desktop side's `screensaverRampDuration` so the overall
    /// deceleration / acceleration feels like one continuous arc.
    private static let handoffRampDuration: TimeInterval = 3.0

    /// How long AVPlayer may remain in a waiting/stalled state before
    /// the coordinator gives up and advances to the next playlist entry.
    /// Long enough to absorb a segment rotation + a brief network dip,
    /// short enough that a truly broken stream doesn't waste a full
    /// `livePlaybackSeconds` window.
    private static let liveStallTimeout: TimeInterval = 20

    /// Nominal framerate of the current video (for ramp duration decisions).
    private(set) var currentVideoFrameRate: Float = 24.0

    /// Whether the screen is vertical (for video selection).
    private let isVertical: Bool

    /// Screen UUID for per-screen playlist resolution (independent mode).
    /// Mutable so `AerialSaverView` can update it when macOS migrates the
    /// view's window to a different screen (independent mode each-view-own-
    /// coord scenario). Only `playNextVideo` / `playPreviousVideo` consult
    /// this — there's no derived state to invalidate when it changes; the
    /// next loader call simply uses the new UUID.
    var screenUUID: String?

    /// True when this coordinator drives desktop playback (Companion). Used
    /// to suppress position-driven opacity fades — desktop transitions are
    /// hard cuts so the menubar / wallpaper handoff doesn't show a fade.
    private let isDesktop: Bool

    /// Fade duration honoured by this coordinator. Always 0 in desktop
    /// mode (hard-cuts there) or when the user has Reduce Motion on in
    /// System Settings → Accessibility → Display; otherwise the user's
    /// `PrefsVideos.fadeDuration`.
    private var effectiveFadeDuration: Double {
        if isDesktop { return 0 }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return 0 }
        return PrefsVideos.fadeDuration
    }

    // MARK: - Delegates (weak references)

    private struct WeakDelegate {
        weak var value: PlayerCoordinatorDelegate?
    }
    private var delegates: [WeakDelegate] = []

    // MARK: - Init

    private init(isVertical: Bool, screenUUID: String? = nil, isDesktop: Bool = false) {
        self.isVertical = isVertical
        self.screenUUID = screenUUID
        self.isDesktop = isDesktop
        self.player = AVQueuePlayer()
        player.isMuted = PrefsAdvanced.muteSound
    }

    // MARK: - Registration

    /// Register a delegate and get back the managed player to assign to its layer.
    /// If a video is already playing, immediately notifies the delegate.
    func register(delegate: PlayerCoordinatorDelegate) -> AVQueuePlayer {
        delegates.append(WeakDelegate(value: delegate))
        debugLog("PlayerCoordinator: registered delegate (\(delegates.count) total)")

        // If video already playing, notify immediately so follower gets overlays
        if let video = currentVideo {
            delegate.coordinatorDidStartVideo(video, player: player)

            // Send current fade opacity so late-joining delegate matches
            if fadeObserverToken != nil {
                let seconds = CMTimeGetSeconds(player.currentTime())
                let opacity = opacityForCurrentPosition(seconds)
                delegate.coordinatorDidUpdateFadeOpacity(opacity)
            } else {
                // No fade observer (fades disabled or looping) — layer is fully opaque
                delegate.coordinatorDidUpdateFadeOpacity(1.0)
            }
        }

        return player
    }

    /// Unregister a delegate. When all delegates are gone, pauses the player.
    func unregister(delegate: PlayerCoordinatorDelegate) {
        delegates.removeAll { $0.value === delegate || $0.value == nil }
        debugLog("PlayerCoordinator: unregistered delegate (\(delegates.count) remaining)")

        if delegates.isEmpty {
            cleanup()
        }
    }

    /// Whether this delegate is the leader (first registrant).
    /// In shared mode, only the leader drives playback.
    func isLeader(_ delegate: PlayerCoordinatorDelegate) -> Bool {
        // Compact nil references
        delegates.removeAll { $0.value == nil }
        return delegates.first?.value === delegate
    }

    // MARK: - Playback Control

    /// Select and play the next video from the loader.
    /// - Parameters:
    ///   - skipFade: When true, skips position-driven fade-in (used for user-initiated skips).
    ///   - resumeTimestamp: Explicit resume position (for handoff). Loader's timestamp is used if nil.
    func playNextVideo(skipFade: Bool = false, resumeTimestamp: Double? = nil) {
        let loader = ExtensionVideoLoader.shared

        let result = loader.getNextVideo(isVertical: isVertical, screenUUID: screenUUID)
        shouldLoop = result.shouldLoop

        guard let video = result.video else {
            debugLog("PlayerCoordinator: No video returned from loader")
            for wrapper in delegates { wrapper.value?.coordinatorDidFailToFindVideo() }
            return
        }

        // Prefer explicit timestamp (handoff), fall back to loader's (auto-resume)
        let effectiveTimestamp = resumeTimestamp ?? result.resumeTimestamp

        debugLog("PlayerCoordinator: Next video: \(video.secondaryName), shouldLoop=\(result.shouldLoop), resumeAt=\(effectiveTimestamp.map { String(format: "%.1fs", $0) } ?? "nil")")
        playVideo(video, skipFade: skipFade, resumeTimestamp: effectiveTimestamp, playDuration: result.playDuration)
    }

    /// Select and play the previous video from the playlist (scans backward).
    func playPreviousVideo(skipFade: Bool = false) {
        let loader = ExtensionVideoLoader.shared

        guard let prev = loader.popPreviousFromPlaylist(screenUUID: screenUUID) else {
            debugLog("PlayerCoordinator: No playlist for previous, falling back to next")
            playNextVideo(skipFade: skipFade)
            return
        }
        shouldLoop = prev.shouldLoop

        debugLog("PlayerCoordinator: Previous video: \(prev.video.secondaryName), shouldLoop=\(prev.shouldLoop)")
        playVideo(prev.video, skipFade: skipFade, playDuration: prev.playDuration)
    }

    // MARK: - Pause / Resume / Speed

    /// Whether playback is currently paused by the user.
    private(set) var isPaused = false

    /// Whether playback has been paused because the screensaver started over the desktop.
    private var isScreensaverPaused = false

    /// Whether playback has been paused because the desktop is occluded by other windows.
    private var isOcclusionPaused = false

    /// Whether playback has been paused because the system is on battery
    /// (or low battery, depending on the user's `desktopPauseOnBatteryMode`).
    /// Distinct from `isPaused` (user) and `isOcclusionPaused` (occlusion)
    /// so the three signals compose without overwriting each other.
    private var isBatteryPaused = false

    /// Composite: any system-level pause is active.
    private var isSystemPaused: Bool { isScreensaverPaused || isOcclusionPaused || isBatteryPaused }

    func screensaverPause() {
        guard !isScreensaverPaused else { return }
        isScreensaverPaused = true
        player.pause()
        debugLog("PlayerCoordinator: screensaver pause")
    }

    func screensaverResume() {
        guard isScreensaverPaused else { return }
        isScreensaverPaused = false
        if !isPaused && !isOcclusionPaused {
            playAtDesiredSpeed()
        }
        debugLog("PlayerCoordinator: screensaver resume (playing=\(!isPaused && !isOcclusionPaused))")
    }

    func occlusionPause() {
        guard !isOcclusionPaused else { return }
        isOcclusionPaused = true
        player.pause()
        debugLog("PlayerCoordinator: occlusion pause")
    }

    func occlusionResume() {
        guard isOcclusionPaused else { return }
        isOcclusionPaused = false
        if !isPaused && !isScreensaverPaused && !isBatteryPaused {
            playAtDesiredSpeed()
        }
        debugLog("PlayerCoordinator: occlusion resume (playing=\(!isPaused && !isScreensaverPaused && !isBatteryPaused))")
    }

    func batteryPause() {
        guard !isBatteryPaused else { return }
        isBatteryPaused = true
        player.pause()
        debugLog("🔋 PlayerCoordinator: battery pause")
    }

    func batteryResume() {
        guard isBatteryPaused else { return }
        isBatteryPaused = false
        if !isPaused && !isScreensaverPaused && !isOcclusionPaused {
            playAtDesiredSpeed()
        }
        debugLog("🔋 PlayerCoordinator: battery resume (playing=\(!isPaused && !isScreensaverPaused && !isOcclusionPaused))")
    }

    func setUserPaused(_ paused: Bool) {
        isPaused = paused
        if isPaused {
            player.pause()
        } else if !isSystemPaused {
            playAtDesiredSpeed()
        }
        debugLog("PlayerCoordinator: setUserPaused → paused=\(isPaused)")
    }

    /// Current playback position in seconds, or nil if nothing is playing.
    func getCurrentPosition() -> Double? {
        guard player.currentItem != nil else { return nil }
        let seconds = CMTimeGetSeconds(player.currentTime())
        return seconds.isFinite ? seconds : nil
    }

    func getPlaybackSpeed() -> Float {
        return desiredSpeed
    }

    func setPlaybackSpeed(_ speed: Float) {
        desiredSpeed = speed
        // Don't override pause states. If we're paused for any reason, just
        // remember the desired speed — `playAtDesiredSpeed()` will apply it
        // when the system resumes naturally.
        let canApply = !isPaused && !isSystemPaused
        if canApply {
            player.rate = speed
        }
        debugLog("PlayerCoordinator: speed → \(speed) (applied=\(canApply))")
    }

    /// Set the AVPlayer rate directly without changing the saved desiredSpeed.
    /// Used for animated speed ramping.
    func setPlaybackRate(_ rate: Float) {
        player.rate = rate
    }

    /// Start or resume playback at the user's chosen speed.
    private func playAtDesiredSpeed() {
        if isPaused || isSystemPaused {
            debugLog("PlayerCoordinator: playAtDesiredSpeed suppressed (paused)")
            return
        }
        player.play()
        if desiredSpeed != 1.0 {
            player.rate = desiredSpeed
        }
    }

    /// Clean up all resources.
    func cleanup() {
        // Remove fade observer
        removeFadeObserver()

        // Remove bounded-loop accumulator
        removeBoundedLoopObserver()
        boundedLoopTargetPlaytime = nil
        boundedLoopAccumulatedPlaytime = 0
        boundedLoopAdvancing = false

        // Remove end observer
        if let observer = playerEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playerEndObserver = nil
        }

        // Cancel live advance timer
        cancelLiveAdvanceTimer()

        // Cancel any pending looper-resume seek
        cancelPendingResumeSeek()

        // Cancel any in-flight handoff ramp
        cancelHandoffRamp()

        // Stop looper
        playerLooper?.disableLooping()
        playerLooper = nil

        // Stop player
        player.pause()
        player.removeAllItems()

        currentVideo = nil
        debugLog("PlayerCoordinator: cleaned up")
    }

    // MARK: - Frame Capture

    /// Copy a pixel buffer at the player's current playhead. Returns nil if
    /// no item is loaded or the output hasn't decoded a buffer for that
    /// time yet. Used by the wallpaper-continuity feature in Companion.
    func captureCurrentFrame() -> CVPixelBuffer? {
        guard let output = videoOutput,
              let item = player.currentItem else { return nil }
        return output.copyPixelBuffer(forItemTime: item.currentTime(),
                                      itemTimeForDisplay: nil)
    }

    // MARK: - Private: Live Stream Advance

    /// Schedule a one-shot timer that rotates to the next playlist video
    /// after `seconds`. Cancels any previously-scheduled timer.
    private func scheduleLiveAdvance(after seconds: Double) {
        cancelLiveAdvanceTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            debugLog("PlayerCoordinator: live advance timer fired")
            self.playNextVideo()
        }
        timer.resume()
        liveAdvanceTimer = timer
    }

    private func cancelLiveAdvanceTimer() {
        liveAdvanceTimer?.cancel()
        liveAdvanceTimer = nil
        liveDiagnostics?.stop()
        liveDiagnostics = nil
        cancelLiveStallWatchdog()
    }

    private func attachLiveDiagnostics(player: AVPlayer, item: AVPlayerItem, label: String) {
        liveDiagnostics?.stop()
        let diag = LivePlaybackDiagnostics()
        diag.start(player: player, item: item, label: label) { line in
            debugLog("🔴 \(line)")
        }
        diag.onEvent = { [weak self] event in
            self?.handleLiveEvent(event)
        }
        liveDiagnostics = diag
    }

    /// React to structured AVPlayer events surfaced by
    /// `LivePlaybackDiagnostics`. Advances the playlist on unrecoverable
    /// failures, arms a stall watchdog on extended waits.
    private func handleLiveEvent(_ event: LivePlaybackDiagnostics.Event) {
        switch event {
        case .timeControlPlaying, .statusReady:
            cancelLiveStallWatchdog()
        case .timeControlWaiting, .playbackStalled:
            armLiveStallWatchdog()
        case .statusFailed, .failedToPlayToEnd:
            cancelLiveStallWatchdog()
            debugLog("🔴 live playback failed, advancing to next video")
            playNextVideo()
        }
    }

    private func armLiveStallWatchdog() {
        // Already armed; let it run its course rather than reset the
        // clock and accidentally stack waits.
        if liveStallWatchdog != nil { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.liveStallTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.liveStallWatchdog = nil
            debugLog("🔴 live playback stalled ≥ \(Int(Self.liveStallTimeout))s, advancing")
            self.playNextVideo()
        }
        timer.resume()
        liveStallWatchdog = timer
    }

    private func cancelLiveStallWatchdog() {
        liveStallWatchdog?.cancel()
        liveStallWatchdog = nil
    }

    // MARK: - Private: Looper Resume

    /// Wait until the `AVPlayerLooper`'s first copy of the template item
    /// actually becomes `player.currentItem`, then seek to the stashed
    /// resume position and start playback. Handles both the
    /// already-populated case (rare but possible) and the async case
    /// (observed in practice — see the nil `currentItem` we used to log
    /// as `status=-1`).
    private func scheduleLooperResumeSeek(to seekTime: CMTime) {
        cancelPendingResumeSeek()
        pendingResumeSeek = seekTime

        // Fast path: currentItem already exists, seek + play now.
        if player.currentItem != nil {
            performLooperResumeSeek()
            return
        }

        // Slow path: observe currentItem until the looper populates it.
        currentItemObserver = player.observe(\.currentItem, options: [.new]) { [weak self] p, _ in
            guard let self = self, p.currentItem != nil else { return }
            self.performLooperResumeSeek()
        }
    }

    private func performLooperResumeSeek() {
        guard let seekTime = pendingResumeSeek else { return }
        pendingResumeSeek = nil
        currentItemObserver?.invalidate()
        currentItemObserver = nil

        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            // Always play afterwards — even if the seek was interrupted
            // (`finished == false`), playback from wherever we landed is
            // strictly better than sitting paused.
            guard let self = self else { return }
            self.playAtDesiredSpeed()
            self.applyHandoffRampIfAvailable()
            debugLog("PlayerCoordinator: loop-resume seek done, playing at \(CMTimeGetSeconds(seekTime))s")
        }
    }

    private func cancelPendingResumeSeek() {
        pendingResumeSeek = nil
        currentItemObserver?.invalidate()
        currentItemObserver = nil
    }

    // MARK: - Private: Desktop → Extension Handoff Ramp

    /// On the first video of the extension's life, consume the
    /// `playback-handoff.json` hint left by Companion's
    /// `DesktopLauncher.handleScreensaverStart` and ease
    /// `player.rate` from the stored start rate up to 1.0 over
    /// `handoffRampDuration` seconds. Skipped when:
    ///  - we've already started a video (rotation, skip, etc.),
    ///  - the hint file isn't there (fresh cold-start, no Companion),
    ///  - the hint is older than `PlaybackHandoff.maxAge` seconds.
    ///
    /// Always runs after `playAtDesiredSpeed()` so the player is
    /// already playing at 1.0; we immediately override the rate down
    /// to the start value and then ramp back up.
    private func applyHandoffRampIfAvailable() {
        if hasStartedFirstVideo { return }
        hasStartedFirstVideo = true

        let fileURL = PlaybackHandoff.fileURL

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let handoff = try? JSONDecoder().decode(PlaybackHandoff.self, from: data) else {
            return
        }
        let age = Date().timeIntervalSince(handoff.writtenAt)
        guard age >= 0, age < PlaybackHandoff.maxAge else {
            // Stale file — clean it up so it doesn't linger indefinitely.
            debugLog("PlayerCoordinator: handoff hint stale (\(Int(age))s), skipping ramp")
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        // Leave the file in place: in independent multi-monitor mode
        // each screen has its own PlayerCoordinator and each must read
        // the hint to ramp. The file is atomically overwritten on the
        // next screensaver start, and the age guard above handles any
        // stale carry-over from an earlier session.
        let startRate = max(0.0, min(handoff.startRate, 1.0))
        debugLog("PlayerCoordinator: handoff ramp \(startRate) → 1.0 over \(Int(Self.handoffRampDuration))s")
        rampPlayerRate(from: startRate, to: 1.0, duration: Self.handoffRampDuration)
    }

    /// Generic rate-ramp for the handoff ease-in. Quadratic ease-IN
    /// (t * t) — slow at the start, accelerating toward `target`.
    /// This always runs in the accelerating direction (start < target)
    /// so the curve is hard-coded rather than direction-branched as in
    /// `SwiftAerialDesktop.rampRate`. Continuous at t=0 with the
    /// desktop side's ease-out tail, so no jerk across the handoff.
    /// Separate from `liveStallWatchdog` / `liveAdvanceTimer` so live
    /// playback can coexist.
    private func rampPlayerRate(from startRate: Float, to target: Float, duration: TimeInterval) {
        handoffRampTimer?.cancel()
        player.rate = max(0.0, startRate)
        let startTime = CACurrentMediaTime()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(Float(elapsed / duration), 1.0)
            let eased = t * t
            let rate = startRate + (target - startRate) * eased
            if t >= 1.0 {
                self.handoffRampTimer?.cancel()
                self.handoffRampTimer = nil
                self.player.rate = target
            } else {
                self.player.rate = max(0.0, rate)
            }
        }
        timer.resume()
        handoffRampTimer = timer
    }

    private func cancelHandoffRamp() {
        handoffRampTimer?.cancel()
        handoffRampTimer = nil
    }

    // MARK: - Private: Video Playback

    private func playVideo(_ video: AerialVideo, skipFade: Bool = false, resumeTimestamp: Double? = nil, playDuration: Double? = nil) {
        currentVideo = video

        // Live streams: use the URL directly (remote HLS / loopback HTTP).
        // Everything else: resolve the cached file on disk.
        let sourceURL: URL
        if video.isLive {
            sourceURL = video.url
            debugLog("🔴 Live URL for \(video.secondaryName): \(sourceURL.absoluteString)")
        } else {
            let localPath = ExtensionVideoLoader.shared.localPathFor(video: video)
            guard !localPath.isEmpty else {
                debugLog("PlayerCoordinator: No local path for video: \(video.secondaryName)")
                return
            }
            sourceURL = URL(fileURLWithPath: localPath)
            debugLog("PlayerCoordinator: Local path \(localPath) (format=\(PrefsVideos.videoFormat))")
        }

        // Create player item
        let playerItem = AVPlayerItem(url: sourceURL)

        // Apply color invert filter if enabled (accessibility).
        // Done via AVMutableVideoComposition so the inversion happens in
        // sRGB regardless of the source video's color space (P3, BT.2020, etc.).
        if AerialSaverView.readInvertColorsFromCompanionJSON() {
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            playerItem.videoComposition = AVMutableVideoComposition(
                asset: playerItem.asset,
                applyingCIFiltersWithHandler: { request in
                    let inSRGB = request.sourceImage.matchedFromWorkingSpace(to: srgb)!
                    let inverted = inSRGB.applyingFilter("CIColorInvert")
                    let backToWorking = inverted.matchedToWorkingSpace(from: srgb)!
                    request.finish(with: backToWorking, context: nil)
                })
        }

        #if COMPANION_APP
        // Tap pixel buffers off the active item for wallpaper-continuity.
        // Only attached under Companion — the extension never reads the
        // tap (`wallpaperContinuitySnapshot()` is COMPANION_APP-gated),
        // and an attached output forces AVFoundation's shared decode
        // path into whatever format we request, which would tone-map
        // HDR/Dolby Vision content for AVPlayerLayer too.
        //
        // No pixel-format constraint — AVFoundation hands back the
        // native (HDR-capable) format and CIImage handles the SDR
        // tone-map at JPEG-encode time inside WallpaperContinuity.
        // IOSurface-backed buffers stay zero-copy into CI.
        let outputAttrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: outputAttrs)
        playerItem.add(output)
        self.videoOutput = output
        #endif

        // Load framerate for ramp duration decisions
        Task {
            do {
                let tracks = try await playerItem.asset.load(.tracks)
                if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
                    let fps = try await videoTrack.load(.nominalFrameRate)
                    await MainActor.run { self.currentVideoFrameRate = fps }
                    debugLog("PlayerCoordinator: Framerate: \(fps) fps")
                }
            } catch {
                debugLog("PlayerCoordinator: Failed to load framerate: \(error.localizedDescription)")
            }
        }

        // Discard any previous looper
        playerLooper?.disableLooping()
        playerLooper = nil

        // Tear down any previous bounded-loop accumulator BEFORE arming the
        // next video. playVideo is the funnel for every transition, so doing
        // this here guarantees a stale accumulator can't fire on the next
        // (possibly non-bounded) video.
        removeBoundedLoopObserver()
        boundedLoopTargetPlaytime = nil
        boundedLoopAccumulatedPlaytime = 0
        boundedLoopAdvancing = false

        // Remove previous end observer
        if let observer = playerEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playerEndObserver = nil
        }

        // Cancel any pending live-stream advance timer from a previous video.
        cancelLiveAdvanceTimer()

        // Clear any pending resume-seek state from a previous video so a
        // rapid switch can't race a late KVO callback into seeking the
        // wrong item.
        cancelPendingResumeSeek()

        // Resume is one-shot from ExtensionVideoLoader — if we got a
        // meaningful timestamp, this playthrough must start there.
        let isResuming = resumeTimestamp != nil && (resumeTimestamp ?? 0) > 1.0

        // Will be true when we hand playback off to the async resume
        // path (see below); suppresses the synchronous playAtDesiredSpeed
        // call at the end of this function.
        var deferredPlay = false

        if video.isLive {
            // Live stream — no looper (duration is indefinite), no end
            // observer (never fires), no fade observer (no known duration).
            // Advance is driven by a wall-clock timer.
            player.removeAllItems()
            player.insert(playerItem, after: nil)
            scheduleLiveAdvance(after: video.livePlaybackSeconds)
            attachLiveDiagnostics(player: player, item: playerItem, label: video.secondaryName)
            debugLog("PlayerCoordinator: Live mode for \(video.secondaryName), advance in \(video.livePlaybackSeconds)s")
        } else if shouldLoop {
            // Seamless looping via AVPlayerLooper. Handles resume too —
            // because the looper's currentItem lands asynchronously, we
            // can't synchronously seek right after init. When resuming
            // we arm a KVO observer that seeks + plays once the first
            // item becomes current; otherwise we play right away.
            playerLooper = AVPlayerLooper(player: player, templateItem: playerItem)
            if isResuming, let timestamp = resumeTimestamp {
                let seekTime = CMTime(seconds: timestamp, preferredTimescale: 600)
                debugLog("PlayerCoordinator: Looping mode for \(video.secondaryName) (resume \(timestamp)s, deferred)")
                scheduleLooperResumeSeek(to: seekTime)
                deferredPlay = true
            } else {
                debugLog("PlayerCoordinator: Looping mode for \(video.secondaryName)")
            }
        } else if let target = playDuration, target > 0 {
            // Bounded loop: an entry-level play-duration override on a
            // multi-entry playlist. Loop the video seamlessly (same machinery
            // as the forever-loop) but advance to the next entry once `target`
            // seconds of PLAYTIME (speed-factored video-content time) elapse.
            // (isLive is excluded by branch order — live wins above.)
            playerLooper = AVPlayerLooper(player: player, templateItem: playerItem)
            boundedLoopTargetPlaytime = target
            boundedLoopAccumulatedPlaytime = 0
            if isResuming, let timestamp = resumeTimestamp {
                // Resume the picture where we left off (reusing the seamless-loop
                // resume seek); the play-duration budget restarts from 0.
                let seekTime = CMTime(seconds: timestamp, preferredTimescale: 600)
                debugLog("PlayerCoordinator: Bounded loop for \(video.secondaryName) (play \(Int(target))s, resume \(timestamp)s, deferred)")
                scheduleLooperResumeSeek(to: seekTime)
                deferredPlay = true
            } else {
                debugLog("PlayerCoordinator: Bounded loop for \(video.secondaryName) (play \(Int(target))s)")
            }
            installBoundedLoopObserver()
        } else {
            // Normal rotation — `player.insert` sets currentItem
            // synchronously, so a straight seek right below works.
            player.removeAllItems()
            player.insert(playerItem, after: nil)

            setupPlayerEndObserver(for: playerItem)

            // Setup position-driven fades
            removeFadeObserver()
            if !skipFade && effectiveFadeDuration > 0 {
                loadVideoDuration(playerItem: playerItem) { [weak self] duration in
                    guard let self = self else { return }
                    debugLog("PlayerCoordinator: Duration loaded: \(duration)s")
                    self.currentVideoDuration = duration
                    self.installFadeObserver()
                }
            }

            debugLog("PlayerCoordinator: Rotation mode for \(video.secondaryName)\(isResuming ? " (resume)" : "")")
        }

        // Seek to resume position in the rotation branch only — the looper
        // branches (forever-loop AND bounded loop) handle their own seek
        // asynchronously above, and live streams ignore resume.
        if !video.isLive && !shouldLoop && (playDuration ?? 0) <= 0, let timestamp = resumeTimestamp, timestamp > 1.0 {
            let seekTime = CMTime(seconds: timestamp, preferredTimescale: 600)
            player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        // Start fully opaque when resuming mid-video, skipping the fade,
        // fades are disabled, we're looping, or we're streaming a live
        // feed. All of those paths skip the fade observer entirely.
        let skipInitialFade = isResuming || skipFade || effectiveFadeDuration == 0
            || shouldLoop || video.isLive || (playDuration ?? 0) > 0
        notifyFadeOpacity(skipInitialFade ? 1.0 : 0)

        // Start playback. Skip when the looper-resume path has taken
        // ownership — it plays after its seek completes.
        if !deferredPlay {
            playAtDesiredSpeed()
            applyHandoffRampIfAvailable()
        }
        debugLog("PlayerCoordinator: after play() — rate=\(player.rate), status=\(player.currentItem?.status.rawValue ?? -1)\(deferredPlay ? " (deferred)" : "")")

        // Notify delegates: new video started
        notifyDidStartVideo(video)

        // Notify Companion app so it can update the popover
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.glouel.aerial.nextvideo"),
            object: video.secondaryName
        )
    }

    // MARK: - Private: End Observer

    private func setupPlayerEndObserver(for item: AVPlayerItem) {
        playerEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handleVideoEnd()
        }
    }

    private func handleVideoEnd() {
        debugLog("PlayerCoordinator: Video ended, playing next")
        playNextVideo()
    }

    // MARK: - Private: Bounded Loop

    /// Playtime (video-content seconds) elapsed over a wall-clock interval at a
    /// given player rate. Speed-factored by `rate`; clamped so a single large
    /// gap (resume from suspension/occlusion) can't overshoot the target.
    /// Pure + static for unit testing.
    static func boundedLoopAdvanceDelta(wallDelta: Double, rate: Float, maxWallDelta: Double = 1.0) -> Double {
        guard rate > 0, wallDelta > 0 else { return 0 }
        return min(wallDelta, maxWallDelta) * Double(rate)
    }

    /// Arm the periodic observer that accumulates playtime for a bounded loop.
    /// Fires only while the player is actually playing, so pauses don't accrue.
    private func installBoundedLoopObserver() {
        removeBoundedLoopObserver()
        guard boundedLoopTargetPlaytime != nil else { return }
        boundedLoopLastTick = 0   // seed on the first ticking sample
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        boundedLoopObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.boundedLoopTick()
        }
    }

    private func boundedLoopTick() {
        guard let target = boundedLoopTargetPlaytime, !boundedLoopAdvancing else { return }
        let now = CACurrentMediaTime()
        let rate = player.rate
        // Seed on first tick, and re-seed across pauses (rate <= 0) without
        // accruing the gap. Playtime advances at `rate`, so a paused player
        // (rate 0) contributes nothing.
        if boundedLoopLastTick == 0 || rate <= 0 {
            boundedLoopLastTick = now
            return
        }
        let wallDelta = now - boundedLoopLastTick
        boundedLoopLastTick = now
        boundedLoopAccumulatedPlaytime += PlayerCoordinator.boundedLoopAdvanceDelta(wallDelta: wallDelta, rate: rate)
        if boundedLoopAccumulatedPlaytime >= target {
            boundedLoopAdvancing = true
            debugLog("PlayerCoordinator: bounded loop reached \(Int(target))s playtime, advancing")
            playNextVideo()
        }
    }

    private func removeBoundedLoopObserver() {
        if let token = boundedLoopObserverToken {
            player.removeTimeObserver(token)
            boundedLoopObserverToken = nil
        }
    }

    // MARK: - Private: Duration Loading

    private func loadVideoDuration(playerItem: AVPlayerItem, completion: @escaping (Double) -> Void) {
        let asset = playerItem.asset

        Task {
            do {
                let duration = try await asset.load(.duration)
                let durationSeconds = CMTimeGetSeconds(duration)
                if durationSeconds.isFinite && durationSeconds > 0 {
                    await MainActor.run { completion(durationSeconds) }
                } else {
                    await MainActor.run { completion(0) }
                }
            } catch {
                debugLog("PlayerCoordinator: Failed to load duration: \(error.localizedDescription)")
                await MainActor.run { completion(0) }
            }
        }
    }

    // MARK: - Private: Delegate Notifications

    private func notifyDidStartVideo(_ video: AerialVideo) {
        for wrapper in delegates {
            wrapper.value?.coordinatorDidStartVideo(video, player: player)
        }
    }

    private func notifyFadeOpacity(_ opacity: Float) {
        for wrapper in delegates {
            wrapper.value?.coordinatorDidUpdateFadeOpacity(opacity)
        }
    }

    // MARK: - Position-Driven Fades

    /// Compute opacity for the current playback position.
    private func opacityForCurrentPosition(_ seconds: Double) -> Float {
        let fade = effectiveFadeDuration
        guard fade > 0, currentVideoDuration > 0 else { return 1.0 }

        // Fade in at start
        if seconds < fade {
            return Float(seconds / fade)
        }
        // Fade out at end
        let fadeOutStart = currentVideoDuration - fade
        if seconds > fadeOutStart {
            return Float((currentVideoDuration - seconds) / fade)
        }
        return 1.0
    }

    /// Install a periodic time observer that drives fade opacity from playback position.
    private func installFadeObserver() {
        removeFadeObserver()
        guard currentVideoDuration > 0 else { return }

        let interval = CMTime(seconds: 0.05, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        fadeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite else { return }
            let opacity = self.opacityForCurrentPosition(seconds)
            self.notifyFadeOpacity(opacity)
        }
    }

    /// Remove the fade time observer.
    private func removeFadeObserver() {
        if let token = fadeObserverToken {
            player.removeTimeObserver(token)
            fadeObserverToken = nil
        }
    }

}

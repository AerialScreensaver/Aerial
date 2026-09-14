// Live-feed engine: plays remote HLS streams on the wallpaper.
//
// AVAssetReader (the file engine) cannot read streaming assets, so live
// feeds use a headless AVPlayer + AVPlayerItemVideoOutput bridge: a
// pull timer copies each new pixel buffer, wraps it in a
// DisplayImmediately CMSampleBuffer, and fans it out to the same
// AVSampleBufferDisplayLayer subscribers the file engine feeds. No
// AVPlayerLayer (doesn't work in remote CAContexts) and no shared
// CMTimebase — live frames display as they arrive, always at 1.0×.
//
// Lifecycle quirks handled here:
//  - yt-dlp-resolved URLs expire (~hours): the stall watchdog rebuilds
//    the item from a fresh URL (the handler hook re-reads entries.json
//    after the Companion's TTL-gated re-resolve), then falls back to a
//    cached file after repeated failures.
//  - Rotation after `playSeconds` re-pops the playlist: live→live
//    replaces the item in place (free URL refresh), live→file asks the
//    handler to swap the whole renderer.
//  - Deep pause tears the player down after 30 s (streams hold network
//    connections); resume rebuilds from a fresh URL.

import AppKit
import AVFoundation
import CoreImage
import CoreMedia

final class LiveStreamRenderer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "aerial-wallpaper-live-renderer", qos: .userInitiated)

    private(set) var streamURL: URL
    private var videoId: String
    private var feedName: String
    private let playSeconds: Double

    private var player: AVPlayer?
    private var itemOutput: AVPlayerItemVideoOutput?
    private var formatDescription: CMVideoFormatDescription?

    private var isRunning = true
    private(set) var isPaused = false
    private var pauseReasons: PauseReasons = []
    private var screensaverSubscriberCount = 0
    private var screensaverActiveFromNotification = false
    private var lockedScreenCount = 0
    private var deepPauseTimer: (any DispatchSourceTimer)?
    /// Player torn down by a deep pause — resume must rebuild.
    private var deepPaused = false

    private var pullTimer: (any DispatchSourceTimer)?
    private var rotationTimer: (any DispatchSourceTimer)?

    /// Companion's audio intent (owner policy folded in by the handler).
    /// Live streams always run at 1.0×, so unlike the file engine there
    /// is no rate gate — just mute/volume on the headless player, and
    /// silence on the lock screen. Queue-confined.
    private var audioEnabled = false
    private var audioVolume: Float = 0.5

    private(set) var subscribers: [AVSampleBufferDisplayLayer] = []
    private var lastSample: CMSampleBuffer?
    private var lastFrameAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var framesEnqueued: Int = 0
    /// Stall-recovery ladder position; resets when frames flow again.
    private var recoveryAttempts = 0
    /// Throttle for the failed-renderer 🚑 log in the 60 Hz pull loop.
    private var lastFailedFlushLogAt: CFAbsoluteTime = 0

    // MARK: - Handler hooks (installed at creation, off-protocol)

    /// Pop the next/previous playlist entry (same selection layer as the
    /// file engine). `.live` rotates in place; `.file` triggers
    /// `requestRendererSwitch`.
    var selectNext: (() -> PlaybackSelection?)?
    var selectPrevious: (() -> PlaybackSelection?)?
    /// The popped entry needs the other engine — the handler tears this
    /// renderer down and builds the right one in its place.
    var requestRendererSwitch: ((PlaybackSelection) -> Void)?
    /// Stall recovery: re-read the live source from disk and return a
    /// fresh stream URL for the given feed id (nil = feed gone).
    var refreshStreamURL: ((String) -> URL?)?
    /// Recovery exhausted — show any cached file instead of a dead feed.
    var requestCachedFallback: (() -> Void)?
    /// Video changed (rotation) — handler debounces a status write.
    var onVideoChanged: (() -> Void)?

    // MARK: - Construction

    init(selection: PlaybackSelection) {
        guard case let .live(url, videoId, name, playSeconds) = selection else {
            preconditionFailure("LiveStreamRenderer requires a .live selection")
        }
        self.streamURL = url
        self.videoId = videoId
        self.feedName = name
        self.playSeconds = max(playSeconds, 10)
    }

    /// Build the player + output and start pulling. Mirrors
    /// `VideoRenderer.start()` in the creation flow.
    func start() {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            buildPlayer(url: streamURL)
            scheduleRotation()
        }
    }

    func stop() {
        queue.sync {
            isRunning = false
            teardownPlayer()
            rotationTimer?.cancel()
            rotationTimer = nil
            cancelDeepPauseTimer()
        }
    }

    // MARK: - Player pipeline (on queue)

    private func buildPlayer(url: URL) {
        teardownPlayer()

        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.isMuted = true   // applyAudioToPlayer() decides below
        player.allowsExternalPlayback = false
        // Default true would keep the display awake forever under a
        // live wallpaper.
        player.preventsDisplaySleepDuringVideoPlayback = false

        self.player = player
        self.itemOutput = output
        self.formatDescription = nil
        self.lastFrameAt = CFAbsoluteTimeGetCurrent()
        applyAudioToPlayer()

        debugLog("  [LiveStream] playing \(feedName) — \(url.absoluteString.prefix(96))…")
        if !effectivePaused {
            player.play()
            startPulling()
        }
    }

    private func teardownPlayer() {
        stopPulling()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        itemOutput = nil
        formatDescription = nil
    }

    /// Pull at 60 Hz: cheap `hasNewPixelBuffer` checks, a copy + fan-out
    /// only when the stream produced a frame (feeds are 25-30 fps).
    private func startPulling() {
        stopPulling()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.pullFrame()
        }
        pullTimer = timer
        timer.resume()
    }

    private func stopPulling() {
        pullTimer?.cancel()
        pullTimer = nil
    }

    private func pullFrame() {
        guard isRunning, let output = itemOutput, let item = player?.currentItem else { return }
        let itemTime = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            return
        }

        // ABR streams switch resolution mid-flight — recreate the format
        // description whenever it stops matching the buffer.
        if formatDescription.map({ CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer) }) != true {
            var desc: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &desc
            )
            formatDescription = desc
        }
        guard let desc = formatDescription else { return }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: itemTime, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        guard let sample, let immediate = VideoRenderer.displayImmediatelyCopy(of: sample) else { return }

        for layer in subscribers {
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed {
                // A failed renderer silently drops enqueues — a frozen
                // window. Flush revives it; the enqueue below re-primes it
                // with this very frame. Log throttled (this is a 60 Hz loop).
                if CFAbsoluteTimeGetCurrent() - lastFailedFlushLogAt > 2 {
                    lastFailedFlushLogAt = CFAbsoluteTimeGetCurrent()
                    let err = renderer.error.map { String(describing: $0) } ?? "no error"
                    debugLog("🚑 [LiveStream] subscriber renderer failed (\(err)) — flushing")
                }
                renderer.flush()
            } else if renderer.requiresFlushToResumeDecoding {
                renderer.flush()
            }
            renderer.enqueue(immediate)
        }
        lastSample = immediate
        lastFrameAt = CFAbsoluteTimeGetCurrent()
        framesEnqueued &+= 1
        recoveryAttempts = 0
    }

    // MARK: - Rotation

    private func scheduleRotation() {
        rotationTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + playSeconds)
        timer.setEventHandler { [weak self] in
            guard let self, isRunning else { return }
            debugLog("  [LiveStream] rotation after \(Int(playSeconds))s")
            rotate(using: selectNext)
        }
        rotationTimer = timer
        timer.resume()
    }

    /// Pop the playlist and act on the result: live → replace the item
    /// in place (fresh URL even for the same feed — free expiry refresh);
    /// file → hand the slot back to the file engine.
    private func rotate(using select: (() -> PlaybackSelection?)?) {
        guard let selection = select?() else {
            // Nothing else to play — keep the current stream and retry
            // at the next rotation window.
            scheduleRotation()
            return
        }
        switch selection {
        case .live(let url, let videoId, let name, _):
            streamURL = url
            self.videoId = videoId
            self.feedName = name
            buildPlayer(url: url)
            scheduleRotation()
            onVideoChanged?()
        case .file:
            debugLog("  [LiveStream] next entry is a file — requesting renderer switch")
            requestRendererSwitch?(selection)
        }
    }

    // MARK: - Stall watchdog / recovery

    /// How long the stream may go without producing a frame while
    /// nominally playing before recovery kicks in (old PlayerCoordinator
    /// used 20 s; the 2 s health cadence makes 15 s comfortable).
    private static let stallTimeout: CFAbsoluteTime = 15

    func checkFeedHealth() {
        queue.async { [weak self] in
            guard let self, isRunning, !isPaused, player != nil else { return }
            let failed = player?.currentItem?.status == .failed
            let starved = CFAbsoluteTimeGetCurrent() - lastFrameAt > Self.stallTimeout
            guard failed || starved else { return }

            recoveryAttempts += 1
            debugLog("⚠️ [LiveStream] \(feedName) \(failed ? "item failed" : "stalled") — recovery attempt \(recoveryAttempts)")
            if recoveryAttempts <= 3 {
                // Fresh URL from disk (picks up the Companion's
                // TTL-gated re-resolve), rebuild the pipeline.
                if let fresh = refreshStreamURL?(videoId) {
                    streamURL = fresh
                }
                lastFrameAt = CFAbsoluteTimeGetCurrent()   // full window for the rebuild
                buildPlayer(url: streamURL)
            } else {
                debugLog("⚠️ [LiveStream] \(feedName) unrecoverable — falling back to cached video")
                requestCachedFallback?()
            }
        }
    }

    // MARK: - Pause-reason model (mirrors VideoRenderer semantics)

    private var pauseInhibited: Bool {
        screensaverSubscriberCount > 0 || screensaverActiveFromNotification || lockedScreenCount > 0
    }

    private var effectivePaused: Bool {
        pauseReasons.contains(.policy) || (!pauseReasons.isEmpty && !pauseInhibited)
    }

    /// Converge the player to the current intent. Live pauses are
    /// instant (a stream can't ease its rate; the fps slowdown rule
    /// would give 0.25 s anyway).
    private func convergePlaybackState(context: String) {
        guard isRunning else { return }
        if effectivePaused {
            guard !isPaused else { return }
            isPaused = true
            player?.pause()
            stopPulling()
            rotationTimer?.cancel()
            scheduleDeepPause()
            debugLog("  [LiveStream] paused [\(pauseReasons.summary)] \(context)")
        } else {
            guard isPaused else { return }
            isPaused = false
            cancelDeepPauseTimer()
            if deepPaused || player == nil {
                deepPaused = false
                // Rebuild with a fresh URL — the old connection is gone
                // and the URL may have expired while parked.
                if let fresh = refreshStreamURL?(videoId) {
                    streamURL = fresh
                }
                buildPlayer(url: streamURL)
            } else {
                // The stall clock must not count paused time — give the
                // watchdog a full window from the resume.
                lastFrameAt = CFAbsoluteTimeGetCurrent()
                player?.play()
                startPulling()
            }
            scheduleRotation()
            debugLog("  [LiveStream] resumed \(context)")
        }
    }

    func pause(reason: PauseReasons) {
        queue.async { [weak self] in
            guard let self, !pauseReasons.contains(reason) else { return }
            pauseReasons.insert(reason)
            convergePlaybackState(context: "+\(reason.summary)")
        }
    }

    func resume(reason: PauseReasons) {
        queue.async { [weak self] in
            guard let self, pauseReasons.contains(reason) else { return }
            pauseReasons.remove(reason)
            convergePlaybackState(context: "-\(reason.summary)")
        }
    }

    func syncCompanionPauseReasons(user: Bool, battery: Bool, coverage: Bool, thermal: Bool, camera: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            var next = pauseReasons.intersection(.policy)
            if user { next.insert(.user) }
            if battery { next.insert(.battery) }
            if coverage { next.insert(.coverage) }
            if thermal { next.insert(.thermal) }
            if camera { next.insert(.camera) }
            guard next != pauseReasons else { return }
            pauseReasons = next
            convergePlaybackState(context: "seed")
        }
    }

    func applyActivityPolicy(paused: Bool, animated: Bool) {
        queue.async { [weak self] in
            guard let self, pauseReasons.contains(.policy) != paused else { return }
            if paused {
                pauseReasons.insert(.policy)
            } else {
                pauseReasons.remove(.policy)
            }
            convergePlaybackState(context: paused ? "+policy" : "-policy")
        }
    }

    // MARK: - Saver / lock modes (live is always 1.0× — inhibition only)

    func enterScreensaverMode() {
        queue.async { [weak self] in
            guard let self else { return }
            screensaverSubscriberCount += 1
            convergePlaybackState(context: "saver-enter")
        }
    }

    func exitScreensaverMode() {
        queue.async { [weak self] in
            guard let self, screensaverSubscriberCount > 0 else { return }
            screensaverSubscriberCount -= 1
            convergePlaybackState(context: "saver-exit")
        }
    }

    func setScreensaverModeFromNotification(_ active: Bool) {
        queue.async { [weak self] in
            guard let self, screensaverActiveFromNotification != active else { return }
            screensaverActiveFromNotification = active
            convergePlaybackState(context: active ? "saver-notif-on" : "saver-notif-off")
        }
    }

    func enterLockedMode() {
        queue.async { [weak self] in
            guard let self else { return }
            lockedScreenCount += 1
            convergePlaybackState(context: "lock-enter")
            applyAudioToPlayer()
        }
    }

    func exitLockedMode() {
        queue.async { [weak self] in
            guard let self, lockedScreenCount > 0 else { return }
            lockedScreenCount -= 1
            convergePlaybackState(context: "lock-exit")
            applyAudioToPlayer()
        }
    }

    // MARK: - Audio (headless AVPlayer — mute/volume only)

    /// Companion's audio intent, owner policy already folded into
    /// `enabled` by the handler. Applies live.
    func setAudio(enabled: Bool, volume: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            let vol = Float(max(0, min(1, volume)))
            guard audioEnabled != enabled || audioVolume != vol else { return }
            audioEnabled = enabled
            audioVolume = vol
            debugLog("  [LiveStream] audio → \(enabled ? "on" : "off") vol=\(String(format: "%.2f", vol))")
            applyAudioToPlayer()
        }
    }

    /// Converge the player's mute/volume to the intent. Must run on
    /// `queue`; no-op while the player is torn down (deep pause) — the
    /// rebuild calls back here via `buildPlayer`.
    private func applyAudioToPlayer() {
        guard let player else { return }
        let audible = audioEnabled && audioVolume > 0.001 && lockedScreenCount == 0
        player.volume = audioVolume
        player.isMuted = !audible
    }

    func beginScreensaverExitRamp() {
        // Live has no rate to ramp; nothing to do until the acquire
        // count / fallback flag actually clear.
    }

    func cancelScreensaverExitRamp() {
        // Mirror of the above: no rate ramp to undo on live streams.
    }

    /// Variant D contents-swap: the latest bridged frame. Live frames
    /// are pulled at 60 Hz and enqueued DisplayImmediately, so "latest"
    /// IS the presenting frame (no timebase pick needed). The output's
    /// pixel buffers are IOSurface-backed (see buildPlayer) — zero-copy
    /// for `CALayer.contents`.
    func presentingImageBuffer() -> CVPixelBuffer? {
        queue.sync { lastSample.flatMap { CMSampleBufferGetImageBuffer($0) } }
    }

    // MARK: - Live config (no-ops: live is rate-locked, no transitions)

    func setNominalRate(_ rate: Double) {}
    func setTransitionConfig(_ config: TransitionConfig) {}

    // MARK: - Deep pause

    private static let deepPauseDelay: TimeInterval = 30

    private func scheduleDeepPause() {
        cancelDeepPauseTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.deepPauseDelay)
        timer.setEventHandler { [weak self] in
            guard let self, isRunning, isPaused else { return }
            deepPaused = true
            teardownPlayer()
            debugLog("  [LiveStream] deep-paused — released the stream connection")
        }
        deepPauseTimer = timer
        timer.resume()
    }

    private func cancelDeepPauseTimer() {
        deepPauseTimer?.cancel()
        deepPauseTimer = nil
    }

    // MARK: - Subscribers

    func addSubscriber(_ layer: AVSampleBufferDisplayLayer) {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            subscribers.append(layer)
            debugLog("  [LiveStream] subscriber +1 → \(subscribers.count) total")
            // Instant join with the most recent frame.
            if let sample = lastSample {
                layer.sampleBufferRenderer.enqueue(sample)
            }
        }
    }

    func removeSubscriber(_ layer: AVSampleBufferDisplayLayer) {
        queue.async { [weak self] in
            guard let self else { return }
            subscribers.removeAll { $0 === layer }
            debugLog("  [LiveStream] subscriber -1 → \(subscribers.count) total")
        }
    }

    func feedsLayer(_ layer: AVSampleBufferDisplayLayer) -> Bool {
        queue.sync { subscribers.contains { $0 === layer } }
    }

    var subscriberCount: Int {
        queue.sync { subscribers.count }
    }

    /// Wake recovery — see `PlaybackRenderer.recoverAllLayers`. The live
    /// engine's 60 Hz pull loop re-feeds every layer continuously, so the
    /// flush alone is enough; `lastSample` (already a DisplayImmediately
    /// copy) bridges the gap until the next pulled frame.
    func recoverAllLayers(reason: String) {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            debugLog("🚑 [LiveStream] wake recovery (\(reason)): flushing \(subscribers.count) subscriber(s)")
            for layer in subscribers {
                layer.sampleBufferRenderer.flush()
                if let sample = lastSample {
                    layer.sampleBufferRenderer.enqueue(sample)
                }
            }
        }
    }

    // MARK: - Navigation

    func advanceNow() {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            debugLog("  [LiveStream] advanceNow() invoked")
            rotate(using: selectNext)
        }
    }

    func regressNow() {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            debugLog("  [LiveStream] regressNow() invoked")
            rotate(using: selectPrevious)
        }
    }

    func jumpNow() {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            debugLog("  [LiveStream] jumpNow() invoked")
            rotate(using: selectNext)
        }
    }

    // MARK: - Status / diagnostics

    var currentAssetURL: URL {
        queue.sync { streamURL }
    }

    /// Live position is meaningless for resume — 0 keeps it out of the
    /// progress sidecar (its writer skips non-positive positions).
    var currentContentPosition: Double { 0 }

    var nowPlayingOverride: (name: String, id: String)? {
        (name: feedName, id: videoId)
    }

    func statusSnapshot() -> VideoRenderer.StatusSnapshot {
        queue.sync {
            VideoRenderer.StatusSnapshot(
                assetURL: streamURL,
                position: player?.currentItem?.currentTime().seconds ?? 0,
                rate: Double(player?.rate ?? 0),
                pauseReasons: pauseReasons,
                saverActive: screensaverSubscriberCount > 0 || screensaverActiveFromNotification
            )
        }
    }

    func diagnosticsSnapshot() -> String {
        queue.sync {
            let sinceFrame = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - lastFrameAt)
            return "LIVE subs=\(subscribers.count) ssCount=\(screensaverSubscriberCount) locked=\(lockedScreenCount) ssNotif=\(screensaverActiveFromNotification) feed=\(feedName) rate=\(player?.rate ?? 0) paused=\(isPaused) reasons=\(pauseReasons.summary) fed=\(framesEnqueued) lastFrame=\(sinceFrame)s recovery=\(recoveryAttempts)"
        }
    }

    private static let snapshotContext = CIContext(options: [.useSoftwareRenderer: false])

    func captureCurrentFrame() async -> CGImage? {
        let recent: CMSampleBuffer? = queue.sync { lastSample }
        guard let recent, let pixelBuffer = CMSampleBufferGetImageBuffer(recent) else { return nil }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        return Self.snapshotContext.createCGImage(ci, from: ci.extent)
    }
}

extension LiveStreamRenderer: PlaybackRenderer {}

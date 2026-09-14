// Optional audio sidecar for VideoRenderer.
//
// The video path decodes with its own AVAssetReader and paces
// AVSampleBufferDisplayLayers off a shared CMTimebase; this class adds
// the audio track WITHOUT touching that pipeline: a second, independent
// audio-only AVAssetReader feeds an AVSampleBufferAudioRenderer attached
// to an AVSampleBufferRenderSynchronizer. Both the video timebase and
// the synchronizer's timebase derive from the host clock, so anchoring
// the synchronizer once (`setRate(1.0, time: videoTime)`) keeps the two
// timelines locked — no continuous drift correction, re-anchors happen
// only at discrete events (start, flush-swap, recreate).
//
// Sync contract with VideoRenderer:
//  - Audio plays ONLY while the video timebase runs at 1.0× (screensaver,
//    or wallpaper at 100% speed) — the renderer's `audioShouldPlay` gate
//    decides; this class just converges to it (`reconcile`).
//  - Samples are retimed by the video's accumulated loop `ptsOffset`
//    (same CMSampleBufferCreateCopyWithNewTiming trick as
//    `offsetTimingForLoop`), so audio PTS live on the video timeline.
//  - Gapless boundaries splice without a flush: the outgoing tail keeps
//    playing while the next video's audio reader queues behind it with
//    the new ptsOffset (`videoDidSwap`, mirroring the video's pipelined
//    reader swap). Manual skips flush and re-anchor at zero.
//
// Everything here is confined to the OWNING VideoRenderer's queue —
// every method must be called on it; async completions (track probe,
// auto-flush notification) hop back to it themselves.

import AVFoundation
import CoreMedia

final class AudioPipeline {
    private let queue: DispatchQueue
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()

    /// Ask the owning renderer to re-run its gate + `reconcile` — used
    /// by async completions (probe results, auto-flush recovery) that
    /// need fresh videoTime/ptsBase from the renderer. Called on `queue`.
    var requestReconcile: ((String) -> Void)?

    private enum State { case idle, playing, stopping }
    private var state: State = .idle

    /// Independent audio-only reader — never the video's.
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    /// Track-probe memo for the most recently probed asset URL.
    /// `probedTrack == nil` with a non-nil `probedURL` means "probed,
    /// no audio track" — the common case for Apple aerials, and a
    /// permanent cheap no-op for that asset.
    private var probedURL: URL?
    private var probedTrack: AVAssetTrack?
    private var probedAsset: AVURLAsset?
    private var probeInFlight = false

    /// Video-timeline offset applied to enqueued samples (mirror of the
    /// renderer's `ptsOffset` for the segment this reader belongs to).
    private var ptsBase: CMTime = .zero
    /// Next segment queued behind the current reader (gapless boundary):
    /// installed by `videoDidSwap`, consumed when the current reader
    /// drains. `track == nil` means the next video has no audio — drain
    /// to silence.
    private var pendingNext: (track: AVAssetTrack?, asset: AVURLAsset?, base: CMTime)?
    /// A gapless boundary whose track probe is still in flight.
    private var pendingBoundaryBase: CMTime?
    /// Current reader drained with nothing queued — `videoDidSwap` (or a
    /// queued segment arriving) must re-register the enqueue callback.
    private var eofReached = false

    private var desiredVolume: Float = 0.5
    private var fadeTimer: (any DispatchSourceTimer)?
    private var samplesFed: UInt64 = 0
    private var flushObserver: (any NSObjectProtocol)?

    /// Decode to LPCM: retiming compressed packets has priming-frame
    /// edge cases, and LPCM sidesteps any bet on which codecs the
    /// renderer decodes for arbitrary user-imported files. Stereo PCM
    /// decode is noise next to the 4K video decode.
    nonisolated(unsafe) private static let lpcmOutputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
    ]

    init(queue: DispatchQueue) {
        self.queue = queue
        synchronizer.addRenderer(audioRenderer)
        // The system flushes the renderer itself on output-route/format
        // changes (AirPods connect, sample-rate switch) — queued samples
        // are gone, so rebuild from the current position.
        flushObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: audioRenderer, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async {
                guard self.state != .idle else { return }
                debugLog("🔊 [Audio] renderer auto-flushed (route change) — restarting")
                self.hardStop()
                self.requestReconcile?("auto-flush")
            }
        }
    }

    deinit {
        if let flushObserver {
            NotificationCenter.default.removeObserver(flushObserver)
        }
    }

    // MARK: - Renderer-facing API (call on `queue`)

    /// Live volume knob. Applies immediately while playing (unless a
    /// fade owns the volume — it lands at the fade's target instead).
    func setDesiredVolume(_ volume: Float) {
        desiredVolume = max(0, min(1, volume))
        if state == .playing, fadeTimer == nil {
            audioRenderer.volume = desiredVolume
        }
    }

    /// Converge to the renderer's gate. Idempotent: a `shouldPlay` that
    /// matches the current state is a no-op — never re-anchors a healthy
    /// pipeline (audible glitch).
    func reconcile(shouldPlay: Bool, asset: AVURLAsset, videoTime: CMTime, ptsBase: CMTime, context: String) {
        if shouldPlay {
            guard state != .playing else { return }
            startAnchored(asset: asset, videoTime: videoTime, ptsBase: ptsBase,
                          fadeDuration: 0.3, context: context)
        } else {
            guard state == .playing else { return }
            stopWithFade(context: context)
        }
    }

    /// The video swapped readers. Gapless path (`flushed == false`):
    /// queue the new video's audio behind the current tail with the new
    /// `ptsBase` — no flush, no re-anchor. Flush path (manual skip):
    /// hard stop and re-anchor at the reset timeline.
    func videoDidSwap(asset: AVURLAsset, shouldPlay: Bool, videoTime: CMTime, ptsBase: CMTime, flushed: Bool) {
        guard shouldPlay else {
            if state != .idle { hardStop() }
            return
        }
        if flushed || state != .playing {
            // Manual skip (timeline reset to zero), or audio wasn't
            // running (e.g. previous video had no track) — anchored
            // (re)start; quick fade to soften the cut.
            hardStop()
            startAnchored(asset: asset, videoTime: videoTime, ptsBase: ptsBase,
                          fadeDuration: 0.15, context: flushed ? "swap-flush" : "swap-start")
            return
        }
        // Gapless boundary while playing: the outgoing tail (already
        // enqueued, PTS below the new base) plays out; the next segment
        // slots in behind it.
        pendingBoundaryBase = ptsBase
        if probedURL == asset.url {
            resolvePendingBoundary()
        } else {
            probe(asset: asset)
        }
    }

    /// Timeline is being reset under us (deep pause, recreate) — drop
    /// everything instantly; the renderer's next reconcile rebuilds.
    func reset(context: String) {
        guard state != .idle || reader != nil else { return }
        debugLog("🔊 [Audio] reset (\(context))")
        hardStop()
    }

    /// Renderer stop — final.
    func teardown() {
        hardStop()
        if let flushObserver {
            NotificationCenter.default.removeObserver(flushObserver)
            self.flushObserver = nil
        }
    }

    /// One-line state for `diagnosticsSnapshot()`.
    func diagnostics() -> String {
        let vol = String(format: "%.2f", audioRenderer.volume)
        switch state {
        case .idle:
            return probedURL != nil && probedTrack == nil ? "no-track" : "off"
        case .playing:
            return "on vol=\(vol) fed=\(samplesFed)\(eofReached ? " eof" : "")"
        case .stopping:
            return "fading vol=\(vol)"
        }
    }

    // MARK: - Start / stop

    private func startAnchored(asset: AVURLAsset, videoTime: CMTime, ptsBase: CMTime,
                               fadeDuration: TimeInterval, context: String) {
        guard probedURL == asset.url else {
            probe(asset: asset)
            return
        }
        guard let track = probedTrack, let probedAsset else {
            // Probed, no audio track — stay idle at zero cost.
            return
        }
        hardStop()
        guard buildReader(track: track, asset: probedAsset,
                          from: CMTimeMaximum(CMTimeSubtract(videoTime, ptsBase), .zero)) else { return }
        self.ptsBase = ptsBase
        state = .playing
        audioRenderer.volume = 0
        registerEnqueue()
        synchronizer.setRate(1.0, time: videoTime)
        fade(to: desiredVolume, duration: fadeDuration)
        debugLog("🔊 [Audio] start at \(String(format: "%.1f", CMTimeSubtract(videoTime, ptsBase).seconds))s vol=\(desiredVolume) (\(context)) — \(asset.url.lastPathComponent)")
    }

    private func stopWithFade(context: String) {
        state = .stopping
        pendingNext = nil
        pendingBoundaryBase = nil
        debugLog("🔊 [Audio] fade out (\(context))")
        fade(to: 0, duration: 0.5) { [weak self] in
            self?.hardStop()
        }
    }

    /// Instant full stop: cancel reader + fade, flush the renderer,
    /// halt the synchronizer. Safe to call from any state.
    private func hardStop() {
        cancelFade()
        state = .idle
        pendingNext = nil
        pendingBoundaryBase = nil
        eofReached = false
        audioRenderer.stopRequestingMediaData()
        reader?.cancelReading()
        reader = nil
        output = nil
        audioRenderer.flush()
        synchronizer.setRate(0, time: CMTimebaseGetTime(synchronizer.timebase))
    }

    // MARK: - Track probe (async, hops back to `queue`)

    private func probe(asset: AVURLAsset) {
        guard !probeInFlight else { return }
        probeInFlight = true
        let probeAsset = asset
        Task.detached { @Sendable [weak self] in
            let track = try? await probeAsset.loadTracks(withMediaType: .audio).first
            nonisolated(unsafe) let loadedTrack = track ?? nil
            guard let self else { return }
            queue.async { [weak self] in
                guard let self else { return }
                probeInFlight = false
                probedURL = probeAsset.url
                probedTrack = loadedTrack
                probedAsset = probeAsset
                if loadedTrack == nil {
                    debugLog("🔊 [Audio] no audio track in \(probeAsset.url.lastPathComponent)")
                }
                if pendingBoundaryBase != nil {
                    resolvePendingBoundary()
                } else {
                    // Fresh gate/times come from the renderer — a stale
                    // videoTime captured before the probe would anchor in
                    // the past.
                    requestReconcile?("probe")
                }
            }
        }
    }

    /// A gapless boundary was waiting on the probe (or the memo already
    /// covered it): queue the next segment, or start it immediately when
    /// the old reader already drained.
    private func resolvePendingBoundary() {
        guard let base = pendingBoundaryBase else { return }
        pendingBoundaryBase = nil
        guard state == .playing else { return }
        if eofReached {
            if let track = probedTrack, let probedAsset {
                guard buildReader(track: track, asset: probedAsset, from: .zero) else { return }
                ptsBase = base
                registerEnqueue()
                debugLog("🔊 [Audio] gapless continue base=\(String(format: "%.1f", base.seconds))s — \(probedAsset.url.lastPathComponent)")
            }
            // No track in the new video: tail already drained → silence.
        } else {
            pendingNext = (track: probedTrack, asset: probedAsset, base: base)
        }
    }

    // MARK: - Reader + enqueue loop

    private func buildReader(track: AVAssetTrack, asset: AVURLAsset, from start: CMTime) -> Bool {
        reader?.cancelReading()
        reader = nil
        output = nil
        eofReached = false
        guard let newReader = try? AVAssetReader(asset: asset) else {
            debugLog("🔊 [Audio] failed to create audio reader for \(asset.url.lastPathComponent)")
            return false
        }
        if start > .zero {
            newReader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        }
        let newOutput = AVAssetReaderTrackOutput(track: track, outputSettings: Self.lpcmOutputSettings)
        newOutput.alwaysCopiesSampleData = false
        newReader.add(newOutput)
        guard newReader.startReading() else {
            debugLog("🔊 [Audio] audio reader failed to start: \(String(describing: newReader.error))")
            return false
        }
        reader = newReader
        output = newOutput
        return true
    }

    private func registerEnqueue() {
        audioRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.enqueueLoop()
        }
    }

    private func enqueueLoop() {
        guard state != .idle else {
            audioRenderer.stopRequestingMediaData()
            return
        }
        while audioRenderer.isReadyForMoreMediaData {
            if let sample = output?.copyNextSampleBuffer() {
                audioRenderer.enqueue(retimed(sample))
                samplesFed &+= 1
            } else if let next = pendingNext {
                // Current video's audio fully queued — slide into the
                // next segment behind it (the video's pipelined swap,
                // audio edition).
                pendingNext = nil
                guard let track = next.track, let asset = next.asset,
                      buildReader(track: track, asset: asset, from: .zero) else {
                    // Next video has no audio — drain to silence.
                    eofReached = true
                    audioRenderer.stopRequestingMediaData()
                    return
                }
                ptsBase = next.base
                debugLog("🔊 [Audio] gapless continue base=\(String(format: "%.1f", next.base.seconds))s — \(asset.url.lastPathComponent)")
            } else {
                eofReached = true
                audioRenderer.stopRequestingMediaData()
                return
            }
        }
    }

    /// Shift a sample onto the video timeline (same lightweight retiming
    /// copy as the video's `offsetTimingForLoop` — shares the data
    /// buffer, only timing differs). LPCM has no reordering, so DTS
    /// stays invalid.
    private func retimed(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard ptsBase > .zero else { return sample }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: pts.isValid ? CMTimeAdd(pts, ptsBase) : pts,
            decodeTimeStamp: .invalid
        )
        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjusted
        )
        return adjusted ?? sample
    }

    // MARK: - Volume fade

    private func fade(to target: Float, duration: TimeInterval, completion: (() -> Void)? = nil) {
        cancelFade()
        let from = audioRenderer.volume
        guard abs(from - target) > 0.01, duration > 0.02 else {
            audioRenderer.volume = target
            completion?()
            return
        }
        let stepInterval = 1.0 / 60.0
        let totalSteps = max(1, Int(sanitizing: duration / stepInterval, "volume ramp steps", fallback: 1))
        var step = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + stepInterval, repeating: stepInterval)
        timer.setEventHandler { [weak self] in
            guard let self else {
                timer.cancel()
                return
            }
            step += 1
            let progress = min(Float(step) / Float(totalSteps), 1)
            audioRenderer.volume = from + (target - from) * progress
            if step >= totalSteps {
                timer.cancel()
                fadeTimer = nil
                completion?()
            }
        }
        fadeTimer = timer
        timer.resume()
    }

    private func cancelFade() {
        fadeTimer?.cancel()
        fadeTimer = nil
    }
}

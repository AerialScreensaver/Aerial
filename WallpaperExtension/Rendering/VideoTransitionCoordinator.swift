// Ghost freeze-fade transitions between videos.
//
// The renderer never decodes two videos at once (see the decode-once
// rationale in VideoRenderer). Instead, at a video boundary the
// outgoing video's *currently presenting* frame is frozen in a "ghost"
// AVSampleBufferDisplayLayer inserted directly above each subscriber
// (below the overlay layer), the swap proceeds underneath exactly as
// before, and the ghost animates away over a wall-clock duration.
// Explicit CAAnimations run server-side in WindowServer — immune to
// timebase-rate changes and extension hiccups — and the ghost shows
// the SAME decoded pixel buffer as the video layer, so HDR/EDR
// treatment is pixel-identical (no tone-map pop).
//
// Two entry points:
//  - Natural EOF (gapless swap): the cut *presents* ~queue-depth after
//    the reader swap (≈8 s wall at 0.125×), so the ghost dance is
//    scheduled on a CMTimebase dispatch timer slightly BEFORE the cut
//    (frozen A over live A is invisible) and the style animation
//    starts exactly at the cut via `beginTime`.
//  - Manual skips: ghost first (from the presenting frame), then the
//    flush-swap runs beneath it — this also papers over the old
//    freeze-then-pop while the new video's first frame decodes.
//
// The freeze frame comes from a small presenting-sample ring, NOT the
// renderer's `lastSample` — samples arrive in decode order, and
// B-frame reordering can leave the last-decoded frame a step behind
// the last-visible one (a backwards jump at ghost insert).

import AVFoundation
import CoreMedia
import os
import QuartzCore

/// Style + natural-boundary duration as applied to one renderer. Built
/// by the control listener from `WallpaperControlState`; manual skips
/// and fast-rate (saver) boundaries derive shorter durations at fire
/// time — one user knob only.
struct TransitionConfig: Equatable {
    var style: WallpaperTransitionStyle = .zoomFade
    var duration: Double = 2.0
}

final class VideoTransitionCoordinator: @unchecked Sendable {
    /// Wall-clock lead between ghost insert and animation start on the
    /// natural path (covers the fire → CATransaction-commit latency so
    /// the incoming video never flashes before the ghost lands), and
    /// the pre-fade hold on the manual path (covers the new video's
    /// first-frame decode).
    private static let leadWall: Double = 0.15
    /// Fixed manual-skip fade duration — responsiveness beats spectacle.
    private static let manualDuration: Double = 0.75
    /// At fast rates (saver/lock, or a user-set fast wallpaper) the
    /// frozen outgoing frame diverges visibly — cap the fade.
    private static let fastRateDurationCap: Double = 1.25
    /// Skip-spam guard: at most this many live ghosts per subscriber;
    /// beyond it, transitions degrade to the old hard cut.
    private static let maxGhostsPerSubscriber = 3

    private let timebase: CMTimebase
    /// The renderer's serial queue. Ring, pending slot, and config are
    /// touched exclusively on it; the ghost registry lives on main.
    private let queue: DispatchQueue

    /// Read/written on `queue` only (via VideoRenderer.setTransitionConfig).
    var config = TransitionConfig()

    // MARK: - Presenting-sample ring (renderer queue)

    /// Recently enqueued samples keyed by adjusted PTS. The display
    /// layers already retain these buffers in their own queues, so the
    /// ring's marginal memory is a handful of just-presented frames.
    /// Prune/pick/replay semantics live in PresentingRing (unit-tested);
    /// this class just injects `now` from the shared timebase.
    ///
    /// Lock-guarded, NOT queue-confined: the variant-D presenter polls
    /// `presentingSample()` at vsync, and routing that read through
    /// `queue.sync` made the poller block behind whole decode batches
    /// (2026-07-24 profile). Writers all still run on `queue`; the
    /// lock only makes the microsecond ring reads safe off-queue.
    /// `uncheckedState`: CMSampleBuffer isn't Sendable, but entries are
    /// immutable once noted.
    private let ring = OSAllocatedUnfairLock(uncheckedState: PresentingRing<CMSampleBuffer>())

    // MARK: - Pending natural-boundary transition (renderer queue)

    // Ghost hosts are plain CALayers: in-tree AVSBDL subscribers AND
    // variant D contents-swap layers (whose AVSBDL twins are off-tree
    // and would fail the superlayer guard). The ghost pass only needs
    // frame/superlayer/insert-above — CALayer contract.
    private struct PendingBoundary {
        let cutTime: CMTime
        let subscribers: () -> [CALayer]
    }

    private var pending: PendingBoundary?
    /// Held as the concrete `DispatchSource` (not the `DispatchSourceTimer`
    /// existential) because every CMTimebase timer call takes that type —
    /// downcast once at creation instead of `as!` at each call site.
    private var boundaryTimer: DispatchSource?

    // MARK: - Live ghost registry (MAIN thread only)

    private struct GhostSet {
        weak var host: CALayer?
        var layers: [CALayer]
    }

    private var liveGhosts: [GhostSet] = []

    init(timebase: CMTimebase, queue: DispatchQueue) {
        self.timebase = timebase
        self.queue = queue

        // One persistent timer, registered with the timebase for its
        // lifetime; parked at an invalid fire time while idle. The
        // timebase converts media fire times to host deadlines and
        // re-computes them across rate changes; at rate 0 it simply
        // waits (pause-safe for free).
        guard let timer = DispatchSource.makeTimerSource(queue: queue) as? DispatchSource else {
            debugLog("  [Transition] timer source is not a DispatchSource — boundary transitions disabled")
            return
        }
        timer.setEventHandler { [weak self] in
            self?.boundaryTimerFired()
        }
        timer.resume()
        boundaryTimer = timer
        CMTimebaseAddTimerDispatchSource(timebase, timerSource: timer)
    }

    /// Detach from the timebase and kill the timer. Called from
    /// VideoRenderer.stop(); safe to call once.
    func teardown() {
        if let timer = boundaryTimer {
            CMTimebaseRemoveTimerDispatchSource(timebase, timerSource: timer)
            timer.cancel()
            boundaryTimer = nil
        }
        pending = nil
        ring.withLockUnchecked { $0.clear() }
        removeAllGhosts()
    }

    // MARK: - Ring maintenance (call on `queue`)

    /// Track an enqueued sample. `pts` is the loop-adjusted timestamp —
    /// the same timeline the shared timebase runs on.
    func noteEnqueued(_ sample: CMSampleBuffer, pts: CMTime) {
        let now = CMTimebaseGetTime(timebase)
        ring.withLockUnchecked { $0.note(sample, pts: pts, now: now) }
    }

    /// The sample whose frame is on screen right now: newest PTS at or
    /// below the timebase time, falling back to the earliest queued
    /// future frame (right after a flush the past side is empty).
    /// Any-thread (lock-guarded ring; CMTimebaseGetTime is thread-safe).
    func presentingSample() -> CMSampleBuffer? {
        let now = CMTimebaseGetTime(timebase)
        return ring.withLockUnchecked { $0.presenting(at: now) }
    }

    /// All not-yet-presented samples, oldest first. Replayed into a
    /// freshly-joined or freshly-flushed layer so it keeps presenting on
    /// the shared timebase instead of holding one primed frame until its
    /// feed callback catches up. PTS values are loop-adjusted to the
    /// shared timebase, so they enqueue as-is — no rewrite. Call on
    /// `queue`.
    func inflightSamples() -> [CMSampleBuffer] {
        let now = CMTimebaseGetTime(timebase)
        return ring.withLockUnchecked { $0.inflight(after: now) }
    }

    /// Drop all ring entries. Call before any timeline reset
    /// (flush-swap, recreate) — PTS from the old timeline are garbage
    /// on the new one.
    func clearRing() {
        ring.withLockUnchecked { $0.clear() }
    }

    // MARK: - Natural-boundary path (call on `queue`)

    /// Arm a transition for a gapless video change whose first new
    /// frame presents when the timebase reaches `cutTime`. Fires
    /// slightly early (`leadWall`), freezes the then-presenting frame
    /// over every subscriber, and starts the style animation exactly
    /// at the cut. One pending slot — a newer boundary replaces an
    /// unfired older one (ultra-short videos).
    func scheduleBoundaryTransition(
        cutTime: CMTime,
        subscribers: @escaping () -> [CALayer]
    ) {
        guard config.style != .none else { return }
        guard let timer = boundaryTimer else { return }
        if pending != nil {
            debugLog("  [Transition] pending boundary replaced by a newer one")
        }
        pending = PendingBoundary(cutTime: cutTime, subscribers: subscribers)

        // Lead in timeline units at the current rate. Rate 0 can't
        // happen here in practice (the feed only reaches EOF while
        // presenting), but guard it — a zero lead just readmits the
        // 1-frame flash.
        let rate = Double(CMTimebaseGetRate(timebase))
        let leadTimeline = CMTime(seconds: Self.leadWall * max(rate, 0.0), preferredTimescale: 600)
        let fireAt = CMTimeSubtract(cutTime, leadTimeline)
        CMTimebaseSetTimerDispatchSourceNextFireTime(
            timebase, timerSource: timer, fireTime: fireAt, flags: 0
        )
        debugLog("  [Transition] scheduled cut=\(String(format: "%.2f", cutTime.seconds))s fire=\(String(format: "%.2f", fireAt.seconds))s style=\(config.style.rawValue)")
    }

    /// Disarm the pending boundary transition (does NOT touch running
    /// ghost animations — those are fire-and-forget). MUST be called
    /// before any backwards `CMTimebaseSetTime`: a time jump under a
    /// pending fire silently parks it forever.
    func cancelScheduled(reason: String) {
        guard pending != nil else { return }
        pending = nil
        if let timer = boundaryTimer {
            CMTimebaseSetTimerDispatchSourceNextFireTime(
                timebase, timerSource: timer, fireTime: .invalid, flags: 0
            )
        }
        debugLog("  [Transition] cancelled (\(reason))")
    }

    private func boundaryTimerFired() {
        // One-shot: park the timer first (the timebase would otherwise
        // keep the stale deadline alive across rate changes).
        if let timer = boundaryTimer {
            CMTimebaseSetTimerDispatchSourceNextFireTime(
                timebase, timerSource: timer, fireTime: .invalid, flags: 0
            )
        }
        // A cancel racing the fire (due-but-not-yet-run, see CMSync.h
        // note) lands here with no pending — nothing to do.
        guard let fired = pending else { return }
        pending = nil
        guard config.style != .none else { return }

        guard let sample = presentingSample() else {
            debugLog("  [Transition] skipped (no-presenting-sample)")
            return
        }
        let subs = fired.subscribers()
        guard !subs.isEmpty else {
            debugLog("  [Transition] skipped (no-subscribers)")
            return
        }

        // Remaining wall time to the cut at the CURRENT rate (the rate
        // may have changed since scheduling; recompute so the animation
        // still starts at the cut). Cap it — a big rate drop must not
        // hold a frozen ghost for ages.
        let rate = Double(CMTimebaseGetRate(timebase))
        let remaining = CMTimeSubtract(fired.cutTime, CMTimebaseGetTime(timebase)).seconds
        let delay = rate > 0.001 ? min(max(remaining / rate, 0), 1.0) : 0
        let duration = rate >= 0.5 ? min(config.duration, Self.fastRateDurationCap) : config.duration

        debugLog("  [Transition] fire tb=\(String(format: "%.2f", CMTimebaseGetTime(timebase).seconds))s delay=\(String(format: "%.2f", delay))s duration=\(String(format: "%.2f", duration))s ghosts=\(subs.count)")
        runGhosts(on: subs, sample: sample, style: config.style, duration: duration, startDelay: delay)
    }

    // MARK: - Manual-skip path (call on `queue`)

    /// Freeze the presenting frame over `subscribers`, then run `swap`
    /// back on the renderer queue once the ghosts are committed. Falls
    /// through to a direct swap when no ghost is possible.
    func performImmediateTransition(
        subscribers: [CALayer],
        then swap: @escaping () -> Void
    ) {
        guard config.style != .none else {
            swap()
            return
        }
        guard !subscribers.isEmpty, let sample = presentingSample() else {
            debugLog("  [Transition] skipped (\(subscribers.isEmpty ? "no-subscribers" : "no-presenting-sample")) — direct swap")
            swap()
            return
        }
        // A pending natural boundary is superseded — and the swap below
        // resets the timebase, which would otherwise park its fire.
        cancelScheduled(reason: "manualSwap")

        let style = config.style
        debugLog("  [Transition] manual ghost (\(style.rawValue)) → swap")
        runGhosts(
            on: subscribers,
            sample: sample,
            style: style,
            duration: Self.manualDuration,
            startDelay: Self.leadWall
        ) { [queue] in
            queue.async { swap() }
        }
    }

    // MARK: - Ghost dance

    /// Build and animate ghosts over each subscriber. All CoreAnimation
    /// work happens on main (never main.sync from the renderer queue —
    /// the snapshot path does queue.sync from MainActor and would
    /// deadlock). `afterCommit` runs once the ghost transaction is
    /// committed.
    private func runGhosts(
        on subscribers: [CALayer],
        sample: CMSampleBuffer,
        style: WallpaperTransitionStyle,
        duration: Double,
        startDelay: Double,
        afterCommit: (() -> Void)? = nil
    ) {
        guard let ghostFrame = VideoRenderer.displayImmediatelyCopy(of: sample) else {
            debugLog("  [Transition] skipped (ghost copy failed) — direct")
            afterCommit?()
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                afterCommit?()
                return
            }
            var created: [(set: GhostSet, midpointDrop: [CALayer])] = []

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for sub in subscribers {
                guard let superlayer = sub.superlayer else { continue }
                guard liveGhostCount(for: sub) < Self.maxGhostsPerSubscriber else {
                    debugLog("  [Transition] skipped (ghost-cap) for one subscriber")
                    continue
                }
                let built = Self.buildGhost(
                    over: sub, in: superlayer, frame: ghostFrame,
                    style: style, duration: duration, startDelay: startDelay
                )
                created.append((GhostSet(host: sub, layers: built.all), built.midpointDrop))
            }
            CATransaction.commit()
            afterCommit?()

            guard !created.isEmpty else { return }
            liveGhosts.append(contentsOf: created.map(\.set))

            // Deterministic cleanup on wall-clock — don't rely on CA
            // completion-block threading. Dip-to-black drops its ghost
            // under peak black; everything else goes at the end.
            let midpointLayers = created.flatMap(\.midpointDrop)
            if !midpointLayers.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + startDelay + duration * 0.5) { [weak self] in
                    self?.removeGhostLayers(midpointLayers)
                }
            }
            let allLayers = created.flatMap(\.set.layers)
            DispatchQueue.main.asyncAfter(deadline: .now() + startDelay + duration + 0.3) { [weak self] in
                self?.removeGhostLayers(allLayers)
                debugLog("  [Transition] ghost removed (live=\(self?.liveGhosts.count ?? 0))")
            }
        }
    }

    /// Construct one subscriber's ghost stack inside the caller's
    /// CATransaction. Returns every created layer plus the subset to
    /// drop at the style's midpoint (dip-to-black's frozen frame).
    private static func buildGhost(
        over sub: CALayer,
        in superlayer: CALayer,
        frame ghostFrame: CMSampleBuffer,
        style: WallpaperTransitionStyle,
        duration: Double,
        startDelay: Double
    ) -> (all: [CALayer], midpointDrop: [CALayer]) {
        // The frozen outgoing frame. Same layer class + same decoded
        // pixel buffer as the live video layer → identical rendering.
        // No controlTimebase and a single DisplayImmediately enqueue:
        // the frame persists by construction.
        let ghost = AVSampleBufferDisplayLayer()
        ghost.frame = sub.frame
        ghost.contentsScale = sub.contentsScale
        // Match the host's scaling: AVSBDL hosts carry videoGravity;
        // variant D contents-swap hosts express it as contentsGravity.
        if let av = sub as? AVSampleBufferDisplayLayer {
            ghost.videoGravity = av.videoGravity
        } else {
            switch sub.contentsGravity {
            case .resizeAspect: ghost.videoGravity = .resizeAspect
            case .resize: ghost.videoGravity = .resize
            default: ghost.videoGravity = .resizeAspectFill
            }
        }
        ghost.sampleBufferRenderer.enqueue(ghostFrame)
        // Directly above the video layer: below the overlay layer, and
        // below any older, still-fading ghost (back-to-back skips stack
        // and composite correctly).
        superlayer.insertSublayer(ghost, above: sub)

        let begin = CACurrentMediaTime() + startDelay

        switch style {
        case .none:
            // Callers gate on style — treat defensively as crossfade.
            fallthrough

        case .crossfade, .zoomFade:
            // Model at the final state + explicit from→to animation
            // (fillMode backwards holds the start value through the
            // delay) so a late removal can never flash the frozen
            // frame back.
            ghost.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            fade.duration = duration
            fade.beginTime = begin
            fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ghost.add(fade, forKey: "aerial-transition-fade")

            if style == .zoomFade {
                let zoom = CABasicAnimation(keyPath: "transform.scale")
                zoom.fromValue = 1.0
                zoom.toValue = 1.04
                zoom.duration = duration
                zoom.beginTime = begin
                zoom.fillMode = .backwards
                zoom.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ghost.add(zoom, forKey: "aerial-transition-zoom")
            }
            return (all: [ghost], midpointDrop: [])

        case .dipToBlack:
            // Black veil above the frozen frame: rises over the first
            // half (over frozen A), the ghost drops under peak black,
            // then the veil falls to reveal the already-playing B.
            let black = CALayer()
            black.frame = sub.frame
            black.backgroundColor = CGColor(gray: 0, alpha: 1)
            black.opacity = 0
            superlayer.insertSublayer(black, above: ghost)

            let veil = CAKeyframeAnimation(keyPath: "opacity")
            veil.values = [0.0, 1.0, 1.0, 0.0]
            veil.keyTimes = [0.0, 0.45, 0.55, 1.0]
            veil.duration = duration
            veil.beginTime = begin
            veil.fillMode = .backwards
            veil.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            black.add(veil, forKey: "aerial-transition-veil")
            return (all: [ghost, black], midpointDrop: [ghost])
        }
    }

    // MARK: - Ghost registry (MAIN thread)

    private func liveGhostCount(for sub: CALayer) -> Int {
        liveGhosts.filter { $0.host === sub && !$0.layers.isEmpty }.count
    }

    private func removeGhostLayers(_ layers: [CALayer]) {
        guard !layers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            layer.removeFromSuperlayer()
        }
        CATransaction.commit()
        for i in liveGhosts.indices {
            liveGhosts[i].layers.removeAll { removed in layers.contains { $0 === removed } }
        }
        liveGhosts.removeAll { $0.layers.isEmpty }
    }

    /// Remove any ghosts stacked over `layer` — its scene is going away
    /// (invalidate / Space churn) and they'd orphan on a dead context.
    func removeGhosts(for layer: AVSampleBufferDisplayLayer) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let doomed = liveGhosts.filter { $0.host === layer || $0.host == nil }.flatMap(\.layers)
            removeGhostLayers(doomed)
        }
    }

    /// Structural teardown (recreate/stop): every ghost goes.
    func removeAllGhosts() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            removeGhostLayers(liveGhosts.flatMap(\.layers))
        }
    }
}

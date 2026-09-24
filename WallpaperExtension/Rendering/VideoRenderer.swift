// Feeds video sample buffers to one or more AVSampleBufferDisplayLayers.
//
// AVPlayerLayer doesn't work in remote CAContexts (DisplaySize stays 0x0),
// so we render frames manually — matching what Phosphene's renderer does.
//
// Two modes of use:
//
// 1. **Per-display renderer** (independent viewing mode): the handler
//    creates one VideoRenderer per `directDisplayID`, and adds one
//    subscriber per acquire on that display. Multiple Spaces on the
//    same display all share the same decoder; only the visible
//    Space's CAContext composites the frames.
//
// 2. **Broadcast renderer** (cloned/spanned viewing mode): the handler
//    creates ONE global VideoRenderer and adds one subscriber per
//    acquire across all displays. One decoder feeds N display layers.
//    All subscribers share a `CMTimebase`, so frames are wallclock-
//    aligned across displays.
//
// Looping is gapless: at each loop boundary, both DTS and PTS of new
// samples are offset to continue the timeline. Avoids flushing the
// queued buffers, which would cause a visible stutter.
//
// Pause / resume / lock-screen ramp drive the shared timebase rate;
// all subscribers respond uniformly.

import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import os

/// Why playback is paused. Pause intent is the UNION of four independent
/// sources; the renderer converges the physical timebase state to the
/// intent in `reassertPlaybackState()` — the single choke point for every
/// pause/resume/rate decision. Replaces the old {isPaused-as-intent +
/// PlaybackPolicy} pair, whose desync silently dropped speed changes
/// (a control-channel resume cleared the pause bit but never restored
/// the policy enum, gating out every later CMTimebaseSetRate).
struct PauseReasons: OptionSet, Equatable {
    let rawValue: Int
    /// System presentation policy (activityState == suspended — display
    /// asleep). FORCE: pauses even while a saver/lock presents — nothing
    /// is visible and the decode is wasted power.
    static let policy = PauseReasons(rawValue: 1 << 0)
    /// The user's static/animated intent (WallpaperControlState.paused).
    static let user = PauseReasons(rawValue: 1 << 1)
    /// Battery rule (WallpaperControlState.batteryPaused).
    static let battery = PauseReasons(rawValue: 1 << 2)
    /// Window-coverage auto-pause for this renderer's scope.
    static let coverage = PauseReasons(rawValue: 1 << 3)
    /// Thermal pressure / Low Power Mode rule
    /// (WallpaperControlState.thermalPaused).
    static let thermal = PauseReasons(rawValue: 1 << 4)
    /// Camera-in-use rule (WallpaperControlState.cameraPaused) — pause
    /// during videoconferences without coverage-threshold tuning.
    static let camera = PauseReasons(rawValue: 1 << 5)

    var summary: String {
        var parts: [String] = []
        if contains(.policy) { parts.append("policy") }
        if contains(.user) { parts.append("user") }
        if contains(.battery) { parts.append("battery") }
        if contains(.coverage) { parts.append("coverage") }
        if contains(.thermal) { parts.append("thermal") }
        if contains(.camera) { parts.append("camera") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }
}

final class VideoRenderer: @unchecked Sendable {
    /// Cinematic default playback rate. Companion can change this live
    /// via the WallpaperControl channel → `setNominalRate`. This is the
    /// rate we use for wallpaper playback; it's overridden by 1.0× while
    /// any screensaver subscriber is attached (see `effectiveRate`).
    private(set) var nominalRate: Double = 0.125

    /// Count of subscribers attached for screensaver presentation. While
    /// > 0, `effectiveRate` returns 1.0 regardless of `nominalRate` so
    /// the screensaver plays at real time independent of the wallpaper's
    /// cinematic slow rate. Mutated only on `queue`.
    private var screensaverSubscriberCount: Int = 0

    /// True between the saver's visual exit (update mode idle→default)
    /// and its INVALIDATE, which WallpaperAgent sends ~5 s later: the
    /// saver layers are off-screen but still subscribed. While set,
    /// `effectiveRate` ignores the screensaver override so the wallpaper
    /// ramps back to its cinematic rate immediately instead of running
    /// 5 s at 1.0× and snapping. Mutated only on `queue`.
    private var screensaverRateSuspended = false

    /// Independent "screensaver mode" flag driven by the FALLBACK detector
    /// (distributed notifications / update()-idle in WallpaperXPCHandler), NOT the
    /// acquire-driven `screensaverSubscriberCount`. OR-ed with the count in
    /// `effectiveRate`/`pauseInhibited` so the fallback can only ADD screensaver
    /// mode — it never decrements or overrides the working acquire path. Mutated
    /// only on `queue`.
    private var screensaverActiveFromNotification = false

    /// Count of wallpapers on this renderer currently in the system's
    /// `locked` presentation mode. The lock/login screen displays the
    /// wallpaper — it must never sit on a paused frame. Mirrors the
    /// screensaver count; driven by update()'s lock transitions.
    private var lockedScreenCount = 0

    /// Playback rate for the lock/login (wake-from-sleep) screen. Kept
    /// as its own constant — separate from the screensaver's 1.0× — so
    /// this "third mode" can diverge later without touching saver
    /// behaviour. Full speed today.
    private static let lockedScreenRate: Double = 1.0

    /// The never-pause invariant: while the screensaver is presenting
    /// (and not already in its exit window) or the lock screen is up,
    /// user/coverage/battery pauses are inhibited — the reasons stay
    /// recorded and re-land automatically at exit via
    /// `reassertPlaybackState()`. `.policy` bypasses this (see
    /// `effectivePaused`).
    private var pauseInhibited: Bool {
        ((screensaverSubscriberCount > 0 || screensaverActiveFromNotification) && !screensaverRateSuspended) || lockedScreenCount > 0
    }

    /// Pause INTENT resolved against the never-pause inhibitors:
    /// `.policy` always wins (display asleep); the Companion-driven
    /// reasons are deferred while a saver/lock presents. Read on `queue`.
    private var effectivePaused: Bool {
        pauseReasons.contains(.policy) || (!pauseReasons.isEmpty && !pauseInhibited)
    }

    /// Rate the timebase should actually run at. Precedence: an active
    /// screensaver (1.0×, unless in its exit window) wins; then the
    /// lock/login screen (`lockedScreenRate`); otherwise the wallpaper's
    /// cinematic `nominalRate`. Read on `queue`.
    private var effectiveRate: Double {
        if (screensaverSubscriberCount > 0 || screensaverActiveFromNotification) && !screensaverRateSuspended { return 1.0 }
        if lockedScreenCount > 0 { return Self.lockedScreenRate }
        return nominalRate
    }

    let timebase: CMTimebase
    /// Ghost freeze-fade engine for video-change transitions. Owns the
    /// presenting-sample ring and the boundary timer; config arrives
    /// via `setTransitionConfig`.
    private let transition: VideoTransitionCoordinator
    /// Optional audio sidecar: its own audio-only AVAssetReader feeding
    /// an AVSampleBufferAudioRenderer, mirrored off this renderer's
    /// timebase at the choke points. Never touches the video readers.
    private let audio: AudioPipeline
    /// Companion's "play audio" intent for THIS renderer — the handler
    /// folds the audio-owner policy in before calling `setAudio`, so
    /// true means "this renderer is the one that sounds". Queue-confined.
    private var audioEnabled = false
    private var audioDesiredVolume: Float = 0.5
    private var asset: AVURLAsset
    private var videoTrack: AVAssetTrack
    private let queue = DispatchQueue(label: "aerial-wallpaper-video-renderer", qos: .userInitiated)
    private var isRunning = true
    /// PHYSICAL state: the timebase is stopped (and a deep pause is
    /// scheduled). Intent lives in `pauseReasons`;
    /// `reassertPlaybackState()` converges the two. Mutated only there
    /// (and by rampDown's completion).
    private(set) var isPaused = false
    /// Pause intent from all four sources. Mutated only on `queue`.
    private var pauseReasons: PauseReasons = []
    /// A playlist-changed cut arrived while paused — executed by
    /// `reassertPlaybackState()` at the next convergence to playing, so a
    /// paused screen never visibly swaps videos. Queue-confined. Cleared
    /// by any explicit navigation (advance/regress/jump), which supersedes
    /// the deferred cut.
    private var pendingPlaylistJump = false
    /// Generation stamp for the playing-state playlist-cut grace window
    /// (see `jumpWhenResumed`). Bumped by each new window and by every
    /// explicit navigation, so a superseded window's delayed block
    /// no-ops. Deliberately NOT `pendingPlaylistJump`: that flag is
    /// executed by `reassertPlaybackState()` on ANY playing convergence,
    /// which would defeat the wait. Queue-confined.
    private var graceJumpGeneration = 0
    private var rampTimer: (any DispatchSourceTimer)?
    /// What the live ramp is doing — a second pause during a rampDown
    /// must let it finish, while a pause during a rampUp/rampRate must
    /// cancel it and ease down from the current rate. `rampTimer != nil`
    /// alone can't tell those apart.
    private enum RampKind { case up, down, rate }
    private var activeRampKind: RampKind?
    private var deepPauseTimer: (any DispatchSourceTimer)?

    /// Frame rate of the video currently feeding subscribers, loaded
    /// race-free at create/swap. Drives the pause-slowdown duration:
    /// high-fps aerials decelerate beautifully; low-fps content would
    /// frame-step through a long ramp, so it gets a near-instant stop
    /// (the historical DesktopLauncher rule).
    private var currentFrameRate: Float = 30
    /// Frame rate riding alongside `nextReader`/`nextOutput`, adopted
    /// at the swap.
    private var nextFrameRate: Float?

    // MARK: Bounded looping (per-entry play duration)

    /// The current entry's play-duration override, in seconds of
    /// playtime; nil = play once. Measured on the timebase, so it is
    /// speed-factored and pause-safe by construction (the AVPlayer engine
    /// had to accumulate wall-clock × rate for the same effect).
    /// Queue-confined after init.
    private var currentPlayDuration: Double?
    /// Rides with the next reader like `nextFrameRate`; adopted at the swap.
    private var nextPlayDuration: Double?
    /// Timebase time the current entry's budget window opened at: its
    /// first pass start, or the resumed position on a cold start /
    /// recreate. Untouched by same-clip re-primes so playtime accumulates
    /// across passes.
    private var budgetStartTB: CMTime = .zero
    /// Absolute timebase time at which the current pass ends early
    /// because the budget runs out mid-clip (armed by
    /// `prepareNextReaderOnQueue`, consumed by the pump). nil = play to EOF.
    private var budgetCutTB: CMTime?
    /// The pump hit `budgetCutTB` — the swap that follows is a budget
    /// cut, not a clean EOF: audio restarts anchored instead of queueing
    /// the old clip's tail behind the new base. One-shot.
    private var budgetCutFired = false
    /// Same-clip passes queued so far for the current budget (diagnostics).
    private var boundedLoopPasses = 0
    /// Where the pending next reader came from. Re-primes never consulted
    /// the provider, so an explicit advance must pop it itself instead of
    /// replaying the clip (`advanceNow`), and the budget window survives
    /// the swap (`swapToNextReader`).
    private enum NextReaderOrigin { case provider, repeatOne, boundedLoop }
    private var nextOrigin: NextReaderOrigin = .provider

    /// Wall-clock duration of every adaptive ease — pause landings,
    /// resume ramps, and saver/lock rate transitions. High-fps content
    /// glides beautifully; low-fps content would frame-step through a
    /// long ramp, so it gets a near-instant change (the historical
    /// DesktopLauncher rule).
    private var adaptiveRampDuration: TimeInterval {
        currentFrameRate >= 60 ? 3.0 : 0.25
    }

    /// Accessibility: when Reduce Motion is on, every ease becomes an
    /// instant change.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var currentReader: AVAssetReader?
    private var currentOutput: AVAssetReaderOutput?
    private var nextReader: AVAssetReader?
    private var nextOutput: AVAssetReaderOutput?
    /// Track riding alongside `nextReader`/`nextOutput`, adopted at the
    /// swap — the output no longer exposes it now that it may be a
    /// composition output.
    private var nextTrack: AVAssetTrack?
    /// How the current track must be rotated to appear upright: its
    /// `preferredTransform` plus the user's extra rotation. Decides
    /// between the raw track output and a composition output. Queue-
    /// confined after init; `nextPresentation` rides with the next reader.
    private var presentation: TrackPresentation
    private var nextPresentation: TrackPresentation?

    // Gapless looping state. Same semantics as Phosphene: ptsOffset
    // accumulates across loops so DTS/PTS are monotonically increasing;
    // lastEnqueuedEnd tracks the highest sample end time across all
    // enqueues (max, not last — handles B-frame reordering).
    private var ptsOffset: CMTime = .zero
    private var lastEnqueuedEnd: CMTime = .zero

    /// Most recent frame fed to subscribers (decompressed — standalone
    /// displayable). Powers instant join (`addSubscriber` shows it via a
    /// DisplayImmediately copy instead of black-until-PTS-catch-up) and
    /// the cheap `captureCurrentFrame` path. Touched only on `queue`;
    /// cleared on explicit swaps so a stale video never replays. A
    /// recreate (deep-pause wake, error/watchdog recovery) KEEPS it: it
    /// is always the same asset, and the wake recovery + snapshot reply
    /// need a frame exactly then (2026-09-20: "no frame to re-prime —
    /// deep-paused" on every wake, poster decode on a suspect decoder).
    private var lastSample: CMSampleBuffer?

    /// Feed heartbeat (touched only on `queue`): wall-clock of the last
    /// enqueue + total frames fed. The watchdog uses the former to spot a
    /// dead feed loop; both surface in `diagnosticsSnapshot()`.
    private var lastEnqueueAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var framesEnqueued: Int = 0

    // MARK: - Off-queue mirror + pump watchdog state

    /// Snapshot of the queue-confined state that off-queue readers need
    /// (status writer, snapshot XPC, diagnostics, control listener).
    /// Written from `queue` by `publish()` at every state change and at
    /// the end of every pump pass; read under the lock everywhere else.
    /// Exists so that NO cross-queue read ever waits on the renderer
    /// queue: when that queue wedged inside AVFoundation (a
    /// `copyNextSampleBuffer` that never returned after a wake — the
    /// 2026-09-20 DisplayLink bundle), the old `queue.sync` readers piled
    /// up on the main thread, the XPC handler tasks and the diagnostics
    /// queue until WallpaperAgent killed the process 30 s later.
    struct Published {
        var asset: AVURLAsset
        var ptsOffset: CMTime = .zero
        var pauseReasons: PauseReasons = []
        var isPaused = false
        var saverActive = false
        var lockedCount = 0
        var ssCount = 0
        var ssNotif = false
        var nominalRate: Double = 0.125
        var extraRotation = 0
        var subscriberIDs: [ObjectIdentifier] = []
        var stuckIDs: Set<ObjectIdentifier> = []
        var lastSample: CMSampleBuffer?
        var currentReader: AVAssetReader?
        var nextReader: AVAssetReader?
        var lastEnqueueAt: CFAbsoluteTime
        var framesEnqueued = 0
        /// Watchdog counters. `wdCancels` / `lastWatchdogCancelAt` are
        /// written by the watchdog thread and preserved across publishes.
        var wdCancels = 0
        var lastWatchdogCancelAt: CFAbsoluteTime = 0
        var wdRecreates = 0
        var wdAttempt = 0
    }
    private let published: OSAllocatedUnfairLock<Published>

    /// The blocking AVFoundation call the pump is inside right now (nil
    /// between calls). Set/cleared on `queue` around `copyNextSampleBuffer`
    /// and `startReading`; the off-queue watchdog reads it to detect a
    /// wedge and records its cancel in it.
    struct PumpBlock {
        let reader: AVAssetReader
        let phase: String
        let enteredAt: CFAbsoluteTime
        var cancelIssuedAt: CFAbsoluteTime?
        var escalated = false
    }
    private let pumpBlock = OSAllocatedUnfairLock<PumpBlock?>(uncheckedState: nil)
    /// Reader the watchdog cancelled — consumed by the pump's nil branch
    /// so a watchdog cancel is never mistaken for EOF (which would advance
    /// the playlist) or for a decoder failure (immediate re-wedge).
    private let watchdogCancelledReader = OSAllocatedUnfairLock<AVAssetReader?>(uncheckedState: nil)
    /// Once-per-episode gate for the "queue unresponsive" diagnostics line.
    private let queueUnresponsiveLogged = OSAllocatedUnfairLock(initialState: false)
    /// Debug-only stall injector (see `pollStallInjector`).
    private let armedStall = OSAllocatedUnfairLock<String?>(initialState: nil)
    /// Watchdog rebuild ladder (queue-confined): attempts since the last
    /// healthy frame, lifetime rebuilds, and the pending backoff timer.
    private var wdAttempt = 0
    private var wdRecreates = 0
    private var watchdogRecreateTimer: (any DispatchSourceTimer)?
    /// Escalation hook: the watchdog cancelled the reader and the queue
    /// is STILL blocked `PumpWatchdogPolicy.escalateAfterCancel` later —
    /// AVFoundation ignored the cancel. Installed by the handler.
    var onQueueWedged: (() -> Void)?

    /// Refresh-cap thinning state (touched only on `queue`). High-fps
    /// sources feed more frames than any display can present (240 fps
    /// content at ≥0.3× on a 60 Hz panel) — every excess frame pays
    /// full enqueue + fan-out + render-server cost while never becoming
    /// visible. `lastKeptPTS` is the content PTS of the last frame that
    /// passed the grid; monotonic across loops/swaps (loop offsetting
    /// keeps PTS rising), and a PTS regression (reader rebuild) resets
    /// it. `displayRefreshCap` is the max refresh among displays this
    /// renderer feeds — 60 Hz until the handler reports better.
    private var lastKeptPTS: CMTime = .invalid
    private var framesDroppedForRefresh: Int = 0
    private var displayRefreshCap: Double = 60

    /// Reader output settings: request DECOMPRESSED frames. VideoToolbox
    /// hardware-decodes ONCE in this process; with passthrough (nil)
    /// every subscribing AVSampleBufferDisplayLayer ran its own
    /// decompression session — N subscribers = N simultaneous 4K decodes,
    /// which saturated the decoder at screensaver entry (wallpaper +
    /// saver layer per display at 1.0×) and produced choppy, staggered
    /// starts. Specifying only the IOSurface key lets the decoder pick
    /// its native pixel format (preserves 8- and 10-bit sources), and
    /// IOSurface backing keeps WindowServer compositing zero-copy.
    nonisolated(unsafe) private static let decodedOutputSettings: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]

    // MARK: - Track orientation

    /// What the reader output needs to present a track upright: the
    /// geometry from `VideoOrientationMath` (the file's
    /// `preferredTransform` plus the user's extra rotation) and the
    /// track's colour tags, which the composition carries so HDR clips
    /// keep their transfer function. Loaded once per asset, off the
    /// queue, together with the track.
    struct TrackPresentation {
        let geometry: VideoOrientationMath.DisplayGeometry
        let preferredTransform: CGAffineTransform
        let extraRotation: Int
        /// End of the track, for the composition instruction's range.
        let trackEnd: CMTime
        let colorPrimaries: String?
        let colorTransferFunction: String?
        let colorYCbCrMatrix: String?

        var needsComposition: Bool { !geometry.isIdentity }

        var summary: String {
            let t = preferredTransform
            let matrix = String(format: "[%.0f %.0f %.0f %.0f]", t.a, t.b, t.c, t.d)
            return needsComposition
                ? "composition \(Int(geometry.renderSize.width))×\(Int(geometry.renderSize.height)) (preferredTransform=\(matrix) extra=\(extraRotation)°)"
                : "identity, track output (preferredTransform=\(matrix) extra=\(extraRotation)°)"
        }
    }

    /// Load the orientation inputs for `track` (async property loads —
    /// never on the render queue) and fold in `extraRotation`.
    static func loadPresentation(track: AVAssetTrack, extraRotation: Int) async -> TrackPresentation {
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let size = (try? await track.load(.naturalSize)) ?? .zero
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        let timeRange = (try? await track.load(.timeRange)) ?? .invalid
        func tag(_ key: CFString) -> String? {
            guard let description = descriptions.first else { return nil }
            return CMFormatDescriptionGetExtension(description, extensionKey: key) as? String
        }
        return TrackPresentation(
            geometry: VideoOrientationMath.displayGeometry(naturalSize: size, preferredTransform: transform,
                                                          extraRotation: extraRotation),
            preferredTransform: transform,
            extraRotation: extraRotation,
            trackEnd: timeRange.isValid ? timeRange.end : .invalid,
            colorPrimaries: tag(kCMFormatDescriptionExtension_ColorPrimaries),
            colorTransferFunction: tag(kCMFormatDescriptionExtension_TransferFunction),
            colorYCbCrMatrix: tag(kCMFormatDescriptionExtension_YCbCrMatrix)
        )
    }

    /// The reader output for `track`: the raw track output for clips that
    /// need no rotation (every Apple video — byte-for-byte the historical
    /// path), a composition output that applies the rotation otherwise,
    /// so every consumer downstream (fan-out, spanned slicing, snapshots,
    /// the contents-swap presenter) sees upright frames.
    private static func makeOutput(track: AVAssetTrack, presentation: TrackPresentation,
                                   frameRate: Float) -> AVAssetReaderOutput {
        let output: AVAssetReaderOutput
        if presentation.needsComposition {
            let composed = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: decodedOutputSettings)
            composed.videoComposition = makeComposition(track: track, presentation: presentation, frameRate: frameRate)
            output = composed
        } else {
            output = AVAssetReaderTrackOutput(track: track, outputSettings: decodedOutputSettings)
        }
        output.alwaysCopiesSampleData = false
        return output
    }

    /// One instruction over the whole track applying the display
    /// transform. Frame timing follows the source track (VFR clips keep
    /// their PTS, which the loop math and the catch-up watermark rely
    /// on); `frameDuration` is still required and set from the nominal
    /// rate. Colour tags are copied when the track carries all three so
    /// HDR sources are composed in their own colour space.
    private static func makeComposition(track: AVAssetTrack, presentation: TrackPresentation,
                                        frameRate: Float) -> AVVideoComposition {
        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layer.setTransform(presentation.geometry.transform, at: .zero)
        let end = presentation.trackEnd
        var instruction = AVVideoCompositionInstruction.Configuration()
        instruction.timeRange = CMTimeRange(start: .zero, end: end.isNumeric && end > .zero ? end : .positiveInfinity)
        instruction.layerInstructions = [AVVideoCompositionLayerInstruction(configuration: layer)]
        let fps = frameRate > 1 ? frameRate : 30
        var configuration = AVVideoComposition.Configuration()
        configuration.renderSize = presentation.geometry.renderSize
        configuration.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        configuration.sourceTrackIDForFrameTiming = track.trackID
        configuration.instructions = [AVVideoCompositionInstruction(configuration: instruction)]
        if let primaries = presentation.colorPrimaries,
           let transfer = presentation.colorTransferFunction,
           let matrix = presentation.colorYCbCrMatrix {
            configuration.colorPrimaries = primaries
            configuration.colorTransferFunction = transfer
            configuration.colorYCbCrMatrix = matrix
        }
        return AVVideoComposition(configuration: configuration)
    }

    /// EXIF orientation that rotates a picture clockwise by `degrees`.
    private static func exifOrientation(clockwiseDegrees degrees: Int) -> CGImagePropertyOrientation {
        switch ((degrees % 360) + 360) % 360 {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    /// Sample-buffer display layers receiving the broadcast. Every
    /// subscriber registers its own `requestMediaDataWhenReady` feed
    /// callback (see `startFeeding`): any of them can drive the shared
    /// reader, and the fan-out keeps them all fed — there is no single
    /// "pacer" whose stall or removal can freeze the rest.
    private(set) var subscribers: [AVSampleBufferDisplayLayer] = []

    /// Variant D ghost hosts: contents-swap layers registered by the
    /// handler so transitions can freeze ghosts over them — their AVSBDL
    /// twins are off-tree orphans that fail the ghost pass's superlayer
    /// guard. Weak (the handler owns layer lifetime); mutated on `queue`.
    private let ghostHosts = NSHashTable<CALayer>.weakObjects()

    func addGhostHost(_ layer: CALayer) {
        queue.async { self.ghostHosts.add(layer) }
    }

    func removeGhostHost(_ layer: CALayer) {
        queue.async { self.ghostHosts.remove(layer) }
    }

    /// Everything a transition should freeze a ghost over: in-tree
    /// AVSBDL subscribers (orphans are filtered by the superlayer guard
    /// in the ghost pass) plus registered contents-swap layers. Call on
    /// `queue`.
    private func transitionTargets() -> [CALayer] {
        subscribers + ghostHosts.allObjects
    }

    /// Per-layer revival bookkeeping for `.failed` sampleBufferRenderers —
    /// throttles recovery attempts (once per 2 s per layer) and counts them
    /// in a rolling 60 s window so a permanently sick layer logs a loud
    /// beacon instead of spamming the pump. `lifetime` never resets and
    /// drives log suppression: an abandoned-window layer (Tahoe agent
    /// churn) revives every 2 s FOREVER — 813 spam lines in one field
    /// session — so only revivals #1-3 and every 10th log. Mutated only
    /// on `queue`.
    private var layerRevivals: [ObjectIdentifier: (count: Int, windowStart: CFAbsoluteTime, lastAttempt: CFAbsoluteTime, lifetime: Int)] = [:]

    /// Wall-clock of each subscriber's attach, surfaced as `age=` in the
    /// snapshot — an old subscriber with a runaway skip total is the
    /// abandoned-window signature at a glance. Renderer queue only.
    private var subscribedAt: [ObjectIdentifier: CFAbsoluteTime] = [:]

    /// Short within-process identity for a layer, so revival lines can
    /// be correlated across a log (there's no wid at renderer level).
    private static func layerTag(_ layer: AVSampleBufferDisplayLayer) -> String {
        let ptr = UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque())
        return String(ptr & 0xFFFFF, radix: 16)
    }

    /// Per-subscriber consecutive fan-out skips (`isReadyForMoreMediaData`
    /// false). A momentarily-full layer skips a handful and catches up;
    /// a layer stuck not-ready skips FOREVER with healthy status — the
    /// 2026-07-08 spanned split (left window frozen on an old video while
    /// the right played, same renderer) was exactly this, invisible to
    /// the `.failed`/needsFlush sweeps and the renderer-global watchdog.
    /// At `stuckSkipThreshold` the layer gets the revival treatment.
    /// Renderer queue only.
    private var consecutiveSkips: [ObjectIdentifier: Int] = [:]
    /// Lifetime skip totals (diagnostics only — `skips=` in the snapshot).
    private var totalSkips: [ObjectIdentifier: Int] = [:]
    /// ~1 s of 240 fps content, ~8 s of 30 fps — long enough that a
    /// genuine burst of back-pressure never trips it.
    private static let stuckSkipThreshold = 240

    /// Per-subscriber high-water mark of successfully enqueued PTS
    /// (loop-adjusted timeline). Drives `catchUpLaggards()`: a layer
    /// whose mark trails `lastFanoutPTS` missed frames while full and
    /// gets them re-offered from the in-flight ring. Cleared with the
    /// ring on every timeline reset. Renderer queue only.
    private var lastEnqueuedPTS: [ObjectIdentifier: CMTime] = [:]
    /// Newest PTS the fan-out has offered to subscribers.
    private var lastFanoutPTS: CMTime = .invalid
    /// Lifetime frames recovered by the catch-up pass (diagnostics —
    /// `caughtUp=` in the snapshot).
    private var framesCaughtUp: UInt64 = 0

    /// Total failed-layer revivals since this renderer started, surfaced
    /// in `diagnosticsSnapshot()` so tester logs show healing at a glance.
    private var layerRevives = 0

    /// Revival back-off (churn mitigation): after this many revivals in
    /// one episode the layer is treated as agent-abandoned — probes drop
    /// from every 2 s to every `revivalBackoffInterval`. A quiet gap of
    /// `revivalEpisodeReset` closes the episode, so a layer that healed
    /// and jams again much later starts fresh at the fast cadence.
    private static let revivalBackoffAfter = 12
    private static let revivalBackoffInterval: CFAbsoluteTime = 300
    private static let revivalEpisodeReset: CFAbsoluteTime = 600

    /// Whether `layer` is currently in a stuck skip-streak (not-ready
    /// across a whole fan-out streak — the abandoned-window signature).
    /// Sync hop onto the renderer queue; called rarely (churn-eviction
    /// checks on acquire).
    func isSubscriberStuck(_ layer: AVSampleBufferDisplayLayer) -> Bool {
        published.withLockUnchecked { $0.stuckIDs.contains(ObjectIdentifier(layer)) }
    }

    /// Pixel buffer of the newest DECODED frame — may run ≤~2 s ahead
    /// of the visible frame (decode order). Survives deep pause and
    /// recreates (only an explicit swap clears `lastSample`), which is
    /// exactly why the acquire prime and the snapshot reply use it as
    /// the fallback when the presenting ring is empty. Mirror read — never
    /// waits on the renderer queue.
    func lastDecodedImageBuffer() -> CVPixelBuffer? {
        published.withLockUnchecked { $0.lastSample }.flatMap { CMSampleBufferGetImageBuffer($0) }
    }

    /// Cheap content identity for the disk-snapshot dedupe: current
    /// asset + coarse timebase position. Identical while paused —
    /// nothing new presents, and re-encoding that unchanged frame was
    /// the bulk of the 2026-08-29 disk-write diagnostics (505 × ~4 MB).
    /// Mirror read; safe from any thread.
    func snapshotIdentity() -> String {
        let name = published.withLockUnchecked { $0.asset.url.lastPathComponent }
        let time = CMTimebaseGetTime(timebase).seconds
        return "\(name)@\(String(format: "%.1f", time))"
    }

    /// Latched true between detecting end-of-reader and the swap/rebuild
    /// re-registering the feed, so a second already-queued driver callback
    /// can't race into a double swap. Mutated only on `queue`.
    private var feedSuspended = false

    /// An explicit swap arrived with no pre-buffered next reader (deep
    /// pause nils both readers; back-to-back advances outrun the async
    /// prepare). The swap defers until `installNextReader` lands instead
    /// of rebuilding the CURRENT asset with a passthrough reader — the
    /// old fallback's compressed samples carry no image buffer, so every
    /// variant-D window (ring → contents-swap presenter) froze while
    /// playback continued invisibly (2026-08-29 field bundle). Remembers
    /// the swap flavor so a deferred natural EOF stays gapless.
    /// Queue-confined.
    private var pendingSwapWhenPrepared = false
    private var pendingSwapFlush = false

    /// One-shot beacon: a compressed sample reached the pump. Should be
    /// impossible with every reader decoded — scream once if it returns.
    private var warnedCompressedSamples = false

    /// What the playlist hooks hand over for a loop boundary or a jump:
    /// the file to play and the entry's play-duration override (seconds
    /// of playtime; nil = play once). Carried with the pop rather than
    /// looked up by URL — the same video can sit twice in a playlist
    /// with different durations.
    struct NextVideo {
        let url: URL
        let playDuration: Double?
    }

    /// Loop-boundary hook for forward direction. The handler installs
    /// this with `ExtensionVideoLoader.getNextVideo(...)`.
    var nextVideoProvider: (() -> NextVideo?)?
    /// Extra rotation (degrees, clockwise) the user set for the video at
    /// a URL — the Library's per-video override. Consulted whenever a
    /// reader is built for a URL the hooks handed us (next / previous /
    /// jump); the first video's value arrives through `create`. nil or 0
    /// means "the file's own metadata only".
    var rotationOverrideProvider: ((URL) -> Int)?

    /// Mirror for backward direction, called by `regressNow()`.
    var previousVideoProvider: (() -> NextVideo?)?

    /// Fired on the renderer queue whenever the playing video CHANGES
    /// (natural EOF rotation and manual swaps alike; same-URL loops
    /// don't fire). The handler debounces this into a status write so
    /// the Companion's now-playing follows organic rotation — do NOT do
    /// synchronous work here, and never call back into `queue.sync`
    /// readers from it.
    var onVideoChanged: (() -> Void)?

    // MARK: - Construction

    /// " playFor=Ns" for log lines; empty without an override.
    private static func playForSuffix(_ playDuration: Double?) -> String {
        playDuration.map { String(format: " playFor=%.0fs", $0) } ?? ""
    }

    /// Build a renderer for the given video. The caller must attach
    /// at least one subscriber via `addSubscriber(_:)` before — or
    /// shortly after — calling `start()`; until then the timebase
    /// stays at rate 0 and no feeding happens.
    static func create(videoURL: URL, startAt: Double? = nil, extraRotation: Int = 0,
                       playDuration: Double? = nil) async throws -> VideoRenderer {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "No video track found in \(videoURL.lastPathComponent)",
            ])
        }
        let fps = (try? await track.load(.nominalFrameRate)) ?? 30
        let presentation = await loadPresentation(track: track, extraRotation: extraRotation)
        debugLog("🔄 [Renderer] \(videoURL.lastPathComponent): \(presentation.summary)\(playForSuffix(playDuration))")
        return try VideoRenderer(asset: asset, videoTrack: track, frameRate: fps, startAt: startAt,
                                 presentation: presentation, playDuration: playDuration)
    }

    /// Resume offset for the FIRST video only (cold-start resume from
    /// the playlist's persisted playbackTimestamp). Subsequent videos
    /// start at zero as before; deep-pause recreates resume via
    /// `deepPauseResumePosition`.
    private let startOffset: CMTime

    /// In-asset position captured at deep pause so `recreatePlayback()`
    /// resumes where the video stopped instead of restarting the clip
    /// (the "video rolls back at saver engage" report). One-shot:
    /// consumed by the next recreate, cleared on video switch and stop.
    private var deepPauseResumePosition: CMTime = .zero

    private init(asset: AVURLAsset, videoTrack: AVAssetTrack, frameRate: Float, startAt: Double? = nil,
                 presentation: TrackPresentation, playDuration: Double? = nil) throws {
        self.asset = asset
        self.videoTrack = videoTrack
        self.presentation = presentation
        self.currentFrameRate = frameRate
        self.currentPlayDuration = playDuration
        self.startOffset = startAt.map { CMTime(sanitizedSeconds: $0, "start offset") } ?? .zero
        self.published = OSAllocatedUnfairLock(uncheckedState: Published(
            asset: asset, extraRotation: presentation.extraRotation, lastEnqueueAt: CFAbsoluteTimeGetCurrent()
        ))

        // Practically never fails, but a crash here takes down the
        // whole extension (black wallpaper on every display) — throw
        // instead and let the acquire path surface the error.
        var tb: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb,
        )
        guard status == noErr, let timebase = tb else {
            throw NSError(domain: "com.glouel.aerial.renderer", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "CMTimebaseCreateWithSourceClock failed (\(status))",
            ])
        }
        self.timebase = timebase
        CMTimebaseSetTime(timebase, time: .zero)
        // Rate stays 0 until first subscriber + start() — prevents the
        // timebase from advancing during the async gap between init
        // and start, which would cause the first batch of frames to
        // be "late" and dropped.
        CMTimebaseSetRate(timebase, rate: 0.0)
        self.transition = VideoTransitionCoordinator(timebase: timebase, queue: queue)
        self.audio = AudioPipeline(queue: queue)
        audio.requestReconcile = { [weak self] context in
            self?.reconcileAudio(context: context)
        }
    }

    // MARK: - Audio (optional sidecar)

    /// Audio gate: the video's soundtrack plays only while the timebase
    /// ACTUALLY runs at 1.0× — screensaver, or wallpaper at 100% speed.
    /// Never during ramps (audio fades instead of pitch-following), and
    /// never on the lock screen (`lockedScreenRate` is also 1.0, so the
    /// physical-rate check alone can't exclude it). Read on `queue`.
    private var audioShouldPlay: Bool {
        audioEnabled && audioDesiredVolume > 0.001
            && lockedScreenCount == 0
            && activeRampKind == nil
            && !effectivePaused
            && !subscribers.isEmpty
            && abs(Double(CMTimebaseGetRate(timebase)) - 1.0) < 0.01
    }

    /// Converge the audio sidecar to the gate. Must run on `queue`.
    private func reconcileAudio(context: String) {
        guard isRunning else { return }
        audio.reconcile(
            shouldPlay: audioShouldPlay,
            asset: asset,
            videoTime: CMTimebaseGetTime(timebase),
            ptsBase: ptsOffset,
            context: context
        )
    }

    /// Companion's audio intent (audio-owner policy already folded into
    /// `enabled` by the handler). Applies live via the reconcile.
    func setAudio(enabled: Bool, volume: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            let vol = Float(max(0, min(1, volume)))
            guard audioEnabled != enabled || audioDesiredVolume != vol else { return }
            audioEnabled = enabled
            audioDesiredVolume = vol
            audio.setDesiredVolume(vol)
            debugLog("  [Renderer] audio → \(enabled ? "on" : "off") vol=\(String(format: "%.2f", vol))")
            reconcileAudio(context: enabled ? "audio-on" : "audio-off")
        }
    }

    // MARK: - Subscribers

    /// Build a new display layer suitable for subscription. Caller is
    /// responsible for parenting it (`rootLayer.addSublayer(...)`).
    static func makeDisplayLayer(size: CGSize, contentsScale: CGFloat) -> AVSampleBufferDisplayLayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        layer.frame = CGRect(origin: .zero, size: size).sanitized("display layer")
        layer.contentsScale = contentsScale
        return layer
    }

    /// Attach a display layer. Sets its `controlTimebase` to ours, so
    /// the renderer paces it. The first attached subscriber becomes
    /// the pacer (drives requestMediaDataWhenReady); subsequent ones
    /// are passive — they receive the same samples synchronously.
    func addSubscriber(_ layer: AVSampleBufferDisplayLayer) {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            layer.controlTimebase = self.timebase
            let wasEmpty = subscribers.isEmpty
            subscribers.append(layer)
            subscribedAt[ObjectIdentifier(layer)] = CFAbsoluteTimeGetCurrent()
            debugLog("  [Renderer] subscriber +1 → \(subscribers.count) total (layer \(Self.layerTag(layer)))")
            // Instant join: present the most recent decoded frame right
            // away. Without this the new layer stays black (or on its
            // snapshot prime) until the timebase reaches the PTS of the
            // first streamed sample — which ends at a different moment
            // on every display, making multi-screen saver entry look
            // staggered.
            if let sample = lastSample, let immediate = Self.displayImmediatelyCopy(of: sample) {
                layer.sampleBufferRenderer.enqueue(immediate)
            }
            // ...then replay the in-flight (not-yet-presented) samples so
            // the join keeps presenting on the shared timebase instead of
            // sitting on the prime until this layer's feed callback fires.
            // Readiness-gated and capped to the near-now PTS window —
            // see `replayInflight`.
            let replayed = replayInflight(into: layer)
            if replayed > 0 {
                debugLog("  [Renderer] instant-join replayed \(replayed) in-flight frame(s) (window-capped)")
            }
            // Watermark rides the replayed frames (raised per enqueue);
            // anything the window/readiness gate held back stays in the
            // ring for catchUpLaggards() once the layer has room.
            // First subscriber after an idle gap kicks the timebase
            // (start() leaves it at rate 0 while there's nobody to feed,
            // and reassert holds it at 0 whenever the last one leaves). A
            // paused renderer with no reader is a deep pause or a resume
            // deferred while idle — the reassert rebuilds it.
            if wasEmpty, currentReader != nil || isPaused {
                reassertPlaybackState(context: "subscriber+1")
            } else if wasEmpty, currentReader == nil, wdAttempt > 0, watchdogRecreateTimer == nil {
                // The watchdog killed the reader while nobody was
                // subscribed — rebuild now that someone is.
                scheduleWatchdogRecreate(after: 0)
            }
            // Join the driver pool — every subscriber drives its own feed,
            // so no single layer is the pacer. Skipped while paused or
            // mid-swap; `startFeeding()` registers it then.
            if currentReader != nil, !isPaused, !feedSuspended {
                registerFeed(on: layer)
            }
            publish()
        }
    }

    func removeSubscriber(_ layer: AVSampleBufferDisplayLayer) {
        queue.async { [weak self] in
            guard let self else { return }
            layer.sampleBufferRenderer.stopRequestingMediaData()
            subscribers.removeAll { $0 === layer }
            layerRevivals.removeValue(forKey: ObjectIdentifier(layer))
            consecutiveSkips.removeValue(forKey: ObjectIdentifier(layer))
            totalSkips.removeValue(forKey: ObjectIdentifier(layer))
            lastEnqueuedPTS.removeValue(forKey: ObjectIdentifier(layer))
            subscribedAt.removeValue(forKey: ObjectIdentifier(layer))
            // Its scene is going away — ghosts stacked over it would
            // orphan on a dead context.
            transition.removeGhosts(for: layer)
            debugLog("  [Renderer] subscriber -1 → \(subscribers.count) total")
            // No pacer handoff: every remaining layer drives its own feed,
            // so dropping one (screen disconnect / Space churn) never stalls
            // the rest and needs no re-election.
            if subscribers.isEmpty {
                // Nobody watching: hold the timebase. It used to keep
                // running at the nominal rate while the pump idled, so the
                // timeline drifted seconds ahead of the decoder, the
                // persisted position ran past short clips, and the next
                // join/cold start fast-forwarded through late frames
                // (2026-09-21 saver-only bundle). A pause landing (.down)
                // finishes on its own — it ends at rate 0 anyway.
                if activeRampKind != .down { cancelRamp() }
                reassertPlaybackState(context: "subscriber-0")
            }
            publish()
        }
    }

    func feedsLayer(_ layer: AVSampleBufferDisplayLayer) -> Bool {
        published.withLockUnchecked { $0.subscriberIDs.contains(ObjectIdentifier(layer)) }
    }

    var subscriberCount: Int {
        published.withLockUnchecked { $0.subscriberIDs.count }
    }

    // MARK: - Lifecycle

    /// Start playback. Opens the reader and starts the timebase if a
    /// subscriber is already attached. If not, waits — the first
    /// `addSubscriber` after start() will kick the feed loop.
    func start() {
        guard let reader = try? AVAssetReader(asset: asset) else { return }
        // Cold-start resume: read from the persisted position and set the
        // timebase to match — samples arrive with PTS ≥ offset, so the
        // first frame presents immediately at the resumed position. Loop
        // math is unaffected (ptsOffset stays 0; lastEnqueuedEnd tracks
        // absolute PTS). A stale position past the clip (older builds let
        // the idle timebase drift and persisted it) would seek past the
        // last sample — instant EOF and a late-frame fast-forward through
        // the next clip — so it is clamped to the clip here, the only
        // place that knows the duration synchronously.
        let clipSeconds = videoTrack.timeRange.duration.seconds
        let resumeSeconds = PlaybackMath.resumeStart(requested: startOffset.seconds, clipDuration: clipSeconds)
        let effectiveStart: CMTime = resumeSeconds > 0 ? startOffset : .zero
        if startOffset > .zero, resumeSeconds == 0 {
            debugLog("⏱ [Renderer] resume position \(String(format: "%.1f", startOffset.seconds))s beyond clip (\(String(format: "%.1f", clipSeconds))s) — starting from 0")
        }
        if effectiveStart > .zero {
            reader.timeRange = CMTimeRange(start: effectiveStart, duration: .positiveInfinity)
        }
        let output = Self.makeOutput(track: videoTrack, presentation: presentation, frameRate: currentFrameRate)
        reader.add(output)
        reader.startReading()

        // Everything below is state the render queue reads — publish it ON
        // the queue, like stop() does. makeRenderer queues setNominalRate /
        // setAudio before calling start(), and their reconcile read
        // `ptsOffset` while this thread was still writing it (three-word
        // CMTime torn write; TSan on the live extension, 2026-09-05).
        // Nothing in here re-enters `queue` synchronously: prepareNextReader
        // is queue.async, startFeeding only registers callbacks on `queue`.
        queue.sync {
            CMTimebaseSetTime(timebase, time: effectiveStart)

            currentReader = reader
            currentOutput = output
            ptsOffset = .zero
            lastEnqueuedEnd = .zero
            // Bounded loop: the entry's budget window opens where playback
            // starts (the resumed position on a cold start).
            budgetStartTB = effectiveStart
            budgetCutTB = nil
            budgetCutFired = false
            boundedLoopPasses = 0

            // Only start the timebase if we have a subscriber to feed.
            // Otherwise it advances while we're waiting and the first
            // frame would be "late."
            if !subscribers.isEmpty {
                CMTimebaseSetRate(timebase, rate: effectiveRate)
            }

            prepareNextReader()
            if !subscribers.isEmpty {
                startFeeding()
            }
            publish()
        }
    }

    /// Stop playback. Cancels the readers FIRST, from this thread — the
    /// one AVFoundation call that unblocks a pump stuck inside
    /// `copyNextSampleBuffer` — then hops onto the queue with a bound so
    /// a teardown can never hang behind a wedged pump (the teardown
    /// timer thread used to block forever). The queued body still runs
    /// once the queue frees up, which is the intended teardown.
    func stop() {
        cancelDeepPauseTimer()
        cancelRamp()
        cancelWatchdogRecreateTimer()
        let (current, next) = published.withLockUnchecked { ($0.currentReader, $0.nextReader) }
        current?.cancelReading()
        next?.cancelReading()
        let finished: Void? = BoundedSync.run(on: queue, timeout: .seconds(5)) { [self] in
            isRunning = false
            deepPauseResumePosition = .zero
            audio.teardown()
            transition.teardown()
            stopFeedingAll()
            currentReader?.cancelReading()
            nextReader?.cancelReading()
            // cancelReading() is async; release the readers so their file handles close before the process suspends (0xdead10cc).
            currentReader = nil
            currentOutput = nil
            nextReader = nil
            nextOutput = nil
            publish()
        }
        if finished == nil {
            debugLog("⚠️ [Renderer] stop(): queue unresponsive after 5s — readers cancelled, teardown left queued")
        }
    }

    // MARK: - Pause / Resume (reason-based)

    /// Add a pause reason. Idempotent per reason; the physical pause
    /// lands via `reassertPlaybackState()` (deferred while a saver/lock
    /// presents — except `.policy`, which always wins).
    func pause(reason: PauseReasons) {
        queue.async { [weak self] in
            guard let self, !pauseReasons.contains(reason) else { return }
            pauseReasons.insert(reason)
            reassertPlaybackState(context: "+\(reason.summary)")
        }
    }

    /// Remove a pause reason. Playback resumes only when NO reason
    /// remains — the set IS the cross-source arbitration (a battery
    /// clear can never un-pause a user pause, coverage never overrides
    /// either).
    func resume(reason: PauseReasons) {
        queue.async { [weak self] in
            guard let self, pauseReasons.contains(reason) else { return }
            pauseReasons.remove(reason)
            reassertPlaybackState(context: "-\(reason.summary)")
        }
    }

    /// Bulk-set the Companion-driven reasons (user/battery/coverage/
    /// thermal/camera), preserving `.policy`. Used to seed fresh
    /// renderers at acquire/rekey and by the control listener's lineage
    /// re-baseline.
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
            reassertPlaybackState(context: "seed")
        }
    }

    /// System presentation policy (activityState). `paused` (suspended —
    /// display asleep) force-pauses even while a saver/lock presents.
    /// `animated` rides the lock-transition ramps.
    func applyActivityPolicy(paused: Bool, animated: Bool) {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            guard pauseReasons.contains(.policy) != paused else { return }
            if paused {
                pauseReasons.insert(.policy)
            } else {
                pauseReasons.remove(.policy)
            }
            // `animated` is legacy (kept for the protocol signature):
            // policy pauses are instant by rule, and every resume eases
            // via the reassert now.
            reassertPlaybackState(context: paused ? "+policy" : "-policy")
        }
    }

    /// THE pause/rate choke point: converges the physical timebase state
    /// (`isPaused` + rate) to the current intent (`effectivePaused`) and
    /// the current `effectiveRate`. Called after EVERY mutation — reason
    /// changes, saver/lock transitions, nominal-rate changes, subscriber
    /// arrival, ramp completions — so nothing can strand a stale rate or
    /// a dropped pause. Must run on `queue`.
    ///
    /// Ramp discipline: a live ramp owns the rate — this never writes the
    /// rate mid-ramp, and every ramp completion calls back here so intent
    /// or rate changes made DURING a ramp land at its end. Converging
    /// INTO a pause cancels a live ramp (the old model let a rampUp keep
    /// easing the rate up over a freshly paused renderer).
    private func reassertPlaybackState(easeRate: Bool = false, context: String = "") {
        guard isRunning else { return }
        // Audio converges after every playback-state decision; the defer
        // covers every return path (ramp starts, instant pauses, direct
        // rate sets). The reconcile no-ops when nothing changed.
        defer {
            reconcileAudio(context: context)
            publish()
        }
        if effectivePaused {
            guard !isPaused else { return }
            // Display-asleep pauses (and Reduce Motion) land instantly —
            // everything else eases to a stop over the fps-adjusted
            // slowdown (the historical DesktopLauncher behavior).
            if pauseReasons.contains(.policy) || reduceMotion {
                cancelRamp()
                isPaused = true
                CMTimebaseSetRate(timebase, rate: 0.0)
                scheduleDeepPause()
                debugLog("  [Renderer] paused [\(pauseReasons.summary)] \(context)")
                return
            }
            if activeRampKind == .down {
                // Already easing to a stop — an extra pause reason
                // doesn't restart the deceleration.
                return
            }
            // A live rampUp/rampRate loses to the pause: ease down from
            // wherever the rate is right now.
            cancelRamp()
            debugLog("  [Renderer] pausing (ramp \(String(format: "%.2f", adaptiveRampDuration))s) [\(pauseReasons.summary)] \(context)")
            rampDown(duration: adaptiveRampDuration)
        } else {
            if pendingPlaylistJump {
                // A playlist cut was deferred while paused — run it now
                // that we're converging to playing. jumpNow()'s async
                // re-dispatch on `queue` lands AFTER this convergence, so
                // a deep-pause resume has already recreated its readers.
                pendingPlaylistJump = false
                debugLog("  [Renderer] executing deferred playlist jump on resume")
                jumpNow()
            }
            if activeRampKind == .down {
                // Resumed mid-slowdown — abort the deceleration and
                // converge back up below instead of dipping to a full
                // stop first.
                cancelRamp()
            }
            if isPaused {
                // Nobody to feed: leave the pause (and its deep-pause
                // timer) in place; the next subscriber's reassert resumes.
                // Resuming here used to rampUp an idle renderer and let the
                // timeline run away from the decoder.
                guard !subscribers.isEmpty else {
                    debugLog("  [Renderer] resume deferred — no subscribers (\(context))")
                    return
                }
                isPaused = false
                cancelDeepPauseTimer()
                if currentReader == nil {
                    recreatePlayback()
                }
                let deferred = pauseReasons.isEmpty ? "" : " (deferred: \(pauseReasons.summary))"
                if !reduceMotion, rampTimer == nil {
                    // Every resume eases up (the old occlusion
                    // resumeAndRampUp behavior — symmetric with the
                    // eased pause landing).
                    debugLog("  [Renderer] resuming (ramp \(String(format: "%.2f", adaptiveRampDuration))s) \(context)\(deferred)")
                    rampUp(duration: adaptiveRampDuration)
                    return
                }
                debugLog("  [Renderer] resumed \(context)\(deferred)")
            }
            // Watchdog belt: a reader the watchdog killed while the
            // renderer was (or ended up) physically playing gets no
            // `isPaused` transition to rebuild it above — re-arm now.
            if currentReader == nil, wdAttempt > 0, watchdogRecreateTimer == nil {
                scheduleWatchdogRecreate(after: 0)
            }
            if rampTimer == nil {
                if subscribers.isEmpty {
                    // Invariant: no subscribers ⇒ physical rate 0. The
                    // intent stays "playing" (no pause reason, no deep
                    // pause — readers stay warm for the teardown grace);
                    // only the timeline stops so it can't run ahead of a
                    // decoder that isn't decoding.
                    if CMTimebaseGetRate(timebase) > 0 {
                        CMTimebaseSetRate(timebase, rate: 0)
                        debugLog("⏱ [Renderer] idle — no subscribers, timebase held at \(String(format: "%.1f", CMTimebaseGetTime(timebase).seconds))s (\(context))")
                    }
                } else {
                    let target = effectiveRate
                    if easeRate, !reduceMotion, abs(Double(CMTimebaseGetRate(timebase)) - target) > 0.01 {
                        // Saver/lock mode transitions glide between rates
                        // (1.0× ↔ nominal) instead of snapping.
                        debugLog("  [Renderer] rate ease → \(target) over \(String(format: "%.2f", adaptiveRampDuration))s (\(context))")
                        rampRate(to: target, duration: adaptiveRampDuration)
                    } else {
                        CMTimebaseSetRate(timebase, rate: target)
                    }
                }
            }
        }
    }

    /// Change the live transition config (style + natural-boundary
    /// duration). Read at each video boundary — nothing to re-assert.
    func setTransitionConfig(_ config: TransitionConfig) {
        queue.async { [weak self] in
            guard let self, transition.config != config else { return }
            transition.config = config
            debugLog("  [Renderer] transition → \(config.style.rawValue) \(String(format: "%.2f", config.duration))s")
        }
    }

    /// Change the live playback rate. `reassertPlaybackState` applies it
    /// immediately when playing (unless a ramp owns the rate — then it
    /// lands at ramp completion); while paused, the new rate lands at
    /// resume.
    func setNominalRate(_ rate: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            nominalRate = rate
            reassertPlaybackState(context: "rate=\(rate)")
        }
    }

    /// Note a screensaver subscriber attaching. While `count > 0`, the
    /// renderer plays at 1.0× regardless of `nominalRate`, and
    /// user/coverage/battery pauses are inhibited (never show a paused
    /// saver — a standing pause resumes here and re-lands at exit).
    func enterScreensaverMode() {
        queue.async { [weak self] in
            guard let self else { return }
            screensaverSubscriberCount += 1
            if screensaverRateSuspended {
                // Saver re-engaged before the previous exit's INVALIDATE
                // landed — cancel the exit ramp and restore full speed.
                screensaverRateSuspended = false
                cancelRamp()
            }
            debugLog("  [Renderer] screensaver +1 → \(screensaverSubscriberCount), effectiveRate=\(effectiveRate)")
            reassertPlaybackState(easeRate: true, context: "saver-enter")
        }
    }

    /// FALLBACK screensaver-mode toggle driven by distributed notifications /
    /// update()-idle (see `WallpaperXPCHandler`). Sets the independent
    /// `screensaverActiveFromNotification` flag WITHOUT touching
    /// `screensaverSubscriberCount`, so it never fights the acquire-driven path —
    /// `effectiveRate`/`pauseInhibited` OR the two together. Idempotent.
    /// On clear, any deferred pause reasons re-land via the reassert.
    func setScreensaverModeFromNotification(_ active: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard screensaverActiveFromNotification != active else { return }
            if active, screensaverRateSuspended {
                // Saver re-engaged during the exit window (agent reused
                // the live windows — no acquire, so enterScreensaverMode's
                // re-engage handling never runs). The suspension gates
                // both effectiveRate and pauseInhibited — without
                // clearing it here, the exit's deferred pause ramp lands
                // mid-session and freezes the saver.
                screensaverRateSuspended = false
                cancelRamp()
                debugLog("  [Renderer] screensaver re-engaged (notif) — canceling exit ramp")
            }
            screensaverActiveFromNotification = active
            debugLog("  [Renderer] screensaver(notif) → \(active), effectiveRate=\(effectiveRate)")
            reassertPlaybackState(easeRate: true, context: active ? "saver-notif-on" : "saver-notif-off")
        }
    }

    /// The lock/login screen engaged on a wallpaper of this renderer.
    /// Like the screensaver, the lock screen must never show a paused
    /// frame — a standing pause resumes here (inhibition) and re-lands
    /// at unlock via the reassert.
    func enterLockedMode() {
        queue.async { [weak self] in
            guard let self else { return }
            lockedScreenCount += 1
            debugLog("  [Renderer] locked +1 → \(lockedScreenCount), effectiveRate=\(effectiveRate)")
            reassertPlaybackState(easeRate: true, context: "lock-enter")
        }
    }

    /// Unlock. Any pause reasons deferred by the lock inhibition land
    /// via the reassert the moment the last locked wallpaper clears.
    func exitLockedMode() {
        queue.async { [weak self] in
            guard let self else { return }
            guard lockedScreenCount > 0 else { return }
            lockedScreenCount -= 1
            debugLog("  [Renderer] locked -1 → \(lockedScreenCount), effectiveRate=\(effectiveRate)")
            reassertPlaybackState(easeRate: true, context: "lock-exit")
        }
    }

    /// URL of the asset currently feeding subscribers. Read by the
    /// control listener to decide whether a playlist change requires
    /// cutting the current video.
    var currentAssetURL: URL {
        published.withLockUnchecked { $0.asset.url }
    }

    /// One coherent snapshot for the status reporter — a single queue
    /// hop instead of one per field. `position` is clamped ≥ 0: right
    /// after a gapless swap the new video's content position is briefly
    /// negative (the timebase hasn't reached the cut yet).
    struct StatusSnapshot {
        let assetURL: URL
        let position: Double
        let rate: Double
        let pauseReasons: PauseReasons
        let saverActive: Bool
    }

    /// Mirror read + thread-safe timebase reads — never waits on the
    /// renderer queue (the status writer runs on the main thread from
    /// the control-notification observer).
    func statusSnapshot() -> StatusSnapshot {
        let p = published.withLockUnchecked { $0 }
        return StatusSnapshot(
            assetURL: p.asset.url,
            position: max(0, CMTimeSubtract(CMTimebaseGetTime(timebase), p.ptsOffset).seconds),
            rate: Double(CMTimebaseGetRate(timebase)),
            pauseReasons: p.pauseReasons,
            saverActive: p.saverActive
        )
    }

    /// Position within the current asset, in seconds (the timebase runs
    /// continuously across gapless boundaries; ptsOffset corrects it).
    /// Read by the progress flusher. Mirror read.
    var currentContentPosition: Double {
        let offset = published.withLockUnchecked { $0.ptsOffset }
        return CMTimeSubtract(CMTimebaseGetTime(timebase), offset).seconds
    }

    /// The saver visually exited (its wids got `update(mode: default)`)
    /// but WallpaperAgent won't invalidate them for another ~5 s. Drop
    /// the rate override now and ease back to the wallpaper's nominal
    /// rate — waiting for the invalidate meant 5 s at full speed followed
    /// by an instant snap.
    func beginScreensaverExitRamp() {
        queue.async { [weak self] in
            guard let self else { return }
            guard screensaverSubscriberCount > 0, !screensaverRateSuspended else { return }
            screensaverRateSuspended = true
            debugLog("  [Renderer] screensaver exit — easing to nominal \(nominalRate)")
            // One converge covers both outcomes: a deferred pause lands
            // as the eased slowdown at the VISUAL exit (not ~5 s later
            // at the INVALIDATE), and a playing wallpaper glides from
            // 1.0× down to its nominal rate.
            reassertPlaybackState(easeRate: true, context: "saver-exit-ramp")
        }
    }

    /// The saver re-engaged during the exit window (WallpaperAgent
    /// reused the still-live saver windows — no fresh acquire, so
    /// `enterScreensaverMode()` never runs). Undo the exit ramp: clear
    /// the suspension, cancel any in-flight slowdown/pause ramp, and
    /// reassert — saver-active inhibits the deferred pause again and
    /// the rate eases back to 1.0. Without this, a quick exit→restart
    /// froze the saver: the suspension kept `effectiveRate` at nominal
    /// and `pauseInhibited` false, so the exit's deferred user pause
    /// landed one second into the new session.
    func cancelScreensaverExitRamp() {
        queue.async { [weak self] in
            guard let self, screensaverRateSuspended else { return }
            screensaverRateSuspended = false
            cancelRamp()
            debugLog("  [Renderer] screensaver re-engaged — canceling exit ramp")
            reassertPlaybackState(easeRate: true, context: "saver-reenter")
        }
    }

    /// Note a screensaver subscriber detaching. When the count returns
    /// to zero, the renderer reverts to `nominalRate` (the user's
    /// wallpaper speed) and any deferred pause reasons re-land via the
    /// reassert. Call from `invalidate()` for screensaver wallpapers
    /// BEFORE the refCount decrement / teardown timer.
    func exitScreensaverMode() {
        queue.async { [weak self] in
            guard let self else { return }
            guard screensaverSubscriberCount > 0 else { return }
            screensaverSubscriberCount -= 1
            if screensaverSubscriberCount == 0 {
                // Bookkeeping only when the exit ramp already ran (the
                // update(default) signal precedes this INVALIDATE by ~5 s
                // and effectiveRate is already nominal).
                screensaverRateSuspended = false
            }
            debugLog("  [Renderer] screensaver -1 → \(screensaverSubscriberCount), effectiveRate=\(effectiveRate)")
            reassertPlaybackState(easeRate: true, context: "saver-exit")
        }
    }

    /// Repeat-one enforcement: while enabled, `prepareNextReader` skips
    /// the provider and re-primes the current asset, so the playlist is
    /// never popped and the on-screen video loops gaplessly. Re-primes
    /// the pre-buffered reader on change so a mid-video flip applies at
    /// the very next loop boundary (the pop is pipelined one video
    /// ahead — without the re-prime, the stale pre-buffer would play one
    /// more video before the mode landed).
    func setLoopCurrentVideo(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, loopCurrentVideo != enabled else { return }
            loopCurrentVideo = enabled
            debugLog("  [Renderer] loopCurrentVideo → \(enabled)")
            guard isRunning else { return }
            prepareNextReaderOnQueue()
        }
    }

    /// Force an immediate swap to the next video, behind a manual-skip
    /// transition (ghost of the presenting frame fades over the cut;
    /// falls through to the old instant flush when transitions are off).
    func advanceNow() {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            pendingPlaylistJump = false
            graceJumpGeneration &+= 1
            debugLog("  [Renderer] advanceNow() invoked")
            // A bounded-loop re-prime is buffered: swapping to it would
            // replay the clip, but an explicit advance means the NEXT
            // entry — pop the provider now and rebuild (jumpNow's shape).
            // Repeat-one keeps its pin; the control listener routes that
            // case to jumpNow() itself.
            if nextOrigin == .boundedLoop, let pick = nextVideoProvider?() {
                nextPlayDuration = pick.playDuration
                if pick.url != asset.url {
                    rebuildAndSwap(to: pick.url)
                    return
                }
            }
            transition.performImmediateTransition(subscribers: transitionTargets()) { [weak self] in
                guard let self, isRunning else { return }
                swapToNextReader(flushDisplayBuffer: true)
            }
        }
    }

    /// Mirror of `advanceNow()` for the previous direction. Asks
    /// `previousVideoProvider` for the previous video, installs it
    /// as the next reader, then swaps in (with flush).
    func regressNow() {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            pendingPlaylistJump = false
            graceJumpGeneration &+= 1
            debugLog("  [Renderer] regressNow() invoked")
            let pick = previousVideoProvider?()
            if let pick { nextPlayDuration = pick.playDuration }
            guard let pick, pick.url != asset.url else {
                transition.performImmediateTransition(subscribers: transitionTargets()) { [weak self] in
                    guard let self, isRunning else { return }
                    swapToNextReader(flushDisplayBuffer: true)
                }
                return
            }
            rebuildAndSwap(to: pick.url)
        }
    }

    /// Jump straight to the provider's current selection — used after
    /// `seekPlaylist` set a new `currentIndex`. Unlike `advanceNow()` (which
    /// swaps whatever was *already* buffered), this rebuilds the buffered
    /// reader from `nextVideoProvider`, so the seeked video shows on the
    /// FIRST call instead of one jump late.
    func jumpNow() {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            pendingPlaylistJump = false
            graceJumpGeneration &+= 1
            debugLog("  [Renderer] jumpNow() invoked")
            let pick = nextVideoProvider?()
            // The picked entry's budget applies even for the same file (a
            // duplicate entry with its own duration, or a re-jump to the
            // current one, which restarts the window at the flush).
            if let pick { nextPlayDuration = pick.playDuration }
            guard let pick, pick.url != asset.url else {
                transition.performImmediateTransition(subscribers: transitionTargets()) { [weak self] in
                    guard let self, isRunning else { return }
                    swapToNextReader(flushDisplayBuffer: true)
                }
                return
            }
            rebuildAndSwap(to: pick.url)
        }
    }

    /// Playlist-changed cut: like `jumpNow()`, but while the pause intent
    /// is active the cut is deferred until resume — a paused screen must
    /// never visibly change videos. User navigation (advance/regress/jump)
    /// never routes here and always cuts immediately. Uses
    /// `effectivePaused` so a cut during the pause ramp defers too, while
    /// the saver/lock inhibit window (visibly playing) cuts immediately.
    func jumpWhenResumed() {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            guard effectivePaused else {
                // Playing: don't cut immediately. When the playlist change
                // came from an explicit "play this" action, the user jump
                // usually lands in the NEXT reconcile a few ms later
                // (regenerate and jump are separate control mutations) —
                // cutting now races two reader rebuilds: double ghost
                // transition, stalled feeder, watchdog-recovery swap
                // seconds later. Arm the cut behind a short grace window
                // instead; an explicit navigation bumps the generation and
                // this cut evaporates. Changes with no follow-up jump
                // (download completions, popover edits) just cut ~0.3s
                // later, imperceptibly.
                graceJumpGeneration &+= 1
                let generation = graceJumpGeneration
                queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                    guard let self, isRunning, graceJumpGeneration == generation else { return }
                    if effectivePaused {
                        // Paused during the window — hand over to the
                        // resume-time deferral instead of cutting a
                        // paused screen.
                        pendingPlaylistJump = true
                        debugLog("  [Renderer] grace-window playlist cut deferred — paused meanwhile")
                        return
                    }
                    debugLog("  [Renderer] executing playlist cut after grace window")
                    jumpNow()
                }
                return
            }
            pendingPlaylistJump = true
            debugLog("  [Renderer] playlist jump deferred while paused [\(pauseReasons.summary)]")
        }
    }

    /// A later reconcile found the current video survives after all —
    /// drop the deferred cut (and any pending grace-window cut) so the
    /// screen doesn't jump needlessly.
    func cancelDeferredJump() {
        queue.async { [weak self] in
            guard let self else { return }
            graceJumpGeneration &+= 1
            if pendingPlaylistJump {
                pendingPlaylistJump = false
                debugLog("  [Renderer] deferred playlist jump cancelled — current video survives")
            }
        }
    }

    /// Cancel any buffered next reader, load `url` fresh, install it as the
    /// next reader, then swap to it (flushing the display buffer). Shared by
    /// `regressNow()` and `jumpNow()` — both must show a provider-chosen URL
    /// *now*, unlike `advanceNow()` which swaps whatever was already buffered.
    /// Must be called on `queue`.
    private func rebuildAndSwap(to url: URL) {
        nextReader?.cancelReading()
        nextReader = nil
        nextOutput = nil
        let newAsset = AVURLAsset(url: url)
        let rotationFor = rotationOverrideProvider
        Task.detached { @Sendable [weak self] in
            guard let self else { return }
            guard let track = try? await newAsset.loadTracks(withMediaType: .video).first else {
                debugLog("  [Renderer] rebuildAndSwap: no video track in \(url.lastPathComponent)")
                return
            }
            nonisolated(unsafe) let loadedTrack = track
            let fps = (try? await loadedTrack.load(.nominalFrameRate)) ?? 30
            let nextPres = await Self.loadPresentation(track: loadedTrack, extraRotation: rotationFor?(url) ?? 0)
            queue.async { [weak self] in
                guard let self, isRunning else { return }
                installNextReader(asset: newAsset, track: loadedTrack, frameRate: fps, presentation: nextPres)
                transition.performImmediateTransition(subscribers: transitionTargets()) { [weak self] in
                    guard let self, isRunning else { return }
                    swapToNextReader(flushDisplayBuffer: true)
                }
            }
        }
    }

    // MARK: - Ramp (Apple-like eased rate changes)

    private static let rampStepInterval: TimeInterval = 1.0 / 120.0

    private static func easeInOut(_ t: Double) -> Double {
        t < 0.5
            ? 4.0 * t * t * t
            : 1.0 - pow(-2.0 * t + 2.0, 3) / 2.0
    }

    /// Most of the deceleration in the first quarter, barely-visible
    /// tail — the "slow down to a stop" feel (matches the historical
    /// DesktopLauncher curve).
    private static func easeOutCubic(_ t: Double) -> Double {
        1.0 - pow(1.0 - t, 3)
    }

    /// Ease the PHYSICAL timebase rate down to a stop over `duration`,
    /// then land the pause (isPaused + deep-pause schedule). Starts from
    /// `CMTimebaseGetRate`, not `effectiveRate` — in the saver-exit case
    /// the suspended flag already makes effectiveRate nominal while the
    /// timebase still runs at 1.0×, and easing must start where the
    /// viewer is.
    private func rampDown(duration: TimeInterval) {
        guard !isPaused else { return }
        let from = Double(CMTimebaseGetRate(timebase))
        guard from > 0.01 else {
            // Effectively stopped already — land instantly.
            isPaused = true
            CMTimebaseSetRate(timebase, rate: 0.0)
            scheduleDeepPause()
            return
        }
        let totalSteps = max(1, Int(sanitizing: duration / Self.rampStepInterval, "ramp steps", fallback: 1))
        var step = 0

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else {
                timer.cancel()
                return
            }
            step += 1
            let progress = Double(step) / Double(totalSteps)
            let eased = Self.easeOutCubic(progress)
            CMTimebaseSetRate(self.timebase, rate: max(from * (1.0 - eased), 0.0))

            if step >= totalSteps {
                timer.cancel()
                self.rampTimer = nil
                self.activeRampKind = nil
                self.isPaused = true
                self.scheduleDeepPause()
                // Intent may have flipped mid-ramp — converge.
                self.reassertPlaybackState(easeRate: true, context: "rampDown-complete")
            }
        }
        rampTimer = timer
        activeRampKind = .down
        timer.resume()
    }

    /// Eased 0 → effectiveRate. Bookkeeping (isPaused, deep-pause timer,
    /// reader rebuild) is done by `reassertPlaybackState` BEFORE calling.
    /// Completion re-asserts, so a rate/intent change mid-ramp lands at
    /// the end instead of dying on the captured target.
    private func rampUp(duration: TimeInterval) {
        let totalSteps = max(1, Int(sanitizing: duration / Self.rampStepInterval, "ramp steps", fallback: 1))
        var step = 0
        CMTimebaseSetRate(timebase, rate: 0.001)
        // Target the effective rate so a screensaver-during-ramp-up
        // climbs back to 1.0×, not the wallpaper's slow rate.
        let target = effectiveRate

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else {
                timer.cancel()
                return
            }
            step += 1
            let progress = Double(step) / Double(totalSteps)
            let eased = Self.easeInOut(progress)
            let rate = min(eased * target, target)
            CMTimebaseSetRate(self.timebase, rate: rate)

            if step >= totalSteps {
                timer.cancel()
                self.rampTimer = nil
                self.activeRampKind = nil
                self.reassertPlaybackState(easeRate: true, context: "rampUp-complete")
            }
        }
        rampTimer = timer
        activeRampKind = .up
        timer.resume()
    }

    private func cancelRamp() {
        rampTimer?.cancel()
        rampTimer = nil
        activeRampKind = nil
    }

    /// Ease the timebase from its CURRENT rate to `target` — no pause at
    /// the end (unlike rampDown). Drives the saver/lock rate glides
    /// (1.0× ↔ nominal) in both directions.
    private func rampRate(to target: Double, duration: TimeInterval) {
        cancelRamp()
        let from = Double(CMTimebaseGetRate(timebase))
        guard abs(from - target) > 0.0001 else { return }
        let totalSteps = max(1, Int(sanitizing: duration / Self.rampStepInterval, "ramp steps", fallback: 1))
        var step = 0

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else {
                timer.cancel()
                return
            }
            step += 1
            let progress = Double(step) / Double(totalSteps)
            let eased = Self.easeInOut(progress)
            CMTimebaseSetRate(self.timebase, rate: from + (target - from) * eased)

            if step >= totalSteps {
                timer.cancel()
                self.rampTimer = nil
                self.activeRampKind = nil
                self.reassertPlaybackState(easeRate: true, context: "rampRate-complete")
            }
        }
        rampTimer = timer
        activeRampKind = .rate
        timer.resume()
    }

    // MARK: - Off-queue mirror

    /// Refresh the off-queue mirror from the queue-confined state. Must
    /// run on `queue`. Cheap (one lock write, a few retains); called at
    /// every state change and at the end of every pump pass, so a site
    /// this list misses is corrected within one callback while playing.
    private func publish() {
        let stuck = Set(consecutiveSkips.lazy.filter { $0.value >= Self.stuckSkipThreshold }.map { $0.key })
        let snap = Published(
            asset: asset,
            ptsOffset: ptsOffset,
            pauseReasons: pauseReasons,
            isPaused: isPaused,
            saverActive: (screensaverSubscriberCount > 0 || screensaverActiveFromNotification) && !screensaverRateSuspended,
            lockedCount: lockedScreenCount,
            ssCount: screensaverSubscriberCount,
            ssNotif: screensaverActiveFromNotification,
            nominalRate: nominalRate,
            extraRotation: presentation.extraRotation,
            subscriberIDs: subscribers.map { ObjectIdentifier($0) },
            stuckIDs: stuck,
            lastSample: lastSample,
            currentReader: currentReader,
            nextReader: nextReader,
            lastEnqueueAt: lastEnqueueAt,
            framesEnqueued: framesEnqueued,
            wdRecreates: wdRecreates,
            wdAttempt: wdAttempt
        )
        published.withLockUnchecked { p in
            let cancels = p.wdCancels
            let cancelAt = p.lastWatchdogCancelAt
            p = snap
            p.wdCancels = cancels
            p.lastWatchdogCancelAt = cancelAt
        }
    }

    // MARK: - Pump watchdog (off-queue)

    /// Seconds the pump has been inside its current blocking AVFoundation
    /// call; nil when it is not in one. Lock read — any thread.
    var pumpBlockedSeconds: TimeInterval? {
        pumpBlock.withLockUnchecked { block in
            block.map { CFAbsoluteTimeGetCurrent() - $0.enteredAt }
        }
    }

    /// Run `body` (a call that may block inside AVFoundation) with the
    /// pump marker set, so the off-queue watchdog can see it. On `queue`.
    private func withPumpMarker<T>(reader: AVAssetReader, phase: String, _ body: () -> T) -> T {
        pumpBlock.withLockUnchecked { $0 = PumpBlock(reader: reader, phase: phase, enteredAt: CFAbsoluteTimeGetCurrent()) }
        defer { pumpBlock.withLockUnchecked { $0 = nil } }
        injectStallIfArmed(reader: reader, phase: phase)
        return body()
    }

    private func blockingCopyNext() -> CMSampleBuffer? {
        guard let output = currentOutput, let reader = currentReader else { return nil }
        return withPumpMarker(reader: reader, phase: "copyNext") { output.copyNextSampleBuffer() }
    }

    private func startReadingUnderMarker(_ reader: AVAssetReader) {
        _ = withPumpMarker(reader: reader, phase: "startReading") { reader.startReading() }
    }

    /// The watchdog proper: runs from the 2 s feed-health timer OFF the
    /// renderer queue. Reads the marker, and past `stallThreshold` cancels
    /// the stuck reader (the one call that makes a pending
    /// `copyNextSampleBuffer` return); if the queue is still inside the
    /// same call `escalateAfterCancel` later, AVFoundation ignored the
    /// cancel and the handler's escalation hook fires. Never calls
    /// AVFoundation under the lock.
    private func runPumpWatchdogOffQueue() {
        pollStallInjector()
        let now = CFAbsoluteTimeGetCurrent()
        var cancelTarget: AVAssetReader?
        var escalate = false
        var blockedFor: TimeInterval = 0
        var phase = ""
        pumpBlock.withLockUnchecked { block in
            guard var b = block else { return }
            blockedFor = now - b.enteredAt
            phase = b.phase
            switch PumpWatchdogPolicy.decide(enteredAt: b.enteredAt, cancelIssuedAt: b.cancelIssuedAt,
                                             escalated: b.escalated, now: now) {
            case .none:
                return
            case .cancel:
                b.cancelIssuedAt = now
                cancelTarget = b.reader
            case .escalate:
                b.escalated = true
                escalate = true
            }
            block = b
        }
        if let cancelTarget {
            watchdogCancelledReader.withLockUnchecked { $0 = cancelTarget }
            let (cancels, name) = published.withLockUnchecked { p -> (Int, String) in
                p.wdCancels += 1
                p.lastWatchdogCancelAt = now
                return (p.wdCancels, p.asset.url.lastPathComponent)
            }
            debugLog("⚠️🐕 [Renderer] pump watchdog: \(phase) blocked \(String(format: "%.1f", blockedFor))s (asset=\(name)) — cancelReading() from watchdog (#\(cancels))")
            cancelTarget.cancelReading()
        }
        if escalate {
            debugLog("⚠️🐕 [Renderer] pump still blocked \(String(format: "%.1f", blockedFor))s after cancelReading — renderer queue wedged; escalating")
            onQueueWedged?()
        }
    }

    /// The pump's nil branch for a watchdog-cancelled reader. Marks the
    /// reader dead, keeps the last frame on screen (no flush, ring and
    /// subscribers untouched, `nextReader` was never started) and arms
    /// the backoff rebuild. On `queue`.
    private func readerDiedUnderWatchdog() {
        let inAsset = CMTimeSubtract(CMTimebaseGetTime(timebase), ptsOffset)
        let clipDuration = videoTrack.timeRange.duration
        deepPauseResumePosition = (inAsset > .zero && inAsset < clipDuration) ? inAsset : .zero
        currentReader = nil
        currentOutput = nil
        wdAttempt += 1
        let delay = PumpWatchdogPolicy.backoffDelay(attempt: wdAttempt)
        debugLog("⚠️🐕 [Renderer] reader cancelled by watchdog — keeping last frame, rebuild in \(Int(delay))s (attempt #\(wdAttempt), resume at \(String(format: "%.1f", deepPauseResumePosition.seconds))s)")
        scheduleWatchdogRecreate(after: delay)
        publish()
    }

    private func scheduleWatchdogRecreate(after delay: TimeInterval) {
        watchdogRecreateTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.runWatchdogRecreate()
        }
        watchdogRecreateTimer = timer
        timer.resume()
    }

    private func cancelWatchdogRecreateTimer() {
        watchdogRecreateTimer?.cancel()
        watchdogRecreateTimer = nil
    }

    /// Backoff rebuild. Skips (and re-arms) while the renderer has no
    /// reason to decode — paused, or nobody subscribed; a resume that
    /// finds `currentReader == nil` rebuilds through the normal path and
    /// this handler then no-ops. On `queue`.
    private func runWatchdogRecreate() {
        watchdogRecreateTimer = nil
        guard isRunning, currentReader == nil, wdAttempt > 0 else { return }
        guard !effectivePaused, !subscribers.isEmpty else {
            let why = effectivePaused ? "paused [\(pauseReasons.summary)]" : "no subscribers"
            debugLog("🐕 [Renderer] watchdog rebuild deferred — \(why) (re-check in \(Int(PumpWatchdogPolicy.recheckDelay))s)")
            scheduleWatchdogRecreate(after: PumpWatchdogPolicy.recheckDelay)
            return
        }
        wdRecreates += 1
        debugLog("🐕 [Renderer] watchdog rebuild attempt #\(wdAttempt)")
        recreatePlayback()
        reassertPlaybackState(context: "watchdog-rebuild")
    }

    // MARK: - Debug stall injector

    /// One-shot trigger file: `soft` (spins until the watchdog's
    /// cancelReading lands, max 60 s) or `hard` (sleeps 60 s no matter
    /// what). Debug mode only; consumed on arm. Exercises the whole
    /// watchdog / mirror chain locally without a real post-wake wedge.
    private static let stallTriggerURL = URL(fileURLWithPath: "/Users/Shared/Aerial/Logs/debug-stall-pump")

    private func pollStallInjector() {
        guard PrefsAdvanced.debugMode,
              FileManager.default.fileExists(atPath: Self.stallTriggerURL.path),
              let raw = try? String(contentsOf: Self.stallTriggerURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: Self.stallTriggerURL)
        let mode = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mode.isEmpty else { return }
        armedStall.withLock { $0 = mode }
        debugLog("🧪 [Renderer] pump stall armed (\(mode)) — fires on the next blocking read")
    }

    private func injectStallIfArmed(reader: AVAssetReader, phase: String) {
        let mode = armedStall.withLock { armed -> String? in
            defer { armed = nil }
            return armed
        }
        guard let mode else { return }
        debugLog("🧪 [Renderer] injected pump stall (\(mode), 60s) in \(phase) — debugMode")
        let deadline = CFAbsoluteTimeGetCurrent() + 60
        while CFAbsoluteTimeGetCurrent() < deadline {
            if mode == "soft", reader.status == .cancelled { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        debugLog("🧪 [Renderer] injected pump stall over (\(mode), reader status=\(reader.status.rawValue))")
    }

    // MARK: - Deep Pause

    private static let deepPauseDelay: TimeInterval = 30

    private func scheduleDeepPause() {
        cancelDeepPauseTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.deepPauseDelay)
        timer.setEventHandler { [weak self] in
            self?.enterDeepPause()
        }
        deepPauseTimer = timer
        timer.resume()
    }

    private func cancelDeepPauseTimer() {
        deepPauseTimer?.cancel()
        deepPauseTimer = nil
    }

    private func enterDeepPause() {
        deepPauseTimer = nil
        guard isRunning, isPaused, currentReader != nil else { return }
        // Capture the in-asset position (timebase time minus the
        // accumulated loop shift) so the recreate resumes here rather
        // than rolling the clip back to zero. Out-of-range values
        // (edge races around a loop boundary) fall back to zero.
        let inAsset = CMTimeSubtract(CMTimebaseGetTime(timebase), ptsOffset)
        let clipDuration = videoTrack.timeRange.duration
        deepPauseResumePosition = (inAsset > .zero && inAsset < clipDuration) ? inAsset : .zero
        transition.cancelScheduled(reason: "deepPause")
        transition.clearRing()
        resetCatchUpWatermarks()
        audio.reset(context: "deep-pause")
        stopFeedingAll()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        currentReader = nil
        currentOutput = nil
        nextReader = nil
        nextOutput = nil
        pendingSwapWhenPrepared = false
        debugLog("  [Renderer] Deep-paused — freed asset readers")
        publish()
    }

    /// Rebuild the playback pipeline from scratch on the renderer queue.
    /// Used by deep-pause-wake and the error recovery path. Resumes the
    /// timeline at the position captured at deep pause when one exists
    /// (same cold-start-resume mechanics as `start()`), from zero
    /// otherwise (error recovery) — caller restores timebase rate.
    private func recreatePlayback() {
        let resumeAt = deepPauseResumePosition
        deepPauseResumePosition = .zero
        // Bounded loop: the budget window lives on the timeline being
        // reset — carry the playtime consumed so far over to the new
        // origin, so a deep-pause wake (or error recovery) neither
        // restarts nor forfeits the entry's budget.
        let budgetElapsed = max(CMTimeSubtract(CMTimebaseGetTime(timebase), budgetStartTB), .zero)
        // Timeline restarts below — a pending boundary fire would park
        // forever (backwards SetTime), the ring's PTS are stale, and
        // any ghost belongs to the old timeline.
        transition.cancelScheduled(reason: "recreate")
        transition.clearRing()
        resetCatchUpWatermarks()
        transition.removeAllGhosts()
        // Timeline resets below — stale audio PTS are garbage on it. The
        // reassert that always follows a recreate restarts audio anchored
        // at the resumed position.
        audio.reset(context: "recreate")
        feedSuspended = false
        stopFeedingAll()
        for layer in subscribers {
            layer.sampleBufferRenderer.flush()
        }
        ptsOffset = .zero
        lastEnqueuedEnd = .zero
        // `lastSample` deliberately survives: same asset, and the wake
        // recovery / snapshot reply need a frame right now (see its doc).
        CMTimebaseSetTime(timebase, time: resumeAt)
        budgetStartTB = CMTimeSubtract(resumeAt, budgetElapsed)
        budgetCutTB = nil
        budgetCutFired = false

        currentReader?.cancelReading()
        nextReader?.cancelReading()
        nextReader = nil
        nextOutput = nil
        pendingSwapWhenPrepared = false

        guard let reader = try? AVAssetReader(asset: asset) else {
            // Used to leave the renderer readerless forever — retry on
            // the watchdog ladder instead.
            currentReader = nil
            currentOutput = nil
            wdAttempt += 1
            let delay = PumpWatchdogPolicy.backoffDelay(attempt: wdAttempt)
            debugLog("⚠️🐕 [Renderer] Failed to create reader during recreate — retry in \(Int(delay))s (attempt #\(wdAttempt))")
            scheduleWatchdogRecreate(after: delay)
            publish()
            return
        }
        if resumeAt > .zero {
            reader.timeRange = CMTimeRange(start: resumeAt, duration: .positiveInfinity)
            debugLog("  [Renderer] recreate resumes at \(String(format: "%.1f", resumeAt.seconds))s")
        }
        let output = Self.makeOutput(track: videoTrack, presentation: presentation, frameRate: currentFrameRate)
        reader.add(output)
        startReadingUnderMarker(reader)
        currentReader = reader
        currentOutput = output

        prepareNextReader()
        startFeeding()
        publish()
    }

    // MARK: - Preloaded Loop Reader

    /// Repeat-one mode: short-circuits `prepareNextReader` onto the
    /// current asset. Set via `setLoopCurrentVideo(_:)`.
    private var loopCurrentVideo = false

    /// Ask `nextVideoProvider` what plays next. New URL → load + install
    /// next reader on a different asset. Same/nil → re-use current asset
    /// (gapless loop).
    private func prepareNextReader() {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            prepareNextReaderOnQueue()
        }
    }

    /// Body of `prepareNextReader` — must be called on `queue`.
    ///
    /// `skipBudget`: an explicit advance is completing through the
    /// deferred-swap path — the current entry's budget must not re-prime
    /// the clip the user just skipped.
    private func prepareNextReaderOnQueue(skipBudget: Bool = false) {
        if loopCurrentVideo {
            nextPlayDuration = currentPlayDuration
            installNextReader(asset: asset, track: videoTrack, frameRate: currentFrameRate, presentation: presentation,
                              origin: .repeatOne)
            return
        }
        // Bounded loop: decide at the start of this pass whether the clip
        // gets another pass after it (re-prime, no pop — repeat-one's
        // shape) or the playlist advances, and whether the budget runs
        // out before this pass ends (mid-pass cut, armed below once the
        // provider has confirmed a DIFFERENT clip follows — a
        // single-entry playlist keeps its seamless loop).
        var pendingCut: Double?
        if !skipBudget, let budget = currentPlayDuration, budget > 0 {
            let clip = videoTrack.timeRange.duration.seconds
            let plan = PlaybackMath.boundedLoopPlan(
                passStart: ptsOffset.seconds, clipDuration: clip,
                budgetStart: budgetStartTB.seconds, budget: budget
            )
            if plan.loopAgain {
                boundedLoopPasses += 1
                let playedAtPassEnd = ptsOffset.seconds + clip - budgetStartTB.seconds
                debugLog("  [Renderer] bounded loop: pass \(boundedLoopPasses + 1) queued — \(String(format: "%.1f", playedAtPassEnd))/\(String(format: "%.0f", budget))s at this pass end")
                nextPlayDuration = currentPlayDuration
                installNextReader(asset: asset, track: videoTrack, frameRate: currentFrameRate, presentation: presentation,
                                  origin: .boundedLoop)
                return
            }
            pendingCut = plan.cutAt
        }
        let pick = nextVideoProvider?()
        // nil pick = loop the current clip until a queued engine switch
        // lands; that stopgap loop carries no budget.
        nextPlayDuration = pick?.playDuration
        if let pick, pick.url != asset.url {
            if let cut = pendingCut {
                budgetCutTB = CMTime(sanitizedSeconds: cut, "bounded loop cut")
                debugLog("  [Renderer] bounded loop: budget ends mid-pass — cut at tb=\(String(format: "%.2f", cut))s")
            }
            let nextURL = pick.url
            let newAsset = AVURLAsset(url: nextURL)
            let rotationFor = rotationOverrideProvider
            Task.detached { @Sendable [weak self] in
                guard let self else { return }
                guard let track = try? await newAsset.loadTracks(withMediaType: .video).first else {
                    debugLog("  [Renderer] No video track in next video: \(nextURL.lastPathComponent)")
                    queue.async { [weak self] in
                        guard let self, isRunning else { return }
                        installNextReader(asset: asset, track: videoTrack, frameRate: currentFrameRate, presentation: presentation)
                    }
                    return
                }
                nonisolated(unsafe) let loadedTrack = track
                let fps = (try? await loadedTrack.load(.nominalFrameRate)) ?? 30
                let nextPres = await Self.loadPresentation(track: loadedTrack, extraRotation: rotationFor?(nextURL) ?? 0)
                queue.async { [weak self] in
                    guard let self, isRunning else { return }
                    installNextReader(asset: newAsset, track: loadedTrack, frameRate: fps, presentation: nextPres)
                }
            }
        } else {
            if pick == nil {
                debugLog("  [Renderer] nextVideoProvider returned nil — looping current asset")
            }
            installNextReader(asset: asset, track: videoTrack, frameRate: currentFrameRate, presentation: presentation)
        }
    }

    private func installNextReader(asset: AVURLAsset, track: AVAssetTrack, frameRate: Float,
                                   presentation nextPres: TrackPresentation,
                                   origin: NextReaderOrigin = .provider) {
        guard let reader = try? AVAssetReader(asset: asset) else {
            debugLog("  [Renderer] Failed to create next reader")
            pendingSwapWhenPrepared = false
            return
        }
        if asset.url != self.asset.url {
            debugLog("🔄 [Renderer] next \(asset.url.lastPathComponent): \(nextPres.summary)\(Self.playForSuffix(nextPlayDuration))")
        }
        nextOrigin = origin
        let output = Self.makeOutput(track: track, presentation: nextPres, frameRate: frameRate)
        reader.add(output)
        nextReader = reader
        nextOutput = output
        nextTrack = track
        nextPresentation = nextPres
        nextFrameRate = frameRate
        publish()
        if pendingSwapWhenPrepared {
            pendingSwapWhenPrepared = false
            debugLog("  [Renderer] completing deferred swap (next reader prepared)")
            swapToNextReader(flushDisplayBuffer: pendingSwapFlush)
        }
    }

    /// Swap to the preloaded next reader.
    ///
    /// `flushDisplayBuffer = false` (default): natural EOF loop — uses
    /// PTS offset for gapless continuation, no flush.
    ///
    /// `flushDisplayBuffer = true`: explicit advance/regress — flushes
    /// every subscriber's queue, resets PTS state and timebase to zero
    /// so the new video shows immediately. Rate untouched.
    private func swapToNextReader(flushDisplayBuffer: Bool = false) {
        feedSuspended = false
        stopFeedingAll()
        // Any reader swap starts a new timeline segment — a position
        // captured at an earlier deep pause must not leak into a later
        // recreate of a different video.
        deepPauseResumePosition = .zero
        // A bounded-loop cut is one-shot per pass; the prepare that
        // follows the swap re-arms it for the new pass when needed.
        let cutFired = budgetCutFired
        budgetCutFired = false
        budgetCutTB = nil

        if flushDisplayBuffer {
            // Defensive even when the caller already ran the manual
            // transition: a pending boundary fire would be silently
            // parked forever by the backwards SetTime below, and the
            // ring's PTS belong to the old timeline.
            transition.cancelScheduled(reason: "flushSwap")
            transition.clearRing()
            resetCatchUpWatermarks()
            for layer in subscribers {
                layer.sampleBufferRenderer.flush()
            }
            ptsOffset = .zero
            lastEnqueuedEnd = .zero
            lastSample = nil   // never instant-join with the outgoing video
            CMTimebaseSetTime(timebase, time: .zero)
        } else {
            // Continue where the decoder left off — but never in the
            // past. After a decode gap (cold-start EOF, a stall) the
            // enqueued end trails the timebase, and basing the next clip
            // there presented its first seconds late in a burst
            // (fast-forward). Re-basing to now costs nothing in the normal
            // case, where the decoder runs ahead.
            let now = CMTimebaseGetTime(timebase)
            let base = PlaybackMath.gaplessSwapBase(enqueuedEnd: lastEnqueuedEnd.seconds, now: now.seconds)
            if base.rebased {
                debugLog("⏱ [Renderer] gapless swap re-based: enqueuedEnd=\(String(format: "%.2f", lastEnqueuedEnd.seconds))s < now=\(String(format: "%.2f", now.seconds))s")
                ptsOffset = now
            } else {
                ptsOffset = lastEnqueuedEnd
            }
        }

        if let nr = nextReader, let no = nextOutput {
            let origin = nextOrigin
            nextOrigin = .provider
            if let nrAsset = nr.asset as? AVURLAsset, nrAsset.url != asset.url {
                debugLog("  [Renderer] Switched to next video: \(nrAsset.url.lastPathComponent)")
                if !flushDisplayBuffer {
                    // Natural gapless change: the cut *presents* when
                    // the timebase reaches the new ptsOffset — arm the
                    // ghost dance for that moment. Same-URL loops never
                    // reach here and stay seamless.
                    transition.scheduleBoundaryTransition(cutTime: ptsOffset) { [weak self] in
                        self?.transitionTargets() ?? []
                    }
                }
                asset = nrAsset
                if let nextTrack { videoTrack = nextTrack }
                onVideoChanged?()
            }
            if let nextPresentation { presentation = nextPresentation }
            // Bounded loop bookkeeping: a re-prime (repeat-one / bounded
            // loop) continues the current entry's window so playtime
            // accumulates across passes; anything the provider chose — a
            // different clip, the same clip again (single-entry playlist)
            // or an explicit restart — opens a new window at this pass
            // start (zero after a flush).
            if flushDisplayBuffer || origin == .provider {
                budgetStartTB = ptsOffset
                boundedLoopPasses = 0
            }
            currentPlayDuration = nextPlayDuration
            nextPlayDuration = nil
            currentReader = nr
            currentOutput = no
            nextReader = nil
            nextOutput = nil
            nextTrack = nil
            nextPresentation = nil
            currentFrameRate = nextFrameRate ?? currentFrameRate
            nextFrameRate = nil
        } else {
            // No pre-buffered next reader. The old fallback rebuilt the
            // CURRENT asset with `outputSettings: nil` — passthrough,
            // compressed samples, the only such reader in this file. It
            // silently restarted the clip instead of advancing, never
            // fired onVideoChanged, and blinded every variant-D window:
            // compressed samples have no image buffer, so the presenting
            // ring went dark while playback continued invisibly
            // (2026-08-29 field bundle — every hourly auto-advance on a
            // deep-paused renderer took this path and poisoned the next
            // saver engage). Defer instead: pop the real next video and
            // complete the swap when its DECODED reader lands.
            guard !pendingSwapWhenPrepared else { return }
            debugLog("  [Renderer] Next reader not ready — deferring swap until prepared")
            pendingSwapWhenPrepared = true
            pendingSwapFlush = flushDisplayBuffer
            prepareNextReaderOnQueue(skipBudget: flushDisplayBuffer)
            publish()
            return
        }

        if let reader = currentReader { startReadingUnderMarker(reader) }
        prepareNextReader()
        startFeeding()

        // Audio follows the swap: flush path re-anchors at the reset
        // timeline; the gapless path queues the new video's audio behind
        // the outgoing tail with the fresh ptsOffset.
        // A bounded-loop cut ends the outgoing clip mid-stream: its audio
        // was read past the cut, so restart anchored (as a flush would)
        // instead of queueing the next segment behind that tail.
        audio.videoDidSwap(
            asset: asset,
            shouldPlay: audioShouldPlay,
            videoTime: CMTimebaseGetTime(timebase),
            ptsBase: ptsOffset,
            flushed: flushDisplayBuffer || cutFired
        )

        // A paused explicit skip presents its one due frame and must then
        // wind down again. Without this, an hourly auto-advance on a
        // coverage-paused renderer left a live reader, a re-saturating
        // ring and NO deep-pause timer until the next resume — the
        // 2026-08-29 saver-join jam's precondition.
        if isPaused { scheduleDeepPause() }
        publish()
    }

    // MARK: - Playback Loop (multi-driver)

    /// Register a `requestMediaDataWhenReady` feed callback on EVERY
    /// subscriber. Whichever fires first pulls the next frames from the
    /// shared reader and fans them out to all layers with room; the rest
    /// then find their queues full and no-op. No single "pacer" drives the
    /// feed, so a stalled or removed layer can't freeze the others — and
    /// there's no handoff to elect on disconnect.
    private func startFeeding() {
        for layer in subscribers {
            registerFeed(on: layer)
        }
    }

    private func registerFeed(on layer: AVSampleBufferDisplayLayer) {
        let renderer = layer.sampleBufferRenderer
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.pumpFrames(driver: renderer)
        }
    }

    /// Revive a subscriber whose sampleBufferRenderer went `.failed`.
    /// Throttled per layer (2 s between attempts) so a permanently sick
    /// layer can't trigger recovery hundreds of times a second from the
    /// pump; the third revival inside 60 s logs a loud beacon. Runs on
    /// the renderer queue.
    private func reviveFailedLayer(_ layer: AVSampleBufferDisplayLayer) {
        let key = ObjectIdentifier(layer)
        let now = CFAbsoluteTimeGetCurrent()
        var tally = layerRevivals[key] ?? (count: 0, windowStart: now, lastAttempt: 0, lifetime: 0)
        if tally.lastAttempt > 0, now - tally.lastAttempt > Self.revivalEpisodeReset {
            tally.lifetime = 0
        }
        let interval: CFAbsoluteTime =
            tally.lifetime >= Self.revivalBackoffAfter ? Self.revivalBackoffInterval : 2
        guard now - tally.lastAttempt > interval else { return }
        if now - tally.windowStart > 60 {
            tally = (count: 0, windowStart: now, lastAttempt: tally.lastAttempt, lifetime: tally.lifetime)
        }
        tally.count += 1
        tally.lifetime += 1
        tally.lastAttempt = now
        layerRevivals[key] = tally
        layerRevives &+= 1
        if tally.lifetime == Self.revivalBackoffAfter {
            debugLog("⚠️⏳ [Renderer] layer \(Self.layerTag(layer)) still dead after \(tally.lifetime) revivals — backing off to \(Int(Self.revivalBackoffInterval))s probes (agent likely abandoned the window)")
        }

        let r = layer.sampleBufferRenderer
        if tally.lifetime <= 3 || tally.lifetime % 10 == 0 {
            let err = r.error.map { String(describing: $0) } ?? "no error"
            let age = Int(now - (subscribedAt[key] ?? now))
            debugLog("🚑 [Renderer] subscriber renderer failed (\(err)) — flush + re-prime + rejoin (layer \(Self.layerTag(layer)) age=\(age)s, revival #\(tally.lifetime)\(tally.lifetime > 3 ? ", logging every 10th" : ""))")
        }
        if tally.lifetime == 3 {
            debugLog("⚠️🚑 [Renderer] layer \(Self.layerTag(layer)) keeps failing — hosting side likely recycling its surface")
        }
        r.flush()
        if let sample = lastSample, let immediate = Self.displayImmediatelyCopy(of: sample) {
            r.enqueue(immediate)
        }
        registerFeed(on: layer)
    }

    /// Revive a subscriber stuck at `isReadyForMoreMediaData == false`
    /// (skip-streak detector in the fan-out). Same medicine as a failed
    /// layer — flush drops the jammed queue, the DisplayImmediately
    /// re-prime restores the current frame, in-flight replay bridges to
    /// the next fan-out round — and the same 2 s per-layer throttle via
    /// `layerRevivals`. Runs on the renderer queue.
    private func reviveStuckLayer(_ layer: AVSampleBufferDisplayLayer, streak: Int) {
        // Never during a ramp: thinning is suspended there, so the
        // fan-out runs at up to 8× the settled cadence and a joining
        // layer burns the 240-skip threshold in ~150 ms while the
        // timebase still crawls — reviving then flushes frames the layer
        // was about to present. The streak keeps counting; if the layer
        // is still stuck once the ramp settles, the next fan-out revives
        // it (2026-08-29: revival #1 at age=0s inside the resume ramp).
        guard rampTimer == nil else { return }
        let key = ObjectIdentifier(layer)
        let now = CFAbsoluteTimeGetCurrent()
        var tally = layerRevivals[key] ?? (count: 0, windowStart: now, lastAttempt: 0, lifetime: 0)
        if tally.lastAttempt > 0, now - tally.lastAttempt > Self.revivalEpisodeReset {
            tally.lifetime = 0
        }
        let interval: CFAbsoluteTime =
            tally.lifetime >= Self.revivalBackoffAfter ? Self.revivalBackoffInterval : 2
        guard now - tally.lastAttempt > interval else { return }
        if now - tally.windowStart > 60 {
            tally = (count: 0, windowStart: now, lastAttempt: tally.lastAttempt, lifetime: tally.lifetime)
        }
        tally.count += 1
        tally.lifetime += 1
        tally.lastAttempt = now
        layerRevivals[key] = tally
        layerRevives &+= 1
        if tally.lifetime == Self.revivalBackoffAfter {
            debugLog("⚠️⏳ [Renderer] layer \(Self.layerTag(layer)) still dead after \(tally.lifetime) revivals — backing off to \(Int(Self.revivalBackoffInterval))s probes (agent likely abandoned the window)")
        }

        if tally.lifetime <= 3 || tally.lifetime % 10 == 0 {
            let age = Int(now - (subscribedAt[key] ?? now))
            debugLog("⚠️🩹 [Renderer] subscriber stuck not-ready (\(streak) consecutive skips) — flush + re-prime (layer \(Self.layerTag(layer)) age=\(age)s, revival #\(tally.lifetime)\(tally.lifetime > 3 ? ", logging every 10th" : ""))")
        }
        if tally.lifetime == 3 {
            debugLog("⚠️🩹 [Renderer] layer \(Self.layerTag(layer)) keeps jamming — its presentation queue isn't draining (abandoned-window signature if it never recovers)")
        }
        let r = layer.sampleBufferRenderer
        r.flush()
        // The flush dropped this layer's queued frames — clear its
        // watermark so catch-up can re-offer them, then prime + replay
        // only the near-now window (re-stuffing the FULL ring is what
        // kept re-jamming the layer every 2 s).
        lastEnqueuedPTS.removeValue(forKey: key)
        if let sample = lastSample, let immediate = Self.displayImmediatelyCopy(of: sample) {
            r.enqueue(immediate)
        }
        replayInflight(into: layer)
        if currentReader != nil, !isPaused, !feedSuspended {
            registerFeed(on: layer)
        }
        consecutiveSkips[key] = 0
    }

    /// Wake recovery: unconditionally flush + re-prime + re-register every
    /// subscriber. The wake-stall shape (2026-07-06 trace) freezes one
    /// display's hosted surface across a system sleep while its layer looks
    /// healthy — `status != .failed` and no flush requested — so neither
    /// `reviveFailedLayer` nor the pump sweep can see it. `flush()` keeps
    /// the currently displayed image (unlike `flushAndRemoveImage`), so a
    /// paused wallpaper doesn't blank; the DisplayImmediately re-prime then
    /// forces a fresh composite of the last decoded frame through the
    /// hosted surface.
    func recoverAllLayers(reason: String) {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            // Refill from the presenting ring after the flush: the
            // DisplayImmediately prime restores the on-screen frame, and
            // the in-flight samples keep presentation seamless until the
            // re-registered feed takes over (frames already pinned by the
            // ring — zero extra memory).
            let primed = lastSample != nil
            debugLog("🚑 [Renderer] wake recovery (\(reason)): flushing \(subscribers.count) subscriber(s)\(primed ? " + re-prime" : " (no frame to re-prime — deep-paused)") + near-now ring replay")
            for layer in subscribers {
                let r = layer.sampleBufferRenderer
                r.flush()
                lastEnqueuedPTS.removeValue(forKey: ObjectIdentifier(layer))
                if let sample = lastSample, let immediate = Self.displayImmediatelyCopy(of: sample) {
                    r.enqueue(immediate)
                }
                replayInflight(into: layer)
                if currentReader != nil, !isPaused, !feedSuspended {
                    registerFeed(on: layer)
                }
            }
        }
    }

    private func stopFeedingAll() {
        for layer in subscribers {
            layer.sampleBufferRenderer.stopRequestingMediaData()
        }
    }

    /// Raise a subscriber's enqueued-PTS high-water mark. Marks never
    /// lower — samples arrive in decode order, so a reordered B-frame
    /// can carry a PTS below the mark. Renderer queue only.
    private func raiseWatermark(_ key: ObjectIdentifier, to pts: CMTime) {
        guard pts.isValid else { return }
        if let current = lastEnqueuedPTS[key], current.isValid, current >= pts { return }
        lastEnqueuedPTS[key] = pts
    }

    /// Drop all catch-up watermarks. Call wherever the ring is cleared —
    /// PTS from the old timeline are garbage on the new one, and a stale
    /// high mark would permanently disable catch-up for its layer.
    private func resetCatchUpWatermarks() {
        lastEnqueuedPTS.removeAll()
        lastFanoutPTS = .invalid
    }

    /// Timeline window for ring replays into a fresh/flushed layer: only
    /// frames within this many timeline-seconds of `now` are handed over.
    /// A saturated ring on a frozen timebase used to dump 64 far-future
    /// frames into a joining layer in one shot — it went not-ready before
    /// its first live frame and the healer kept re-stuffing the same set
    /// (2026-08-29 saver-join jam). Frames beyond the window stay in the
    /// ring for `catchUpLaggards()` once the layer has room again.
    private static let replayWindowSeconds = 2.0

    /// Replay in-flight ring samples into `layer`: readiness-gated per
    /// enqueue, oldest first, capped to the near-`now` window above.
    /// Raises the layer's watermark per replayed frame — a partial
    /// replay deliberately leaves catch-up room. Renderer queue only.
    @discardableResult
    private func replayInflight(into layer: AVSampleBufferDisplayLayer) -> Int {
        let r = layer.sampleBufferRenderer
        let key = ObjectIdentifier(layer)
        let horizon = CMTimeAdd(
            CMTimebaseGetTime(timebase),
            CMTime(seconds: Self.replayWindowSeconds, preferredTimescale: 600)
        )
        var replayed = 0
        for sample in transition.inflightSamples() {
            guard r.isReadyForMoreMediaData else { break }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isValid else { continue }
            if pts > horizon { break }
            r.enqueue(sample)
            raiseWatermark(key, to: pts)
            replayed += 1
        }
        return replayed
    }

    /// Re-offer missed, still-presentable samples to subscribers the
    /// fan-out passed by while they were momentarily full. Without this
    /// a skipped sample is gone for that layer — tolerable on 8×-
    /// oversampled 240 fps aerials, a visible hole on genuine 30 fps
    /// content. Replays from the in-flight ring (not-yet-presented
    /// samples only), so a laggard never shows a stale frame; a frame
    /// whose presentation time already passed stays skipped, as it
    /// would have been dropped as late anyway. Watermarks are PTS high
    /// marks, so a reordered frame below a layer's mark that raced the
    /// fan-out stays missed — rare, and strictly better than dropping
    /// every raced frame. Runs on `queue`.
    private func catchUpLaggards() {
        guard lastFanoutPTS.isValid else { return }
        var inflight: [CMSampleBuffer]?
        for layer in subscribers {
            let key = ObjectIdentifier(layer)
            if let mark = lastEnqueuedPTS[key], mark.isValid, mark >= lastFanoutPTS { continue }
            let r = layer.sampleBufferRenderer
            guard r.status != .failed, r.isReadyForMoreMediaData else { continue }
            let samples: [CMSampleBuffer]
            if let cached = inflight {
                samples = cached
            } else {
                samples = transition.inflightSamples()
                inflight = samples
            }
            for sample in samples {
                guard r.isReadyForMoreMediaData else { break }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                guard pts.isValid else { continue }
                if let mark = lastEnqueuedPTS[key], mark.isValid, pts <= mark { continue }
                r.enqueue(sample)
                raiseWatermark(key, to: pts)
                framesCaughtUp &+= 1
            }
        }
    }

    /// Feed body, invoked by whichever subscriber's renderer is ready for
    /// data. Pulls from the shared reader and enqueues to every ready
    /// subscriber. At end-of-reader, swap (or rebuild on reader failure).
    private func pumpFrames(driver: AVSampleBufferVideoRenderer) {
        guard isRunning, !subscribers.isEmpty, !feedSuspended else {
            driver.stopRequestingMediaData()
            return
        }
        // Every pass refreshes the off-queue mirror (lastSample, ptsOffset,
        // counters) — one lock write per callback, not per frame.
        defer { publish() }

        // Per-layer recovery — one stuck layer never forces a full renderer
        // reset. Two shapes:
        //  - `requiresFlushToResumeDecoding`: flush and it rejoins the
        //    fan-out on its own.
        //  - `.failed`: its own requestMediaData callback is DEAD, so it can
        //    only be revived here, on a HEALTHY driver's callback — flush,
        //    re-prime with the last frame, re-register its feed. Left alone
        //    it self-excludes forever: the fan-out skips it (never ready)
        //    while `fed=` keeps rising from the healthy layers — the frozen
        //    full-screen window behind the corner overlap (Logs-5 repro).
        // Reader-level failure is caught below; an all-layers wedge is
        // caught by the feed watchdog.
        for layer in subscribers {
            let r = layer.sampleBufferRenderer
            if r.status == .failed {
                reviveFailedLayer(layer)
            } else if r.requiresFlushToResumeDecoding {
                r.flush()
            }
        }

        catchUpLaggards()

        while driver.isReadyForMoreMediaData {
            guard let sample = blockingCopyNext() else {
                // End of this reader. Three shapes, checked in this
                // order: the watchdog cancelled a stuck read (rebuild on
                // the backoff ladder — never advance, never rebuild
                // inline); a genuine reader failure rebuilds; a clean EOF
                // gaplessly swaps to the next video. The `feedSuspended`
                // latch stops a second already-queued driver callback
                // from racing into a double swap.
                feedSuspended = true
                stopFeedingAll()
                let cancelledByWatchdog = watchdogCancelledReader.withLockUnchecked { (slot: inout AVAssetReader?) -> Bool in
                    defer { slot = nil }
                    guard let flagged = slot, let current = currentReader else { return false }
                    return flagged === current
                }
                let readerFailed = (currentReader?.status == .failed)
                queue.async { [weak self] in
                    guard let self, isRunning else { return }
                    if cancelledByWatchdog {
                        readerDiedUnderWatchdog()
                    } else if readerFailed {
                        recoverFromError()
                    } else {
                        swapToNextReader()
                    }
                }
                return
            }

            let adjusted = offsetTimingForLoop(sample)

            let pts = CMSampleBufferGetPresentationTimeStamp(adjusted)
            // Bounded loop: the entry's budget ends inside this pass — stop
            // feeding at the cut and swap exactly like a clean EOF (gapless
            // base at the last enqueued end, ghost transition armed there).
            // Waits for the next reader so the cut never takes the
            // deferred-swap path, which would pop the playlist a second
            // time; a slow load just delays the cut by a few frames.
            if let cut = budgetCutTB, pts.isValid, pts >= cut, nextReader != nil {
                budgetCutTB = nil
                budgetCutFired = true
                debugLog("  [Renderer] bounded loop: cut reached at tb=\(String(format: "%.2f", pts.seconds))s — advancing")
                feedSuspended = true
                stopFeedingAll()
                queue.async { [weak self] in
                    guard let self, isRunning else { return }
                    swapToNextReader()
                }
                return
            }
            let dur = CMSampleBufferGetDuration(adjusted)
            if pts.isValid {
                // Invalid duration: assume one frame at the source rate —
                // a hardcoded guess (formerly 1/60 s) halves the real
                // frame duration for 30 fps content and shifts the
                // gapless-loop offset.
                let fallbackDuration = CMTime(
                    value: 1,
                    timescale: max(1, CMTimeScale(sanitizing: currentFrameRate.rounded(), "fallback frame duration", fallback: 30))
                )
                let sampleEnd = dur.isValid && dur > .zero
                    ? CMTimeAdd(pts, dur)
                    : CMTimeAdd(pts, fallbackDuration)
                if sampleEnd > lastEnqueuedEnd {
                    lastEnqueuedEnd = sampleEnd
                }
            }

            // Thin the stream to the display's refresh BEFORE the
            // fan-out/ring so watermarks, laggard catch-up, and ghost
            // frames all see the same kept timeline. The loop
            // bookkeeping above (`lastEnqueuedEnd`) intentionally sees
            // every decoded sample so gapless offsets stay exact —
            // decode itself can't be skipped (HEVC reference chains),
            // but everything downstream of it can.
            if shouldDropForRefresh(pts) {
                framesDroppedForRefresh &+= 1
                continue
            }

            // Fan out to every subscriber with room; a momentarily-full
            // layer skips this sample and `catchUpLaggards()` re-offers
            // it from the in-flight ring on the next pump (a lost frame
            // is a 4 ms gap at 240 fps but a visible 33 ms hole at
            // 30 fps). A layer that skips a whole streak is stuck
            // (not-ready forever with healthy status) and gets flushed
            // back to life.
            for layer in subscribers {
                let r = layer.sampleBufferRenderer
                let key = ObjectIdentifier(layer)
                if r.isReadyForMoreMediaData {
                    r.enqueue(adjusted)
                    consecutiveSkips[key] = 0
                    if layerRevivals[key] != nil {
                        // The layer accepted a frame again — close its
                        // revival episode. Without this, the 300 s
                        // backoff could never expire (each probe
                        // refreshed lastAttempt before the 600 s episode
                        // reset could fire) and a healed layer restarted
                        // its next jam five minutes behind.
                        layerRevivals.removeValue(forKey: key)
                    }
                    raiseWatermark(key, to: pts)
                } else {
                    let streak = (consecutiveSkips[key] ?? 0) + 1
                    consecutiveSkips[key] = streak
                    totalSkips[key] = (totalSkips[key] ?? 0) + 1
                    if streak >= Self.stuckSkipThreshold {
                        reviveStuckLayer(layer, streak: streak)
                    }
                }
            }
            if pts.isValid, !(lastFanoutPTS.isValid && lastFanoutPTS >= pts) {
                lastFanoutPTS = pts
            }
            lastSample = adjusted
            if CMSampleBufferGetImageBuffer(adjusted) != nil {
                transition.noteEnqueued(adjusted, pts: pts)
            } else if !warnedCompressedSamples {
                warnedCompressedSamples = true
                debugLog("⚠️ [Renderer] compressed sample reached the pump (no image buffer) — presenters cannot show these")
            }
            lastEnqueueAt = CFAbsoluteTimeGetCurrent()
            framesEnqueued &+= 1
            if wdAttempt > 0 {
                // A frame reached the fan-out on a rebuilt reader — the
                // watchdog episode is over.
                let sinceCancel = published.withLockUnchecked { CFAbsoluteTimeGetCurrent() - $0.lastWatchdogCancelAt }
                debugLog("🐕 [Renderer] pump recovered after watchdog rebuild (attempt #\(wdAttempt), \(String(format: "%.1f", sinceCancel))s since cancel)")
                wdAttempt = 0
            }
        }
    }

    /// Refresh-cap thinning: should this decoded sample be dropped
    /// before the fan-out because the display can't present it anyway?
    /// Frames must land at least one vsync apart in WALL time, so the
    /// minimum CONTENT-time spacing between kept frames is
    /// `rate / refresh` — computed from the INSTANTANEOUS timebase
    /// rate, not the target: during a resume/saver ramp the target
    /// snaps to 1.0 while the timebase still crawls, and thinning for
    /// the target collapsed the displayed cadence at ramp start (the
    /// 2026-07-27 "stutter then fine mid-ramp" report). Tracking the
    /// real rate keeps ramps full-granularity and fades thinning in as
    /// the rate genuinely exceeds the display; the mild over-keep of
    /// frames presented later at a higher rate costs enqueues, never
    /// smoothness. Rate 0 (paused/priming) keeps everything, so the
    /// poster frame always lands. Runs on `queue`.
    private func shouldDropForRefresh(_ pts: CMTime) -> Bool {
        guard pts.isValid else { return false }
        guard lastKeptPTS.isValid, pts > lastKeptPTS else {
            // Fresh timeline (first frame, or a reader rebuild reset
            // PTS backwards) — keep and re-anchor the grid.
            lastKeptPTS = pts
            return false
        }
        // Never thin while a ramp is easing the rate: the grid spacing
        // is computed at ENQUEUE time but consumed at PRESENTATION time
        // ~a queue-depth later — during acceleration the rate has moved
        // by then and the mispredicted spacing lands frames 1-then-2
        // vsyncs apart (the 2026-07-27 mid-ramp judder). Ramps enqueue
        // everything (the pre-thinning, historically smooth config);
        // thinning resumes at the settled rate.
        guard rampTimer == nil else {
            lastKeptPTS = pts
            return false
        }
        let rate = Double(CMTimebaseGetRate(timebase))
        guard rate > 0, displayRefreshCap > 0,
              Double(currentFrameRate) > (displayRefreshCap / rate) * 1.05 else {
            lastKeptPTS = pts
            return false
        }
        let minSpacing = rate / displayRefreshCap
        let halfFrame = 0.5 / Double(max(1, currentFrameRate))
        if CMTimeGetSeconds(CMTimeSubtract(pts, lastKeptPTS)) + halfFrame < minSpacing {
            return true
        }
        lastKeptPTS = pts
        return false
    }

    /// Note the refresh rate of a display this renderer now feeds. The
    /// thinning cap keeps the MAX seen — a 120 Hz panel joining a 60 Hz
    /// one must not lose its extra frames; standing at 60 when nothing
    /// was ever reported is the conservative default.
    func noteDisplayRefresh(_ hz: Double) {
        queue.async { [weak self] in
            guard let self, hz > 0 else { return }
            if hz > displayRefreshCap { displayRefreshCap = hz }
        }
    }

    /// Copy a sample with the DisplayImmediately attachment set, so a
    /// freshly-joined layer presents it this frame instead of waiting
    /// for the timebase to reach the sample's PTS. The copy shares the
    /// underlying pixel buffer — only attachments differ. Also used by
    /// VideoTransitionCoordinator for its frozen ghost frames.
    static func displayImmediatelyCopy(of sample: CMSampleBuffer) -> CMSampleBuffer? {
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleBufferOut: &copy)
        guard let copy else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return copy
    }

    /// Offset both DTS and PTS of a sample for gapless looping.
    /// Returns the original sample unchanged for the first loop (no copy needed).
    /// For subsequent loops, creates a lightweight copy with adjusted timing
    /// (shares the underlying data buffer — only the timing metadata differs).
    private func offsetTimingForLoop(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard ptsOffset > .zero else { return sample }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dts = CMSampleBufferGetDecodeTimeStamp(sample)
        let dur = CMSampleBufferGetDuration(sample)

        var timingInfo = CMSampleTimingInfo(
            duration: dur,
            presentationTimeStamp: pts.isValid ? CMTimeAdd(pts, ptsOffset) : pts,
            decodeTimeStamp: dts.isValid ? CMTimeAdd(dts, ptsOffset) : .invalid
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

    /// Reset everything and restart playback from scratch after a decoder error.
    private func recoverFromError() {
        recreatePlayback()
        reassertPlaybackState(context: "recover")
    }

    /// One-line state summary for `dumpTopology` traces. Bounded hop onto
    /// the renderer queue so the counters read coherently; when the queue
    /// is wedged (or already known to be inside a long blocking call)
    /// the line is served from the off-queue mirror instead of piling
    /// another block behind the wedge. Never call from `queue` itself.
    func diagnosticsSnapshot() -> String {
        if let blocked = pumpBlockedSeconds, blocked > PumpWatchdogPolicy.skipHopAfter {
            noteQueueUnresponsive(blocked)
            return degradedDiagnosticsLine(blockedFor: blocked)
        }
        let started = CFAbsoluteTimeGetCurrent()
        if let line = BoundedSync.run(on: queue, timeout: .seconds(2), { [weak self] in
            self?.diagnosticsLineOnQueue() ?? "renderer gone"
        }) {
            queueUnresponsiveLogged.withLock { $0 = false }
            return line
        }
        noteQueueUnresponsive(pumpBlockedSeconds ?? (CFAbsoluteTimeGetCurrent() - started))
        return degradedDiagnosticsLine(blockedFor: pumpBlockedSeconds)
    }

    private func noteQueueUnresponsive(_ seconds: TimeInterval) {
        let first = queueUnresponsiveLogged.withLock { logged -> Bool in
            if logged { return false }
            logged = true
            return true
        }
        if first {
            debugLog("⚠️ [Renderer] renderer queue unresponsive for \(String(format: "%.1f", seconds))s — degraded diagnostics from mirror")
        }
    }

    private func degradedDiagnosticsLine(blockedFor: TimeInterval?) -> String {
        let p = published.withLockUnchecked { $0 }
        let phase = pumpBlock.withLockUnchecked { $0?.phase }
        return RendererDegradedLine.format(
            subs: p.subscriberIDs.count, paused: p.isPaused, reasons: p.pauseReasons.summary,
            fed: p.framesEnqueued, sinceFeed: CFAbsoluteTimeGetCurrent() - p.lastEnqueueAt,
            tbTime: CMTimebaseGetTime(timebase).seconds, tbRate: Double(CMTimebaseGetRate(timebase)),
            asset: p.asset.url.lastPathComponent, blockedFor: blockedFor, phase: phase,
            wdCancels: p.wdCancels, wdRecreates: p.wdRecreates, wdAttempt: p.wdAttempt
        )
    }

    /// The live diagnostics line. Runs on `queue`.
    private func diagnosticsLineOnQueue() -> String {
        let tbTime = String(format: "%.1f", CMTimebaseGetTime(timebase).seconds)
        let tbRate = CMTimebaseGetRate(timebase)
        let sinceFeed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - lastEnqueueAt)
        // Per-subscriber skip totals in subscription order — a large
        // or growing number on one layer is the stuck-not-ready
        // signature (see reviveStuckLayer).
        let skips = subscribers
            .map { "\(totalSkips[ObjectIdentifier($0)] ?? 0)" }
            .joined(separator: "/")
        // Subscriber attach ages in the same order as skips= — an
        // OLD subscriber with a runaway skip total is a window the
        // agent abandoned without invalidating (Tahoe churn).
        let nowAbs = CFAbsoluteTimeGetCurrent()
        let ages = subscribers
            .map { "\(Int(nowAbs - (subscribedAt[ObjectIdentifier($0)] ?? nowAbs)))s" }
            .joined(separator: "/")
        // locked=/ssNotif= : the pause-inhibition inputs. A non-zero
        // locked count while every window is mode=default is the
        // leaked-counter signature (2026-07-10) — rate pinned at
        // 1.0×, every Companion pause deferred forever.
        let budget = currentPlayDuration.map { String(format: " playFor=%.0fs pass=%d", $0, boundedLoopPasses + 1) } ?? ""
        let cancels = published.withLockUnchecked { $0.wdCancels }
        let wd = (cancels > 0 || wdRecreates > 0) ? " wd=cancels:\(cancels)/recreates:\(wdRecreates)/attempt:\(wdAttempt)" : ""
        return "subs=\(subscribers.count) ssCount=\(screensaverSubscriberCount) locked=\(lockedScreenCount) ssNotif=\(screensaverActiveFromNotification) nominal=\(nominalRate) tbRate=\(tbRate) tbTime=\(tbTime)s paused=\(isPaused) reasons=\(pauseReasons.summary) audio=\(audioEnabled ? audio.diagnostics() : "off") fed=\(framesEnqueued) dropped=\(framesDroppedForRefresh) skips=\(skips) age=\(ages) caughtUp=\(framesCaughtUp) revived=\(layerRevives) lastFeed=\(sinceFeed)s\(budget)\(wd) asset=\(asset.url.lastPathComponent)"
    }

    /// Watchdog: a renderer that claims to play but hasn't enqueued a
    /// sample in several seconds has a dead feed loop. The known shape: the
    /// pacer's `requestMediaDataWhenReady` callback never fires (e.g. the
    /// layer's renderer went `.failed` while it WASN'T the pacer — all
    /// failure/flush recovery lives inside that callback, so a dead pacer
    /// can never heal itself). At any playing rate the feed enqueues many
    /// times per second (the interval depends on source fps and rate —
    /// ~4 ms for 240 fps at 1.0×, up to ~33 ms for 30 fps sources or
    /// 240 fps at 0.125×) and swaps are gapless, so 4 s of silence is
    /// unambiguous. Recovery reuses
    /// `recoverFromError()` (full flush + reader rebuild + pacer
    /// re-registration). Called from a dedicated ~2 s feed-watchdog timer.
    func checkFeedHealth() {
        // Off-queue first: the on-queue check below can't run while the
        // pump is wedged — it would sit behind the very call it should
        // be catching. This phase reads only lock-protected markers.
        runPumpWatchdogOffQueue()
        queue.async { [weak self] in
            guard let self,
                  isRunning,
                  !isPaused,
                  !subscribers.isEmpty,
                  currentReader != nil,
                  CMTimebaseGetRate(timebase) > 0.01 else { return }
            let silence = CFAbsoluteTimeGetCurrent() - lastEnqueueAt
            guard silence > 4 else { return }
            debugLog("⚠️ [Renderer] feed watchdog: no samples enqueued in \(String(format: "%.0f", silence))s (subs=\(subscribers.count), asset=\(asset.url.lastPathComponent)) — recovering")
            // Give recovery a fresh full window so the tighter threshold
            // can't re-fire on the next ~2 s tick before the rebuilt feed
            // lands its first frame.
            lastEnqueueAt = CFAbsoluteTimeGetCurrent()
            recoverFromError()
        }
    }

    /// Shared CIContext for the lastSample → CGImage conversion below.
    /// One per process — CIContext setup is expensive.
    private static let snapshotContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Variant D (contents-swap experiment): the pixel buffer of the
    /// frame that should be ON SCREEN right now, per the presenting
    /// ring's timebase pick — NOT `lastSample`, which is the newest
    /// DECODED frame and runs ahead of presentation by the enqueue
    /// watermark. Zero-copy: decoder output is IOSurface-backed
    /// (`decodedOutputSettings`), so the caller can hand the surface
    /// straight to `CALayer.contents`.
    func presentingImageBuffer() -> CVPixelBuffer? {
        // Deliberately NOT queue.sync: the presenter polls this at
        // vsync, and syncing onto the renderer queue made every poll
        // wait out whole decode batches (2026-07-24 profile). The ring
        // read is lock-guarded inside the coordinator.
        transition.presentingSample().flatMap { CMSampleBufferGetImageBuffer($0) }
    }

    /// Capture a CGImage of the current playback frame for snapshot
    /// use (cold-start prime, picker snapshot reply).
    /// Cheap capture of the newest decoded frame (mirror read +
    /// CIContext). No AVFoundation reader involved — safe while the pump
    /// is wedged, and the rung the snapshot XPC tries before anything
    /// that could open a decoder session.
    func captureFromLastSample() -> CGImage? {
        guard let recent = published.withLockUnchecked({ $0.lastSample }),
              let pixelBuffer = CMSampleBufferGetImageBuffer(recent) else { return nil }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        return Self.snapshotContext.createCGImage(ci, from: ci.extent)
    }

    func captureCurrentFrame() async -> CGImage? {
        if let cg = captureFromLastSample() { return cg }
        // The poster decode below is a fresh VideoToolbox session. Don't
        // open one while the pump's own decode is stuck — same decoder.
        if let blocked = pumpBlockedSeconds, blocked > PumpWatchdogPolicy.posterSkipAfter {
            return nil
        }
        // Fallback (no frame fed yet): decode a poster frame from the
        // asset at the current position. The timebase runs continuously
        // across gapless loop / next-video boundaries — `ptsOffset`
        // accumulates there without resetting it — so subtract the
        // offset to get the position within the current asset; both come
        // from one mirror read so they're coherent.
        let (offset, currentAsset, extraRotation) = published.withLockUnchecked { ($0.ptsOffset, $0.asset, $0.extraRotation) }
        let captureTime = CMTimeSubtract(CMTimebaseGetTime(timebase), offset)
        let requestTime: CMTime = captureTime.isValid && captureTime.seconds > 0 ? captureTime : .zero
        let generator = AVAssetImageGenerator(asset: currentAsset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        do {
            let result = try await generator.image(at: requestTime)
            // The generator applies the file's own matrix; the user's
            // extra rotation is ours to add, as the composition does.
            guard extraRotation != 0 else { return result.image }
            let oriented = CIImage(cgImage: result.image).oriented(Self.exifOrientation(clockwiseDegrees: extraRotation))
            return Self.snapshotContext.createCGImage(oriented, from: oriented.extent) ?? result.image
        } catch {
            return nil
        }
    }
}

// The renderer abstraction behind every SharedRenderer.
//
// Two engines implement it:
//  - `VideoRenderer` — local files via AVAssetReader + shared CMTimebase
//    (the everyday path: cached aerials, gapless loops, transitions).
//  - `LiveStreamRenderer` — remote HLS live feeds via a headless
//    AVPlayer + AVPlayerItemVideoOutput frame bridge (AVAssetReader
//    cannot stream).
//
// The handler and control listener only ever talk through this
// protocol; creation sites branch on `PlaybackSelection` and keep the
// concrete type just long enough to install their hooks
// (nextVideoProvider / selectNext / onVideoChanged), which stay OFF the
// protocol on purpose — they differ in shape between the engines.

import AVFoundation
import CoreGraphics

/// What the playlist layer picked for a renderer slot. Live entries are
/// detected BEFORE the local-file existence check (their "local path"
/// never exists — that guard is what silently substituted cached clips
/// for live feeds after the AVPlayer engine was removed).
enum PlaybackSelection {
    /// `rotation`: the Library's extra rotation for this video (degrees,
    /// clockwise, 0 when none) — applied on top of the file's metadata.
    case file(url: URL, resumeAt: Double?, rotation: Int)
    case live(url: URL, videoId: String, name: String, playSeconds: Double)
}

protocol PlaybackRenderer: AnyObject {
    // Subscribers
    func addSubscriber(_ layer: AVSampleBufferDisplayLayer)
    func removeSubscriber(_ layer: AVSampleBufferDisplayLayer)
    /// Diagnostics: does this renderer currently feed `layer`? Used by
    /// the topology dump's stale-layer detector to catch a window whose
    /// hosted layer is fed by a renderer other than the window's key
    /// (re-key leftovers), or by nobody at all.
    func feedsLayer(_ layer: AVSampleBufferDisplayLayer) -> Bool
    var subscriberCount: Int { get }

    // Lifecycle (start is creation-site-only, off-protocol)
    func stop()

    // Pause-reason model
    func pause(reason: PauseReasons)
    func resume(reason: PauseReasons)
    func syncCompanionPauseReasons(user: Bool, battery: Bool, coverage: Bool, thermal: Bool, camera: Bool)
    func applyActivityPolicy(paused: Bool, animated: Bool)

    // Saver / lock modes
    func enterScreensaverMode()
    func exitScreensaverMode()
    func setScreensaverModeFromNotification(_ active: Bool)
    func enterLockedMode()
    func exitLockedMode()
    func beginScreensaverExitRamp()
    func cancelScreensaverExitRamp()

    // Live config
    func setNominalRate(_ rate: Double)
    func setTransitionConfig(_ config: TransitionConfig)
    /// Play the video's own audio track. `enabled` arrives with the
    /// audio-owner policy already folded in (exactly one renderer gets
    /// true); the engine still gates on its own state (rate 1.0, not
    /// paused, not locked).
    func setAudio(enabled: Bool, volume: Double)

    // Navigation
    func advanceNow()
    func regressNow()
    func jumpNow()

    // Recovery
    /// Wake recovery: flush + re-prime + re-register EVERY subscriber.
    /// Targets the wake-stall shape (2026-07-06): a display's hosted
    /// surface stops compositing across system sleep while its layer
    /// reports healthy (`status != .failed`, no flush required), so the
    /// per-layer detectors never fire. Called on
    /// `handleNotification(com.apple.wallpaper.hostDidWake)`.
    func recoverAllLayers(reason: String)

    // Variant D contents-swap: the pixel buffer of the frame that
    // should be ON SCREEN right now (nil when nothing is presentable
    // yet). File engine answers from the presenting ring's timebase
    // pick; live engine answers with its latest bridged frame.
    func presentingImageBuffer() -> CVPixelBuffer?

    // Status / diagnostics
    var currentAssetURL: URL { get }
    var currentContentPosition: Double { get }
    /// Live feeds report their name/id directly — their asset path is a
    /// stream URL whose last component (`index.m3u8`) would mis-map in
    /// the filename-based lookup. Nil = use the path-based mapping.
    var nowPlayingOverride: (name: String, id: String)? { get }
    func statusSnapshot() -> VideoRenderer.StatusSnapshot
    func diagnosticsSnapshot() -> String
    func checkFeedHealth()
    func captureCurrentFrame() async -> CGImage?
}

extension PlaybackRenderer {
    /// Default no-op so future engines without an audio path still
    /// conform; both current engines implement the real thing.
    func setAudio(enabled: Bool, volume: Double) {}
}

extension VideoRenderer: PlaybackRenderer {
    var nowPlayingOverride: (name: String, id: String)? { nil }
}

// Module-level state for the wallpaper XPC handler.
//
// Active CAContexts (keyed by wallpaperID UUID) and their shared
// renderers live here, OUTSIDE the handler instance, so they survive
// the rapid XPC disconnect/reconnect cycle WallpaperAgent runs us
// through — per-instance state would be wiped on every reconnect,
// leaving stale contextIds on the agent side and gray screens when ARC
// then drops the underlying CAContext. Split out of
// WallpaperXPCHandler.swift (2026-07-07), verbatim.

import AppKit
import AVFoundation
import Foundation
import os
import QuartzCore

/// Typed bag of everything we read off a `WallpaperCreationRequestXPC`
/// or `WallpaperUpdateRequestXPC`. Fields that don't exist on the
/// update path (`isPreview`, `cacheDirectory`, `placement`,
/// `hasFallbackColor`) stay at their defaults.
struct RequestContext {
    var presentationMode: String = "?"
    var activityState: String = "?"
    var systemAppearance: String = "?"
    var isPreview: Bool = false
    var cacheDirectory: URL?
    /// Picker-side placement choice (e.g. "Crop", "Fill"). Only present
    /// on acquire requests for the wallpaper choice (not screensaver).
    var placement: String?
    /// True when the descriptor carries a non-nil fallback color choice.
    /// We don't extract the CGColor itself — Mirror traversal of
    /// CGColor through several private wrapper structs isn't worth it.
    var hasFallbackColor: Bool = false
}
/// Sentinel key for the single "broadcast" SharedRenderer used by
/// cloned/spanned viewing modes. Per-display renderers are keyed by the
/// screen's stable UUID string (CGDisplayCreateUUIDFromDisplayID) — NOT
/// by CGDirectDisplayID, which macOS re-assigns across sleep/wake and
/// re-enumeration (field logs show the same physical screen cycling
/// IDs 3 → 11 → 8 in a day, leaving stale-keyed renderers decoding
/// while new acquires cold-created duplicates).
let broadcastRendererKey = "broadcast"
/// Compact key for log lines (UUIDs are long; the prefix identifies).
func shortKey(_ key: String) -> String {
    key == broadcastRendererKey ? key : String(key.prefix(8))
}
/// Process-wide monotonically-increasing sequence number so we can
/// correlate acquire -> update -> invalidate for a single wallpaper
/// across the log.
private let globalSeq = OSAllocatedUnfairLock<UInt64>(initialState: 0)
func nextSeq() -> UInt64 {
    globalSeq.withLock { current in
        current &+= 1
        return current
    }
}
/// Per-context retained state. We hold the CAContext AND the root
/// CALayer — letting either go severs WindowServer's view of the
/// remote layer tree and grays the screen out.
///
/// Each acquire now owns its own `displayLayer` (the
/// AVSampleBufferDisplayLayer parented under rootLayer). It's a
/// *subscriber* of either a per-displayID `SharedRenderer` (independent
/// mode) or the singleton broadcast SharedRenderer (cloned/spanned).
/// On invalidate we removeSubscriber + release refCount.
final class ActiveWallpaper: @unchecked Sendable {
    let caContext: AnyObject          // CAContext (private class)
    let rootLayer: CALayer
    // Mutable: update() refreshes it when the agent reports a new
    // directDisplayID for this wallpaper (display re-enumeration) so
    // spanned-frame, snapshot and overlay lookups stay current.
    var displayID: UInt32?
    // Screen UUID for independent, broadcastRendererKey otherwise.
    // Mutable: reconfigureAllWallpapers / rekeyWallpaper re-key live
    // wallpapers when the viewing mode changes or the wallpaper moves
    // to a different physical screen (the agent never re-acquires for
    // our settings).
    var rendererKey: String
    var displayLayer: AVSampleBufferDisplayLayer?

    /// Optional overlay driver for this acquire. Nil if the user
    /// hasn't opted in to wallpaper overlays (no separate-desktop
    /// config / no layout for this screen).
    var overlayDriver: OverlayRenderingDriver?

    /// Last presentationMode the agent told us. Used to detect lock
    /// transitions and decide whether to ramp the policy change.
    var lastPresentationMode: String = "default"

    /// Last activityState the agent told us. Used to detect the
    /// transition TO `suspended` (display sleep — typically the last
    /// signal this process sees before full system sleep) so the
    /// visible frame is persisted for the wake-side cold prime.
    var lastActivityState: String = "active"

    /// Last systemAppearance the agent told us. Compared on update()
    /// so we only push to the overlay driver on real changes.
    var lastSystemAppearance: String = "?"

    /// Last placement value from the picker's `optionValues`. Only set
    /// on the wallpaper acquire (screensaver acquires carry empty
    /// optionValues). Not used for rendering today — stashed so a
    /// future tweak ("honour macOS placement for the wallpaper") is a
    /// one-line change.
    var lastPlacement: String?

    /// Last destination tuple the agent told us. Update requests carry
    /// destination too; if size/scaleFactor/displayID changes between
    /// updates without an invalidate, we re-layout the displayLayer.
    var lastDestination: (size: CGSize, scaleFactor: CGFloat, displayID: UInt32?) = (.zero, 1.0, nil)

    /// Acquire sequence number of this instance — cross-references the
    /// `=== ACQUIRE === seq=N` log line and is printed on the diagnostic
    /// badge so tester photos map straight back to the log.
    var acquireSeq: UInt64 = 0

    /// Wall-clock of this window's acquire. The churn eviction's age
    /// guard reads it (a window younger than the guard can't be evicted
    /// — it may be part of the same engage burst as the new acquire).
    let acquiredAt = CFAbsoluteTimeGetCurrent()

    /// Diagnostic badge currently attached to rootLayer (nil when the
    /// setting is off). Rebuilt on settings reconcile.
    var debugBadge: DebugBadgeLayer?

    /// Compositor-mapping variant this window was built with: "D"
    /// contents-swap (production default) or "A" plain AVSBDL (the
    /// EDR/HDR path, auto-selected for HDR formats; also the badges-on
    /// "HDR compatible" manual override). Printed on the badge chip so
    /// tester photos attribute the construction.
    var experimentVariant: String = "D"

    /// True when this acquire was invoked as the screen saver (mode=idle
    /// + empty optionValues at acquire time). Drives:
    ///   - the renderer's screensaver-mode rate override (always 1.0×)
    ///   - the overlay driver's `isDesktop:` routing (so screensaver
    ///     content uses the screensaver overlay layout, not the
    ///     desktop one)
    ///   - the `userPaused` bypass already wired into `acquire()`
    var isScreenSaver: Bool = false

    /// True when the acquire carried `preview=true` — a System Settings
    /// preview window, not a real desktop/saver presentation. Load-
    /// bearing: excludes the window from the saver classification at
    /// acquire and from the global saver-mode fallback in `update()`
    /// (a preview shares the desktop's renderer and must not drag it
    /// into 1.0×/pause-bypass saver mode). Also diagnostics attribution
    /// (🗺/📐 `preview=`, badge role "P").
    var isPreview: Bool = false

    /// Variant D (contents-swap, the default): the plain CALayer that
    /// displays video via `contents` IOSurface swaps. The AVSBDL
    /// `displayLayer` still exists and is still subscribed — it drives
    /// the renderer's pump/pacing — but is NOT in the layer tree, so the
    /// serialized context contains no video-surface node for
    /// WallpaperAgent to special-case.
    var contentsSwapLayer: CALayer?

    /// Variant D: the 30 Hz presenter mirroring the renderer's
    /// presenting frame into `contentsSwapLayer`. Stopped at invalidate.
    var contentsSwapPresenter: ContentsSwapPresenter?

    /// The colour-cycling "No videos found" layer, present only while
    /// this window has nothing playable. Its presence is also the
    /// "retry attaching me" marker for `retryAttachForUnfedWindows`.
    var noVideoFallback: NoVideoFallbackLayer?

    init(
        caContext: AnyObject,
        rootLayer: CALayer,
        displayID: UInt32?,
        rendererKey: String,
        displayLayer: AVSampleBufferDisplayLayer? = nil,
        overlayDriver: OverlayRenderingDriver? = nil
    ) {
        self.caContext = caContext
        self.rootLayer = rootLayer
        self.displayID = displayID
        self.rendererKey = rendererKey
        self.displayLayer = displayLayer
        self.overlayDriver = overlayDriver
    }
}

/// One video pipeline shared across N subscribers. In independent
/// mode there's one of these per displayID, each with subscribers from
/// multiple Spaces of that display. In cloned/spanned mode there's a
/// single broadcast SharedRenderer keyed by `broadcastRendererKey`,
/// with subscribers from every acquire on every display — all sharing
/// one decoder and one CMTimebase for frame-sync.
///
/// `refCount` tracks the number of attached subscribers (= active
/// acquires bound to this renderer). When it hits zero a teardown
/// timer fires after a 30s grace period so quick Space switches that
/// drop + reacquire don't churn the decoder.
final class SharedRenderer: @unchecked Sendable {
    let rendererKey: String  // screen UUID OR broadcastRendererKey
    let videoURL: URL
    /// Either engine behind the protocol: `VideoRenderer` for local
    /// files, `LiveStreamRenderer` for live feeds.
    let renderer: any PlaybackRenderer
    var refCount: Int = 0
    var teardownTimer: DispatchSourceTimer?

    init(rendererKey: String, videoURL: URL, renderer: any PlaybackRenderer) {
        self.rendererKey = rendererKey
        self.videoURL = videoURL
        self.renderer = renderer
    }
}

/// Module-level state — survives XPC reconnects. WallpaperAgent drops
/// and re-establishes the XPC connection every few seconds; a fresh
/// `WallpaperXPCHandler` is built each time but this dict lives on,
/// keeping the CAContexts alive across handler churn. Exposed (not
/// private) so `WallpaperControlListener` can read the active
/// SharedRenderers via `allRenderers()`.
final class HandlerState: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [String: ActiveWallpaper] = [:]                  // wallpaperID → state
    private var renderers: [String: SharedRenderer] = [:]                  // rendererKey → SharedRenderer
    private var loginShieldVisible = false                                 // password/login UI up (distributed notif)
    private var notificationScreensaverActive = false                      // saver running per fallback detector (notif / update-idle)

    // MARK: Login shield

    /// The system login/password UI is showing. Set by the
    /// `com.apple.screenLockUIIsShown/Hidden` distributed-notification
    /// observer — the reliable cross-context signal (the agent's
    /// `presentationMode == locked` doesn't reach a running saver's wid).
    func setLoginShieldVisible(_ visible: Bool) {
        lock.lock(); defer { lock.unlock() }
        loginShieldVisible = visible
    }

    var isLoginShieldVisible: Bool {
        lock.lock(); defer { lock.unlock() }
        return loginShieldVisible
    }

    // MARK: Notification screensaver fallback

    /// Whether the FALLBACK detector (distributed notification / update-idle)
    /// believes a screensaver is running — independent of the acquire-driven
    /// per-renderer count. Lets a fresh acquire mid-saver pick the mode up.
    func setNotificationScreensaverActive(_ active: Bool) {
        lock.lock(); defer { lock.unlock() }
        notificationScreensaverActive = active
    }
    var isNotificationScreensaverActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return notificationScreensaverActive
    }

    // MARK: ActiveWallpaper bookkeeping

    func store(wallpaperID: String, wallpaper: ActiveWallpaper) {
        lock.lock(); defer { lock.unlock() }
        contexts[wallpaperID] = wallpaper
    }

    func remove(wallpaperID: String) -> ActiveWallpaper? {
        lock.lock(); defer { lock.unlock() }
        return contexts.removeValue(forKey: wallpaperID)
    }

    func get(wallpaperID: String) -> ActiveWallpaper? {
        lock.lock(); defer { lock.unlock() }
        return contexts[wallpaperID]
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return contexts.count
    }

    // MARK: SharedRenderer bookkeeping (keyed by rendererKey, which is
    // either a real displayID for independent mode or `broadcastRendererKey`
    // for shared modes).

    /// Get the SharedRenderer for a key, incrementing refCount and
    /// canceling any pending teardown. Returns nil if none exists yet.
    /// Bind another acquire to a live renderer. `wasIdle`: no acquire was
    /// bound before this one — the renderer sat inside its teardown grace
    /// with zero subscribers and its timebase held at rate 0 (the warm
    /// saver-restart case). Decided under the lock, so a second display
    /// racing in behind this one never sees idle.
    func acquireExistingRenderer(key: String) -> (shared: SharedRenderer, wasIdle: Bool)? {
        lock.lock(); defer { lock.unlock() }
        guard let shared = renderers[key] else { return nil }
        let wasIdle = shared.refCount == 0
        shared.refCount += 1
        shared.teardownTimer?.cancel()
        shared.teardownTimer = nil
        return (shared, wasIdle)
    }

    /// Install a freshly-created SharedRenderer for a key. If another
    /// acquire raced and got there first, return the winner (incremented)
    /// and the caller should stop the loser's renderer to free the
    /// duplicate decoder.
    func installRenderer(key: String, candidate: SharedRenderer) -> (winner: SharedRenderer, lostRace: Bool) {
        lock.lock(); defer { lock.unlock() }
        if let existing = renderers[key] {
            existing.refCount += 1
            existing.teardownTimer?.cancel()
            existing.teardownTimer = nil
            return (existing, true)
        }
        candidate.refCount = 1
        renderers[key] = candidate
        return (candidate, false)
    }

    /// Swap the renderer behind a key IN PLACE (live↔file engine
    /// switch): preserves refCount and cancels any pending teardown so
    /// the acquire bookkeeping is untouched. Returns the old
    /// SharedRenderer for subscriber migration + stop, or nil if the
    /// key vanished (caller stops the candidate).
    func replaceRenderer(key: String, candidate: SharedRenderer) -> SharedRenderer? {
        lock.lock(); defer { lock.unlock() }
        guard let old = renderers[key] else { return nil }
        candidate.refCount = old.refCount
        old.teardownTimer?.cancel()
        old.teardownTimer = nil
        renderers[key] = candidate
        return old
    }

    // MARK: Pending live↔file engine switches (stash-and-defer)

    /// The file engine's provider pops the NEXT playlist entry at the
    /// START of the current video — switching engines on that pop would
    /// cut the current video short. The mismatched selection is stashed
    /// here and the switch fires on the SECOND provider call, exactly
    /// at the loop boundary.
    private var pendingEngineSwitch: [String: PlaybackSelection] = [:]

    func setPendingSwitch(_ selection: PlaybackSelection, key: String) {
        lock.lock(); defer { lock.unlock() }
        pendingEngineSwitch[key] = selection
    }

    func takePendingSwitch(key: String) -> PlaybackSelection? {
        lock.lock(); defer { lock.unlock() }
        return pendingEngineSwitch.removeValue(forKey: key)
    }

    func clearPendingSwitch(key: String) {
        lock.lock(); defer { lock.unlock() }
        pendingEngineSwitch[key] = nil
    }

    /// Decrement the SharedRenderer's refCount for this wallpaperID's
    /// renderer key. If refCount hits zero, schedule teardown after the
    /// grace period.
    func releaseRenderer(forWallpaperID wid: String, gracePeriod: TimeInterval, teardown: @escaping @Sendable (SharedRenderer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let wallpaper = contexts[wid],
              let shared = renderers[wallpaper.rendererKey] else { return }
        shared.refCount -= 1
        if shared.refCount <= 0 {
            scheduleTeardownLocked(shared, gracePeriod: gracePeriod, teardown: teardown)
        }
    }

    /// Decrement a SharedRenderer's refCount directly by key. For paths
    /// where the wallpaper's `rendererKey` has already moved on
    /// (reconfigure re-key, stale async install) and the wid → key
    /// lookup would resolve to the wrong renderer.
    func releaseRenderer(key: String, gracePeriod: TimeInterval, teardown: @escaping @Sendable (SharedRenderer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let shared = renderers[key] else { return }
        shared.refCount -= 1
        if shared.refCount <= 0 {
            scheduleTeardownLocked(shared, gracePeriod: gracePeriod, teardown: teardown)
        }
    }

    private func scheduleTeardownLocked(_ shared: SharedRenderer, gracePeriod: TimeInterval, teardown: @escaping @Sendable (SharedRenderer) -> Void) {
        shared.teardownTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let key = shared.rendererKey
        timer.schedule(deadline: .now() + gracePeriod)
        timer.setEventHandler { [weak self, weak shared] in
            guard let self, let shared else { return }
            self.lock.lock()
            let shouldTeardown = shared.refCount <= 0 && self.renderers[key] === shared
            if shouldTeardown {
                self.renderers.removeValue(forKey: key)
                shared.teardownTimer = nil
            }
            self.lock.unlock()
            if shouldTeardown {
                teardown(shared)
            }
        }
        shared.teardownTimer = timer
        timer.resume()
    }

    /// Look up the SharedRenderer for a wallpaperID. Used by `update`
    /// to apply policy.
    func renderer(forWallpaperID wid: String) -> SharedRenderer? {
        lock.lock(); defer { lock.unlock() }
        guard let wallpaper = contexts[wid] else { return nil }
        return renderers[wallpaper.rendererKey]
    }

    /// Snapshot all active SharedRenderers. Each is internally thread-
    /// safe via its own dispatch queue.
    func allRenderers() -> [SharedRenderer] {
        lock.lock(); defer { lock.unlock() }
        return Array(renderers.values)
    }

    /// Snapshot all active wallpapers (wid → state). Diagnostics only —
    /// consumed by `dumpTopology(reason:)`.
    func allWallpapers() -> [(wid: String, wallpaper: ActiveWallpaper)] {
        lock.lock(); defer { lock.unlock() }
        return contexts.map { ($0.key, $0.value) }
    }
}
/// Module-internal singleton holding all active wallpapers + their
/// SharedRenderers. Survives XPC handler instance churn; exposed
/// (not private) so `WallpaperControlListener` can iterate renderers
/// when reconciling Companion's live-control commands.
let sharedHandlerState = HandlerState()

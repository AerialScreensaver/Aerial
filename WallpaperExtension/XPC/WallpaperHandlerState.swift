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
// MARK: - Handler queue (X4, 2026-10-13)

/// The one serial queue that owns every `ActiveWallpaper` mutation and
/// every window-level operation: attach, teardown, rekey, reconfigure,
/// retry, re-slice/geometry, fallback show/hide, presenter start, badge,
/// `HandlerState.store`/`remove`. The XPC `acquire`/`update`/`invalidate`
/// bodies run `handlerQueue.sync` (which also serialises overlapping agent
/// connections); every other entrant — control listener on main, the
/// periodic/wake retries, renderer-install completions, the engine
/// switch, churn eviction — uses `handlerQueue.async`. `snapshot` never
/// touches it.
///
/// Rules (the deadlock analysis depends on every one of them):
///  1. Never `.sync` onto a renderer queue from the handler queue:
///     `BoundedSync` only, and `renderer.stop()` never runs here (the
///     slow-path lost-race stop stays on the install thread, the engine
///     switch stops on `rendererSwitchQueue`, teardown stops on the grace
///     timer's global queue).
///  2. Renderer callbacks (`nextVideoProvider`, `previousVideoProvider`,
///     `selectNext`, `requestCachedFallback`, `onVideoChanged`, …) never
///     touch the handler queue — they run on renderer queues.
///  3. No `MainActor.run` and no synchronous dispatch onto the main queue
///     from the handler queue; overlay-driver work hops to main with
///     `Task { @MainActor }`.
///  4. Only the XPC handler methods may `handlerQueue.sync`; everyone
///     else `async` (or `onHandlerQueue`, inline when already here).
///  5. `writeWallpaperStatus`, `flushPlaybackProgress`, `dumpTopology`'s
///     body and the diagnostics dumps never run on the handler queue
///     (they `BoundedSync`/`queue.sync` into renderer queues) — route
///     them through `statusWriteQueue` / `extensionDiagnosticsQueue`.
///  6. `IdleExit` is unchanged: it decides under `HandlerState.lock` on
///     the connection's invalidation thread, counting contexts minus the
///     ones `invalidate` has marked (`markInvalidating`), so a teardown
///     still queued behind busy work cannot make the process miss its
///     exit window.
/// Lock order: handler queue → HandlerState.lock → mirror lock → (CA
/// transaction). The handler queue's outgoing edges are leaf locks and
/// `queue.async` calls onto renderers; renderer queues never reach the
/// handler queue; main reaches it by `async` only. No cycle.
///
/// Layer-tree ownership (the mirror protects references and flags, not
/// the layers they point at):
///  - the handler queue owns the root tree's STRUCTURE (sublayer
///    add/remove of the video, swap, badge and fallback layers), its
///    geometry, the root's `contents` (primes) and the blanking at
///    teardown;
///  - the MainActor owns the overlay driver and every CALayer it creates:
///    the overlay sublayer is attached/detached on main
///    (`rebuildOverlayDriver`, acquire's overlay task, teardown's main
///    hop) and `overlayDriver` itself is `@MainActor`;
///  - the contents-swap presenter swaps its leaf layer's `contents` on
///    main; `primeRootLayer`'s read of a sibling window's
///    `contentsSwapLayer.contents` is a CA-locked leaf read and tolerated.
/// Ordering across the two: attach (handler) → driver create/attach
/// (main) → teardown marks and blanks (handler) → driver stop (main,
/// reading the field at run time, not at enqueue).
let handlerQueue: DispatchQueue = {
    let queue = DispatchQueue(label: "aerial-wallpaper-handler", qos: .userInitiated, autoreleaseFrequency: .workItem)
    queue.setSpecific(key: handlerQueueKey, value: true)
    debugLog("🧵 handler queue adopted: aerial-wallpaper-handler (userInitiated) — ActiveWallpaper mutations confined here")
    return queue
}()
private let handlerQueueKey = DispatchSpecificKey<Bool>()

/// True on the handler queue (queue-specific key, so a block dispatched
/// onto it from anywhere still answers yes).
var isOnHandlerQueue: Bool {
    DispatchQueue.getSpecific(key: handlerQueueKey) == true
}

/// Debug-only confinement check for the handler-only free functions and
/// `ActiveWallpaper.mutate`. Logs the offender synchronously, then traps:
/// a violation on the tsan-live (Debug) build shows as an unexpected
/// extension respawn, with this line naming the function.
func assertHandlerQueue(_ what: String) {
    #if DEBUG
    guard !isOnHandlerQueue else { return }
    LogBridge.shared.writeSynchronously(
        "💥 handler-queue violation: \(what) ran on \(Thread.current) — see the handlerQueue rules in WallpaperHandlerState.swift",
        osLogType: .fault)
    preconditionFailure("handler-queue violation: \(what)")
    #endif
}

/// Run `body` on the handler queue: inline when already there (keeps the
/// synchronous completion order of the live engine's `makeRenderer`),
/// otherwise `async`.
func onHandlerQueue(_ body: @escaping @Sendable () -> Void) {
    if isOnHandlerQueue {
        body()
    } else {
        handlerQueue.async(execute: body)
    }
}

/// Debug-only, thread-local guard for the HandlerState.lock → mirror lock
/// order: `ActiveWallpaper.mutate` bumps a per-thread depth around its
/// body; `mirror` and every `HandlerState` lock entry assert the depth is
/// zero. A `mutate` body that read `mirror` would deadlock on the
/// non-recursive mirror lock; one that called into `HandlerState` would
/// invert the lock order. Same-thread misuse only — the cross-queue
/// graph is documented above.
enum MutationGuard {
    private static let depthKey = "aerial.wallpaper.mutateDepth"

    private static var depth: Int {
        get { (Thread.current.threadDictionary[depthKey] as? Int) ?? 0 }
        set { Thread.current.threadDictionary[depthKey] = newValue }
    }

    static func enter() {
        #if DEBUG
        depth += 1
        #endif
    }

    static func exit() {
        #if DEBUG
        depth -= 1
        #endif
    }

    static func assertNotInsideMutate(_ what: String) {
        #if DEBUG
        let current = depth
        guard current > 0 else { return }
        LogBridge.shared.writeSynchronously(
            "💥 lock-order violation: \(what) inside an ActiveWallpaper.mutate body (depth \(current)) — mutate bodies are pure value edits",
            osLogType: .fault)
        preconditionFailure("lock-order violation: \(what) inside mutate")
        #endif
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
///
/// Thread model (X4, 2026-10-13). Everything decided at acquire is a
/// `let`. Everything that changes over the window's life lives in one
/// `WindowState` value behind an unfair lock: `mutate` is the only
/// writer and runs on the handler queue (`handlerQueue`, Debug-asserted),
/// `mirror` is the lock-protected copy any thread may read without ever
/// waiting on the queue (snapshot XPC, status writer, diagnostics,
/// overlay pushes). The lock IS the storage, so there is no separate
/// publish step and never a torn read. Convention: handler-queue code
/// reads `mirror` once at the top of a function (or inside its
/// `mutate`); layer work happens outside `mutate` (do the CATransaction,
/// then record the reference). `mutate` bodies are pure value edits —
/// no callbacks, no `HandlerState` calls (lock order is
/// HandlerState.lock → this lock, see `releaseRenderer(forWallpaperID:)`),
/// no `mirror` reads (the lock is not recursive).
final class ActiveWallpaper: @unchecked Sendable {
    let caContext: AnyObject          // CAContext (private class)
    let rootLayer: CALayer
    /// The per-acquire AVSBDL subscriber. Always built — a saver window
    /// the display selection excludes (`WindowState.saverExcluded`) keeps
    /// it OFF the tree and unsubscribed, so a later include (display set
    /// change mid-saver) puts it to work without rebuilding the tree.
    let displayLayer: AVSampleBufferDisplayLayer

    /// Variant D (contents-swap, the default): the plain CALayer that
    /// displays video via `contents` IOSurface swaps. The AVSBDL
    /// `displayLayer` still exists and is still subscribed — it drives
    /// the renderer's pump/pacing — but is NOT in the layer tree, so the
    /// serialized context contains no video-surface node for
    /// WallpaperAgent to special-case.
    let contentsSwapLayer: CALayer?

    /// True when this acquire was invoked as the screen saver (mode=idle
    /// + empty optionValues at acquire time). Drives:
    ///   - the renderer's screensaver-mode rate override (always 1.0×)
    ///   - the overlay driver's `isDesktop:` routing (so screensaver
    ///     content uses the screensaver overlay layout, not the
    ///     desktop one)
    ///   - the `userPaused` bypass already wired into `acquire()`
    let isScreenSaver: Bool

    /// True when the acquire carried `preview=true` — a System Settings
    /// preview window, not a real desktop/saver presentation. Load-
    /// bearing: excludes the window from the saver classification at
    /// acquire and from the global saver-mode fallback in `update()`
    /// (a preview shares the desktop's renderer and must not drag it
    /// into 1.0×/pause-bypass saver mode). Also diagnostics attribution
    /// (🗺/📐 `preview=`, badge role "P").
    let isPreview: Bool

    /// Acquire sequence number of this instance — cross-references the
    /// `=== ACQUIRE === seq=N` log line and is printed on the diagnostic
    /// badge so tester photos map straight back to the log.
    let acquireSeq: UInt64

    /// Wall-clock of this window's acquire. The churn eviction's age
    /// guard reads it (a window younger than the guard can't be evicted
    /// — it may be part of the same engage burst as the new acquire).
    let acquiredAt = CFAbsoluteTimeGetCurrent()

    /// Compositor-mapping variant this window was built with: "D"
    /// contents-swap (production default) or "A" plain AVSBDL (the
    /// EDR/HDR path, auto-selected for HDR formats; also the badges-on
    /// "HDR compatible" manual override). Printed on the badge chip so
    /// tester photos attribute the construction.
    let experimentVariant: String

    /// Optional overlay driver for this acquire. Nil if the user
    /// hasn't opted in to wallpaper overlays (no separate-desktop
    /// config / no layout for this screen). MainActor-isolated: the
    /// driver and its layers live on main, every writer
    /// (`rebuildOverlayDriver`, acquire's overlay task, teardown's main
    /// hop) already ran there and relied on that serialisation for its
    /// check-then-act; off-main code reads `mirror.hasOverlay` instead.
    @MainActor var overlayDriver: OverlayRenderingDriver?

    /// The mutable half of the window, published through `mirror`.
    struct WindowState {
        /// Refreshed by update() when the agent reports a new
        /// directDisplayID for this wallpaper (display re-enumeration) so
        /// spanned-frame, snapshot and overlay lookups stay current.
        var displayID: UInt32?

        /// Screensaver windows only: the display UUIDs this saver session
        /// plays on ("Screensaver plays videos on"), nil for desktop and
        /// preview windows. Feeds the saver's spanned canvas — the
        /// wallpaper's canvas always covers every display. Refreshed by
        /// `reevaluateSaverDisplays` when the display set changes.
        var saverPlayingDisplays: Set<String>?

        /// This saver window sits on a display the selection excludes: the
        /// window is solid black, its video layers are off the tree, it
        /// holds no renderer, presenter or overlay, and every feed path
        /// (attach, reconfigure, re-slice, retry, dest-move, engine switch)
        /// skips it. Decided at acquire and flipped live by
        /// `excludeSaverWindow` / `includeSaverWindow` when a display is
        /// plugged in mid-saver (an unplug ends the session instead —
        /// 2026-10-15 probes). A flip bumps `generation`.
        var saverExcluded = false

        /// "Use overlays from": the display UUID whose per-screen overlay
        /// layout this saver window borrows while the single-display
        /// override is what keeps it playing; nil = its own display. Read
        /// by every overlay driver creation (acquire, rebuild); refreshed
        /// by `reevaluateSaverDisplays`. No generation bump — an overlay
        /// source change never invalidates an in-flight renderer install.
        var saverOverlayScreenUUID: String?

        /// Screen UUID for independent, broadcastRendererKey otherwise.
        /// reconfigureAllWallpapers / rekeyWallpaper re-key live wallpapers
        /// when the viewing mode changes or the wallpaper moves to a
        /// different physical screen (the agent never re-acquires for our
        /// settings).
        var rendererKey: String

        /// The renderer key this window currently holds a `refCount` and a
        /// layer subscription on. Nil while parked on the no-video fallback
        /// or before an install completes. `attachWallpaper` is re-run by
        /// the periodic retry and wake; without this marker each re-run took
        /// another ref and subscription (decoder never torn down, saver rate
        /// pinned), and teardown released refs that fallback-parked windows
        /// never held.
        var attachedRendererKey: String?

        /// Last presentationMode the agent told us. Used to detect lock
        /// transitions and decide whether to ramp the policy change.
        var lastPresentationMode: String

        /// Last activityState the agent told us (seeded from the acquire
        /// request). Used to detect the transition TO `suspended` (display
        /// sleep — typically the last signal this process sees before full
        /// system sleep) so the visible frame is persisted for the
        /// wake-side cold prime, and re-read by the slow-path attach
        /// completion so a suspend that landed while the decoder loaded is
        /// honoured.
        var lastActivityState: String

        /// `lastActivityState` through the handler's activity rule
        /// (`activitySuspended(_:)`), for call sites where a parameter of
        /// that name shadows the free function.
        var isActivitySuspended: Bool { activitySuspended(lastActivityState) }

        /// Last systemAppearance the agent told us. Compared on update()
        /// so we only push to the overlay driver on real changes.
        var lastSystemAppearance: String

        /// Last destination tuple the agent told us. Update requests carry
        /// destination too; if size/scaleFactor/displayID changes between
        /// updates without an invalidate, we re-layout the displayLayer.
        var lastDestination: (size: CGSize, scaleFactor: CGFloat, displayID: UInt32?)

        /// Diagnostic badge currently attached to rootLayer (nil when the
        /// setting is off). Rebuilt on settings reconcile.
        var debugBadge: DebugBadgeLayer?

        /// Variant D: the 30 Hz presenter mirroring the renderer's
        /// presenting frame into `contentsSwapLayer`. Stopped at invalidate.
        var contentsSwapPresenter: ContentsSwapPresenter?

        /// The colour-cycling "No videos found" layer, present only while
        /// this window has nothing playable. Its presence is also the
        /// "retry attaching me" marker for `retryAttachForUnfedWindows`.
        var noVideoFallback: NoVideoFallbackLayer?

        /// The "Menu bar background" band, present only while
        /// `MenuBarBackgroundController` decides this window shows it.
        var menuBarBand: MenuBarBackgroundLayer?

        /// Diagnostics echo of `overlayDriver != nil`. Lags the MainActor
        /// field by one handler-queue hop; never a decision input.
        var hasOverlay = false

        /// Bumped by `mutate` whenever `rendererKey`, `displayID`,
        /// `lastDestination` or `saverExcluded` changes, and by teardown. Asynchronous
        /// continuations (slow-path install, defensive prime, overlay
        /// create) capture it and re-validate on the handler queue before
        /// applying their result, so a configuration that went A → B → A
        /// while they ran is rejected where a key-equality check would
        /// pass.
        var generation: UInt64 = 0
    }

    /// The queue-confined storage (`QueueConfined`, Support/): writes on
    /// `handlerQueue`, reads through the lock from anywhere.
    private let published: QueueConfined<WindowState>

    /// Lock-protected copy of the mutable state. Any thread, never blocks
    /// on the handler queue. One read per observation: compare fields
    /// from the same copy, not from two calls.
    var mirror: WindowState {
        MutationGuard.assertNotInsideMutate("ActiveWallpaper.mirror")
        return published.mirror
    }

    /// The only writer. Handler queue only (Debug-asserted here with a
    /// log line, and again by the primitive's precondition); the body is a
    /// pure value edit — no callbacks, no `HandlerState` calls, no `mirror`
    /// reads. Returns whatever the body returns so a caller can take a
    /// reference out (presenter to stop, badge to remove) and act on it
    /// AFTER the lock is released.
    @discardableResult
    func mutate<T>(_ body: (inout WindowState) -> T) -> T {
        assertHandlerQueue("ActiveWallpaper.mutate")
        MutationGuard.enter()
        defer { MutationGuard.exit() }
        return published.mutate { state in
            let before = (state.rendererKey, state.displayID, state.lastDestination, state.saverExcluded)
            let result = body(&state)
            if before.0 != state.rendererKey || before.1 != state.displayID
                || before.2.size != state.lastDestination.size
                || before.2.scaleFactor != state.lastDestination.scaleFactor
                || before.2.displayID != state.lastDestination.displayID
                || before.3 != state.saverExcluded {
                state.generation &+= 1
            }
            return result
        }
    }

    init(
        caContext: AnyObject,
        rootLayer: CALayer,
        displayLayer: AVSampleBufferDisplayLayer,
        contentsSwapLayer: CALayer?,
        displayID: UInt32?,
        rendererKey: String,
        destination: (size: CGSize, scaleFactor: CGFloat, displayID: UInt32?),
        presentationMode: String,
        activityState: String,
        systemAppearance: String,
        isScreenSaver: Bool,
        isPreview: Bool,
        acquireSeq: UInt64,
        experimentVariant: String,
        saverPlayingDisplays: Set<String>?,
        saverExcluded: Bool,
        saverOverlayScreenUUID: String? = nil
    ) {
        self.caContext = caContext
        self.rootLayer = rootLayer
        self.displayLayer = displayLayer
        self.contentsSwapLayer = contentsSwapLayer
        self.isScreenSaver = isScreenSaver
        self.isPreview = isPreview
        self.acquireSeq = acquireSeq
        self.experimentVariant = experimentVariant
        self.published = QueueConfined(owner: handlerQueue, initialState: WindowState(
            displayID: displayID,
            saverPlayingDisplays: saverPlayingDisplays,
            saverExcluded: saverExcluded,
            saverOverlayScreenUUID: saverOverlayScreenUUID,
            rendererKey: rendererKey,
            lastPresentationMode: presentationMode,
            lastActivityState: activityState,
            lastSystemAppearance: systemAppearance,
            lastDestination: destination
        ))
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
    private var invalidating: Set<String> = []                             // wids whose invalidate is in flight (see markInvalidating)
    private var loginShieldVisible = false                                 // password/login UI up (distributed notif)
    private var notificationScreensaverActive = false                      // saver running per fallback detector (notif / update-idle)

    /// Every lock entry goes through here: the Debug lock-order guard
    /// (`MutationGuard`) refuses to take this lock from inside an
    /// `ActiveWallpaper.mutate` body. Pair with `lock.unlock()`.
    private func lockChecked() {
        MutationGuard.assertNotInsideMutate("HandlerState.lock")
        lock.lock()
    }

    // MARK: Login shield

    /// The system login/password UI is showing. Set by the
    /// `com.apple.screenLockUIIsShown/Hidden` distributed-notification
    /// observer — the reliable cross-context signal (the agent's
    /// `presentationMode == locked` doesn't reach a running saver's wid).
    func setLoginShieldVisible(_ visible: Bool) {
        lockChecked(); defer { lock.unlock() }
        loginShieldVisible = visible
    }

    var isLoginShieldVisible: Bool {
        lockChecked(); defer { lock.unlock() }
        return loginShieldVisible
    }

    // MARK: Notification screensaver fallback

    /// Whether the FALLBACK detector (distributed notification / update-idle)
    /// believes a screensaver is running — independent of the acquire-driven
    /// per-renderer count. Lets a fresh acquire mid-saver pick the mode up.
    /// Compare-and-set: returns true when the flag actually changed, so two
    /// callers racing in (the distributed observer on main and an
    /// acquire/update on the handler queue) cannot both act on the same
    /// transition.
    @discardableResult
    func setNotificationScreensaverActive(_ active: Bool) -> Bool {
        lockChecked(); defer { lock.unlock() }
        guard notificationScreensaverActive != active else { return false }
        notificationScreensaverActive = active
        return true
    }
    var isNotificationScreensaverActive: Bool {
        lockChecked(); defer { lock.unlock() }
        return notificationScreensaverActive
    }

    // MARK: ActiveWallpaper bookkeeping

    /// Handler queue only: `acquire` parks the window here before it replies.
    func store(wallpaperID: String, wallpaper: ActiveWallpaper) {
        assertHandlerQueue("HandlerState.store")
        lockChecked(); defer { lock.unlock() }
        contexts[wallpaperID] = wallpaper
    }

    /// Handler queue only: the last step of `teardownWallpaperWindow`.
    /// Also clears the `markInvalidating` mark, if any.
    func remove(wallpaperID: String) -> ActiveWallpaper? {
        assertHandlerQueue("HandlerState.remove")
        lockChecked(); defer { lock.unlock() }
        invalidating.remove(wallpaperID)
        return contexts.removeValue(forKey: wallpaperID)
    }

    /// Called by `invalidate` on the XPC thread BEFORE it enters the
    /// handler queue: the teardown may wait behind queued work, and the
    /// agent's disconnect (→ `exitProcessIfIdle`) can land in that gap.
    /// A marked window no longer counts as hosted for the idle-exit
    /// decision, while it stays in `contexts` until its teardown runs so
    /// queued operations keep seeing consistent membership. Only marks a
    /// window that exists (an unknown wid has nothing to tear down).
    func markInvalidating(wallpaperID: String) {
        lockChecked(); defer { lock.unlock() }
        if contexts[wallpaperID] != nil {
            invalidating.insert(wallpaperID)
        }
    }

    func get(wallpaperID: String) -> ActiveWallpaper? {
        lockChecked(); defer { lock.unlock() }
        return contexts[wallpaperID]
    }

    var count: Int {
        lockChecked(); defer { lock.unlock() }
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
    func acquireExistingRenderer(key: String) -> (shared: SharedRenderer, wasIdle: Bool, refCount: Int)? {
        lockChecked(); defer { lock.unlock() }
        guard let shared = renderers[key] else { return nil }
        let wasIdle = shared.refCount == 0
        shared.refCount += 1
        shared.teardownTimer?.cancel()
        shared.teardownTimer = nil
        // `refCount` is returned for the caller's log line: reading the
        // field after the lock is released races the install completions.
        return (shared, wasIdle, shared.refCount)
    }

    /// Install a freshly-created SharedRenderer for a key. If another
    /// acquire raced and got there first, return the winner (incremented)
    /// and the caller should stop the loser's renderer to free the
    /// duplicate decoder.
    func installRenderer(key: String, candidate: SharedRenderer) -> (winner: SharedRenderer, lostRace: Bool) {
        lockChecked(); defer { lock.unlock() }
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
        lockChecked(); defer { lock.unlock() }
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
        lockChecked(); defer { lock.unlock() }
        pendingEngineSwitch[key] = selection
    }

    func takePendingSwitch(key: String) -> PlaybackSelection? {
        lockChecked(); defer { lock.unlock() }
        return pendingEngineSwitch.removeValue(forKey: key)
    }

    func clearPendingSwitch(key: String) {
        lockChecked(); defer { lock.unlock() }
        pendingEngineSwitch[key] = nil
    }

    /// Decrement the SharedRenderer's refCount for this wallpaperID's
    /// renderer key. If refCount hits zero, schedule teardown after the
    /// grace period.
    func releaseRenderer(forWallpaperID wid: String, gracePeriod: TimeInterval, teardown: @escaping @Sendable (SharedRenderer) -> Void) {
        lockChecked(); defer { lock.unlock() }
        // Lock order HandlerState.lock → mirror lock (never the reverse:
        // `mutate` bodies make no HandlerState calls).
        guard let wallpaper = contexts[wid],
              let shared = renderers[wallpaper.mirror.rendererKey] else { return }
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
        lockChecked(); defer { lock.unlock() }
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
            self.lockChecked()
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
        lockChecked(); defer { lock.unlock() }
        guard let wallpaper = contexts[wid] else { return nil }
        return renderers[wallpaper.mirror.rendererKey]
    }

    /// Snapshot all active SharedRenderers. Each is internally thread-
    /// safe via its own dispatch queue. `refCount` is NOT: read it through
    /// `rendererSummaries()`, never off a returned object.
    func allRenderers() -> [SharedRenderer] {
        lockChecked(); defer { lock.unlock() }
        return Array(renderers.values)
    }

    /// Diagnostics snapshot of every renderer with its `refCount` copied
    /// under the lock (the field is written by install/release on the
    /// handler queue and the install completion threads; reading it after
    /// `allRenderers()` returned was the one race the 2026-10-14 TSan-live
    /// window reported).
    func rendererSummaries() -> [(shared: SharedRenderer, refCount: Int)] {
        lockChecked(); defer { lock.unlock() }
        return renderers.values.map { ($0, $0.refCount) }
    }

    /// Debug-only reference audit: every renderer's `refCount` must equal
    /// the number of windows whose `attachedRendererKey` names it (the
    /// `attachedRendererKey` invariants: a retried window takes no second
    /// ref, a fallback-parked window releases none, a rekey or a stale
    /// completion releases exactly the one it took). Both sides are read
    /// under this lock (lock order HandlerState → mirror). A one-shot
    /// mismatch right after an install or a re-key is a window whose
    /// completion is still queued (ref taken, not yet attached); the same
    /// key mismatching across consecutive dumps is the bug.
    func auditReferences(context: String) {
        #if DEBUG
        lockChecked(); defer { lock.unlock() }
        var attached: [String: Int] = [:]
        for wallpaper in contexts.values {
            if let key = wallpaper.mirror.attachedRendererKey {
                attached[key, default: 0] += 1
            }
        }
        for (key, shared) in renderers where shared.refCount != attached[key, default: 0] {
            debugLog("  ⚠️ ref mismatch key=\(shortKey(key)) refCount=\(shared.refCount) attached=\(attached[key, default: 0]) (\(context))")
        }
        for (key, count) in attached where renderers[key] == nil {
            debugLog("  ⚠️ ref mismatch key=\(shortKey(key)) refCount=none attached=\(count) — no renderer behind the key (\(context))")
        }
        #endif
    }

    /// Snapshot all active wallpapers (wid → state). Diagnostics only —
    /// consumed by `dumpTopology(reason:)`.
    func allWallpapers() -> [(wid: String, wallpaper: ActiveWallpaper)] {
        lockChecked(); defer { lock.unlock() }
        return contexts.map { ($0.key, $0.value) }
    }

    // MARK: Idle exit

    /// Decide under the lock and, on `.exit`, end the process WITHOUT
    /// releasing it: `acquire()` parks its ActiveWallpaper before it
    /// replies, so an acquire that has replied is visible in `contexts`
    /// here (→ stay), and one that has not reached `store` yet blocks on
    /// this lock and dies with the process — the agent never receives a
    /// contextId from a process about to vanish. `_exit`, not `exit`: no
    /// atexit handlers or destructors while CoreMedia and dispatch threads
    /// are live (every disk writer in this process is atomic anyway).
    /// Nothing in the critical section re-enters this lock. Returns only
    /// when staying, with the reason. Live renderers do not keep the
    /// process (their grace timer may never have run across a sleep, see
    /// `IdleExitRule`); a grace timer firing now blocks on this lock and
    /// dies with us. `desktopWallpaperActive` is logged for triage only
    /// (a hosted desktop wallpaper never idles).
    func exitProcessIfIdle(desktopWallpaperActive: Bool) -> String {
        lockChecked()
        // A window `invalidate` has marked is on its way out even if its
        // teardown is still queued on the handler queue — count it gone.
        // (A teardown that reaches `remove` after this point blocks on
        // the lock and dies with the process; its disk writes are atomic.)
        let hosted = contexts.count - invalidating.count
        let verdict = IdleExitRule.decide(contexts: hosted, renderers: renderers.count)
        switch verdict {
        case .exit:
            let graceNote = renderers.isEmpty ? "" : " (grace teardown pending, no subscribers — leaving anyway)"
            let invalidatingNote = invalidating.isEmpty ? "" : " invalidating=\(invalidating.count) (teardown still queued)"
            LogBridge.shared.writeSynchronously(
                "🚪 idle exit: agent disconnected, contexts=0\(invalidatingNote) renderers=\(renderers.count)\(graceNote) desktopActive=\(desktopWallpaperActive) — leaving before RunningBoard suspends the process; Metal holds archiveUsage.db/lock.mdb and a suspended extension is killed with 0xDEAD10CC",
                osLogType: .info)
            Darwin._exit(0)
        case .stay(let reason):
            lock.unlock()
            return reason
        }
    }
}
/// Module-internal singleton holding all active wallpapers + their
/// SharedRenderers. Survives XPC handler instance churn; exposed
/// (not private) so `WallpaperControlListener` can iterate renderers
/// when reconciling Companion's live-control commands.
let sharedHandlerState = HandlerState()

// MARK: - Idle exit

/// Runs the "nothing hosted" check when the agent drops the connection —
/// the one moment a voluntary exit is safe, see `IdleExitRule`.
final class IdleExit: @unchecked Sendable {
    /// Synchronous on purpose: RunningBoard suspends ~100 ms after the
    /// disconnect (this handler runs ~1 ms after it), so there is no time
    /// to defer. May not return.
    func onConnectionInvalidated() {
        // Read the control flag BEFORE the HandlerState lock — never nest
        // the two. Triage only; it does not enter the decision.
        let desktopActive = WallpaperControlListener.shared.currentDesktopWallpaperActive
        let stayReason = sharedHandlerState.exitProcessIfIdle(desktopWallpaperActive: desktopActive)
        debugLog("🚪 idle exit skipped (xpc-invalidated): \(stayReason)")
    }
}

let idleExit = IdleExit()

/// Timestamp of the last saver-fallback OFF transition — feeds the reuse
/// beacon in `setNotificationScreensaver`. Written from the distributed
/// observer on main AND from acquire/update on the handler queue, hence
/// the lock (it used to be documented main-only).
let lastSaverStopAt = OSAllocatedUnfairLock<Date?>(initialState: nil)

// MARK: - Debug injectors (X4 lifecycle gates)

/// File-flag injectors for the lifecycle gates, Debug builds in
/// `PrefsAdvanced.debugMode` only — same shape as the renderer's pump
/// stall injector: the file's content is a millisecond count (capped at
/// 60 s), consumed on arm.
///
/// - `/Users/Shared/Aerial/handler-delay-ms`: holds the handler queue at
///   the top of the next `invalidate` critical section. Gate: with it
///   armed, kill WallpaperAgent during a saver stop and confirm the
///   `🚪 idle exit` line still fires (the exit decision reads the
///   `markInvalidating` mark, not the queue).
/// - `/Users/Shared/Aerial/attach-delay-ms`: delays the next slow-path
///   attach completion before it is handed to the handler queue. Gate:
///   invalidate, re-key (viewing-mode flip) or an overlay rebuild during
///   the delay must each log one `rejected stale completion` line and
///   leave the reference audit balanced.
enum HandlerDebugInjectors {
    private static let handlerDelayURL = URL(fileURLWithPath: "/Users/Shared/Aerial/handler-delay-ms")
    private static let attachDelayURL = URL(fileURLWithPath: "/Users/Shared/Aerial/attach-delay-ms")

    private static func consume(_ url: URL) -> Int? {
        #if DEBUG
        guard PrefsAdvanced.debugMode,
              FileManager.default.fileExists(atPath: url.path),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard let ms = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), ms > 0 else { return nil }
        return min(ms, 60_000)
        #else
        return nil
        #endif
    }

    /// Blocks the handler queue for the armed duration. Handler queue only.
    static func holdHandlerQueueIfArmed(at phase: String) {
        guard let ms = consume(handlerDelayURL) else { return }
        assertHandlerQueue("HandlerDebugInjectors.holdHandlerQueueIfArmed")
        debugLog("🧪 handler queue held \(ms) ms at \(phase) — debugMode injector (handler-delay-ms)")
        Thread.sleep(forTimeInterval: Double(ms) / 1000)
        debugLog("🧪 handler queue released after \(ms) ms (\(phase))")
    }

    /// The armed delay for the next slow-path attach completion, or nil.
    static func attachCompletionDelayIfArmed() -> TimeInterval? {
        guard let ms = consume(attachDelayURL) else { return nil }
        debugLog("🧪 attach completion delayed \(ms) ms — debugMode injector (attach-delay-ms)")
        return Double(ms) / 1000
    }
}

// XPC handler — single "Aerial" choice, color picked per displayID.
//
// State (active CAContexts keyed by wallpaperID UUID) lives at module
// level so it survives the rapid XPC disconnect/reconnect cycle the
// WallpaperAgent runs us through. Per-instance state would be wiped
// on every reconnect, leaving stale contextIds on the agent side and
// gray screens when ARC then drops the underlying CAContext.

import AppKit
import AVFoundation
import Foundation
@preconcurrency import IOSurface
import os
import QuartzCore

/// Aerial accent — light mode RGB(0.039, 0.494, 0.549), #0A7E8C.
/// Used as the background under the video (visible at letterbox edges)
/// and as the snapshot fill while we still synthesize snapshots.
private let aerialBlue: CGColor = CGColor(red: 0.039, green: 0.494, blue: 0.549, alpha: 1.0)

/// Safety-net fallback: pick a random `.mov` from the effective cache
/// folder (`Cache.path` — default, custom, or the external-image mount
/// point) if the playlist machinery can't give us anything (cache
/// empty, filters too tight, parse errors). Used only when
/// `videoURLForDisplay` returns nil.
private func pickRandomCachedVideo() -> URL? {
    let cacheDir = URL(fileURLWithPath: Cache.path, isDirectory: true)
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: cacheDir,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    ) else { return nil }

    let movs = contents.filter { $0.pathExtension.lowercased() == "mov" }
    return movs.randomElement()
}


/// Extract the presentation context from a `WallpaperCreationRequestXPC`
/// or `WallpaperUpdateRequestXPC`. Enums (`presentationMode`,
/// `activityState`, `systemAppearance`) are scraped from the inner
/// value's `String(describing:)` since Mirror doesn't expose enum case
/// names. `isPreview` and `cacheDirectory` come through Mirror.
/// `placement` / `hasFallbackColor` come from a substring scan of the
/// descriptor's `optionValues` dump.
///
/// Returns a default-initialized `RequestContext` if the request shape
/// can't be unwrapped — activityState "?" reads as not-suspended, which
/// is the safe (playing) default.
private func extractRequestContext(_ request: Any?) -> RequestContext {
    var ctx = RequestContext()

    guard let reqObj = request as? NSObject else { return ctx }

    let mirror = Mirror(reflecting: reqObj)
    guard let innerValue = mirror.children.first?.value else { return ctx }

    // Mirror walk for the plain-typed props: isPreview (Bool) and
    // cacheDirectory (Optional<URL>) on acquire requests.
    let innerMirror = Mirror(reflecting: innerValue)
    for prop in innerMirror.children {
        switch prop.label {
        case "isPreview":
            if let preview = prop.value as? Bool { ctx.isPreview = preview }
        case "cacheDirectory":
            if let url = prop.value as? URL { ctx.cacheDirectory = url }
        default:
            break
        }
    }

    // String-scrape the enum-valued props. The format is consistent:
    // `<name>: <case>,` or `<name>: <case>)` at the end of the struct.
    let desc = String(describing: innerValue)
    func scrape(_ label: String) -> String? {
        guard let r = desc.range(of: "\(label): ") else { return nil }
        let after = desc[r.upperBound...]
        guard let end = after.range(of: ",") ?? after.range(of: ")") else { return nil }
        return String(after[..<end.lowerBound])
    }
    if let mode = scrape("presentationMode") { ctx.presentationMode = mode }
    if let activity = scrape("activityState") { ctx.activityState = activity }
    if let appearance = scrape("systemAppearance") { ctx.systemAppearance = appearance }

    // Picker placement: `"placement": ...PickerValue(id: "Crop")`. Look
    // for the inner `id: "..."` after the placement marker. Robust to
    // intermediate framework class names that change across macOS
    // versions.
    if let placementRange = desc.range(of: "\"placement\":") {
        let after = desc[placementRange.upperBound...]
        if let idRange = after.range(of: "id: \"") {
            let afterId = after[idRange.upperBound...]
            if let endQuote = afterId.firstIndex(of: "\"") {
                ctx.placement = String(afterId[..<endQuote])
            }
        }
    }
    // Fallback color presence: `"color": ...Kind.color(`.
    ctx.hasFallbackColor = desc.range(of: "\"color\":") != nil

    return ctx
}

/// Extract the `WallpaperDestination` fields from a request via Mirror.
/// Works for both `WallpaperCreationRequestXPC` (acquire) and
/// `WallpaperUpdateRequestXPC` (update) — the struct shape is the same.
/// Returns nil if the destination prop isn't found.
private func extractDestination(_ request: Any?) -> (size: CGSize, scaleFactor: CGFloat, displayID: UInt32?)? {
    guard let reqObj = request as? NSObject else { return nil }
    let mirror = Mirror(reflecting: reqObj)
    guard let innerValue = mirror.children.first?.value else { return nil }
    let innerMirror = Mirror(reflecting: innerValue)
    for prop in innerMirror.children where prop.label == "destination" {
        let destMirror = Mirror(reflecting: prop.value)
        var size = CGSize.zero
        var scale: CGFloat = 1.0
        var did: UInt32?
        for destProp in destMirror.children {
            switch destProp.label {
            case "size": if let s = destProp.value as? CGSize { size = s }
            case "scaleFactor": if let sf = destProp.value as? CGFloat { scale = sf }
            case "directDisplayID": if let d = destProp.value as? UInt32 { did = d }
            default: break
            }
        }
        return (size, scale, did)
    }
    return nil
}

/// Compute the screenUUID string the playlist code keys by, from the
/// directDisplayID we get in the acquire request.
private func screenUUID(for directDisplayID: UInt32?) -> String? {
    guard let did = directDisplayID,
          let cfUUID = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue() else {
        return nil
    }
    return CFUUIDCreateString(nil, cfUUID) as String
}

/// Pick the next video URL via the existing playlist machinery.
///
/// `playlistScreenUUID` is the value passed to ExtensionVideoLoader's
/// `getNextVideo(screenUUID:)`. In independent mode it's the per-display
/// UUID — playlist code returns the per-screen playlist. In shared
/// modes (cloned/spanned) we pass nil so it returns `sharedPlaylist`,
/// the same content for every display.
///
/// Falls back to `pickRandomCachedVideo()` if the playlist can't
/// produce anything so the wallpaper still has *something* to show.
private func selectPlayback(screenUUID playlistScreenUUID: String?) -> PlaybackSelection? {
    // result.shouldLoop is unused: a single-entry playlist hands the file
    // engine the same URL again, which is already a gapless loop.
    // result.playDuration rides in the selection — the file engine loops
    // the clip until that much playtime has elapsed (bounded looping).
    // result.resumeTimestamp IS used: it's non-nil only on the first pop
    // after a playlist cache load — exactly the cold-start/respawn case
    // where the renderer should resume at the persisted position.
    let result = ExtensionVideoLoader.shared.getNextVideo(
        isVertical: false, screenUUID: playlistScreenUUID
    )
    if let video = result.video {
        if let selection = playbackSelection(for: video, resumeAt: result.resumeTimestamp,
                                             playDuration: result.playDuration) {
            debugLog("  selectPlayback(uuid=\(playlistScreenUUID?.prefix(8) ?? "nil-shared")) → \(video.isLive ? "LIVE" : "playlist"): \(video.secondaryName)\(result.resumeTimestamp.map { String(format: ", resumeAt=%.1fs", $0) } ?? "")")
            return selection
        }
        debugLog("⚠️ selectPlayback: \(video.secondaryName) has no local file — substituting a cached video")
    }
    if let fallback = pickRandomCachedVideo() {
        debugLog("  selectPlayback(uuid=\(playlistScreenUUID?.prefix(8) ?? "nil-shared")) → fallback: \(fallback.lastPathComponent)")
        return .file(url: fallback, resumeAt: nil, rotation: rotationOverride(for: fallback), playDuration: nil)
    }
    return nil
}

/// Map a playlist pick to the engine-facing selection. Live entries are
/// detected BEFORE the file-existence check — their "local path" never
/// exists on disk (that guard is what silently substituted cached clips
/// for live feeds after the AVPlayer engine was removed).
private func playbackSelection(for video: AerialVideo, resumeAt: Double?,
                               playDuration: Double? = nil) -> PlaybackSelection? {
    if video.isLive {
        return .live(
            url: video.url,
            videoId: video.id,
            name: video.secondaryName,
            playSeconds: video.livePlaybackSeconds
        )
    }
    let path = ExtensionVideoLoader.shared.localPathFor(video: video)
    // isReadableFile, not fileExists: the sandbox lets this process STAT
    // a file on /Volumes but never read it, and the file engine would
    // fail on it. Same rule as VideoCache.isAvailableOffline.
    guard !path.isEmpty, FileManager.default.isReadableFile(atPath: path) else { return nil }
    return .file(url: URL(fileURLWithPath: path), resumeAt: resumeAt,
                 rotation: PrefsVideos.rotationOverride[video.id] ?? 0, playDuration: playDuration)
}

/// The Library's extra rotation for the video whose local file is `url`
/// (degrees, clockwise; 0 when none). The renderer hooks only carry
/// URLs, so this maps back through the catalog — skipped entirely while
/// no override exists, which is nearly always.
private func rotationOverride(for url: URL) -> Int {
    let overrides = PrefsVideos.rotationOverride
    guard !overrides.isEmpty else { return 0 }
    let path = url.path
    let match = VideoList.instance.videos.first { video in
        !video.isLive && overrides[video.id] != nil
            && ExtensionVideoLoader.shared.localPathFor(video: video) == path
    }
    return match.flatMap { overrides[$0.id] } ?? 0
}


/// Renderer key for a display: its stable screen UUID, with a
/// display-ID-based fallback for the (never observed) case where the
/// UUID can't be derived.
private func makeRendererKey(for displayID: UInt32?, isShared: Bool) -> String {
    if isShared { return broadcastRendererKey }
    return screenUUID(for: displayID) ?? "display-\(displayID ?? 0)"
}

/// Detector for WallpaperAgent window churn (observed on Tahoe 26.5.2,
/// 2026-07 field incident): while idle/locked the agent issues a fresh
/// acquire every ~30 s on alternating displays and abandons the old
/// windows without invalidating them — subscribers, presenters, and
/// window-server windows pile up for hours (22 acquires / 3 invalidates
/// in one evening; 738 desktop-band windows after a week). This only
/// OBSERVES and logs a beacon so field logs self-diagnose; counters
/// track genuine agent requests (re-keys don't route through acquire()).
///
/// Detection keys on the churn's real signature — the SAME display
/// re-acquired repeatedly — not the global acquire count, so it needs
/// no display-count tuning: a legitimate engage acquires each display
/// ONCE whether the setup has 1 or 6 displays, while churn re-acquires
/// one every ~30 s. Previews (System Settings browsing re-acquires the
/// main display freely) are excluded, and the unmatched-invalidates
/// guard keeps rapid engage/exit toggling silent.
private final class WindowChurnDetector: @unchecked Sendable {
    static let shared = WindowChurnDetector()
    private let lock = NSLock()
    private var acquires: [(time: CFAbsoluteTime, did: UInt32?)] = []
    private var invalidates: [CFAbsoluteTime] = []
    private static let window: CFAbsoluteTime = 180

    func noteAcquire(did: UInt32?, isPreview: Bool) {
        guard !isPreview else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        acquires.append((time: now, did: did))
        acquires.removeAll { now - $0.time > Self.window }
        invalidates.removeAll { now - $0 > Self.window }
        let total = acquires.count
        let inv = invalidates.count
        var perDisplay: [UInt32: Int] = [:]
        for entry in acquires {
            if let d = entry.did { perDisplay[d, default: 0] += 1 }
        }
        let worst = perDisplay.values.max() ?? 0
        lock.unlock()
        // 3 acquires of one display inside 3 min, with at least 2 of the
        // window's acquires unmatched by invalidates, is beyond any
        // legitimate sequence (engage = 1 per display; engage/exit/
        // re-engage = 2, and its invalidates cancel the unmatched count).
        if worst >= 3, total - inv >= 2 {
            debugLog("⚠️🌀 [Churn] a display was re-acquired \(worst)× in \(Int(Self.window))s (\(total) acquires vs \(inv) invalidates) — agent window churn suspected (abandoned windows accumulate)")
        }
    }

    func noteInvalidate() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        invalidates.append(now)
        lock.unlock()
    }

    /// Whether `did` currently matches the churn signature (≥3 acquires
    /// of that display inside the window, ≥2 of the window's acquires
    /// unmatched by invalidates). Gates the superseded-window eviction:
    /// eviction only ever engages under detected churn, so legitimate
    /// multi-Space acquires on one display can never trigger it alone.
    func isChurning(did: UInt32?) -> Bool {
        guard let did else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock(); defer { lock.unlock() }
        let recent = acquires.filter { now - $0.time <= Self.window }
        let inv = invalidates.filter { now - $0 <= Self.window }.count
        let mine = recent.filter { $0.did == did }.count
        return mine >= 3 && recent.count - inv >= 2
    }
}

/// Audio-owner policy: exactly one renderer sounds. The broadcast
/// renderer in cloned/spanned mode (it's the only one), the MAIN
/// display's renderer in independent mode — every other renderer stays
/// muted regardless of the user toggle.
private func isAudioOwnerKey(_ rendererKey: String) -> Bool {
    if rendererKey == broadcastRendererKey { return true }
    return rendererKey == screenUUID(for: CGMainDisplayID())
}

/// Converge every live renderer's audio to the control state + owner
/// policy. Called on install/rekey/reconfigure (topology may have moved
/// the main-display crown) and on audio control deltas.
func reassertAudioOwnership(context: String) {
    let listener = WallpaperControlListener.shared
    let enabled = listener.currentAudioEnabled
    let volume = listener.currentAudioVolume
    for shared in sharedHandlerState.allRenderers() {
        shared.renderer.setAudio(
            enabled: enabled && isAudioOwnerKey(shared.rendererKey),
            volume: volume
        )
    }
}


/// Map the user's aspect preference to AVSampleBufferDisplayLayer's
/// videoGravity (`.fill` → fill, `.fit` → letterbox).
private func videoGravity(for aspectMode: AspectMode) -> AVLayerVideoGravity {
    switch aspectMode {
    case .fill: return .resizeAspectFill
    case .fit:  return .resizeAspect
    }
}

/// Same mapping for a plain CALayer's contentsGravity (variant D's
/// contents-swap layer has no videoGravity — the IOSurface is scaled by
/// the contents gravity instead).
private func contentsGravity(for aspectMode: AspectMode) -> CALayerContentsGravity {
    switch aspectMode {
    case .fill: return .resizeAspectFill
    case .fit:  return .resizeAspect
    }
}


/// The agent's activityState collapsed to the renderer's `.policy`
/// pause reason: `suspended` (display asleep) ⇒ force-paused; everything
/// else (default, idle, locked, active) plays. `idle` is the picker
/// preview / saver state; `locked` shows the wallpaper behind the login
/// UI (the renderer inhibits user/coverage pauses while locked).
private func activitySuspended(_ activityState: String) -> Bool {
    activityState == "suspended"
}


/// Write every renderer's presenting video + in-asset position to the
/// playlist-progress sidecar so an extension respawn (or a Companion
/// merge) resumes where playback was. Renderer keys ARE screen UUIDs,
/// so the scope mapping is direct (broadcast → shared playlist). The
/// asset URL and position come from ONE snapshot so the pair is
/// coherent — the loader resolves the playlist index from the asset,
/// not from its cursor (which is one entry ahead: the pre-popped next
/// reader).
func flushPlaybackProgress(reason: String) {
    for shared in sharedHandlerState.allRenderers() {
        let scope: String? = shared.rendererKey == broadcastRendererKey ? nil : shared.rendererKey
        let snap = shared.renderer.statusSnapshot()
        guard snap.position > 0 else { continue }
        ExtensionVideoLoader.shared.updateProgress(
            timestamp: snap.position,
            presentingLocalPath: snap.assetURL.path,
            screenUUID: scope
        )
    }
}

/// Per-display wall-clock of the last event-driven snapshot save, so
/// the saver-stop burst (exit ramp + agent snapshot() + invalidate)
/// collapses into a single PNG encode.
private let snapshotSaveTimes = OSAllocatedUnfairLock<[UInt32: CFAbsoluteTime]>(initialState: [:])

/// Last content identity written per display. `persistCurrentFrameToDisk`
/// skips the encode + write entirely when nothing changed — a paused
/// wallpaper's frame is identical across every suspend/exit event, and
/// re-encoding it is what tripped macOS's daily disk-write budget in the
/// 2026-08-29 bundle.
private let snapshotContentIdentities = OSAllocatedUnfairLock<[UInt32: String]>(initialState: [:])

/// Shared 3 s per-display gate for the ad-hoc disk rewrites (snapshot()
/// replies, defensive primes) that used to bypass the persist debounce
/// and stack extra multi-MB writes on top of it.
private func shouldRewriteSnapshot(did: UInt32) -> Bool {
    let now = CFAbsoluteTimeGetCurrent()
    return snapshotSaveTimes.withLock { times in
        if let last = times[did], now - last < 3 { return false }
        times[did] = now
        return true
    }
}

/// One poster capture per renderer per engage window: spanned acquires
/// request the SAME canvas frame for every display within milliseconds,
/// and `captureCurrentFrame`'s fallback is a full-4K poster decode. The
/// in-flight task is shared, then retired after a short grace.
private let captureTasks = OSAllocatedUnfairLock<[String: Task<CGImage?, Never>]>(initialState: [:])

private func cachedCapture(renderer: any PlaybackRenderer, key: String) async -> CGImage? {
    let task = captureTasks.withLock { tasks -> Task<CGImage?, Never> in
        if let existing = tasks[key] { return existing }
        let t = Task { await renderer.captureCurrentFrame() }
        tasks[key] = t
        Task {
            _ = await t.value
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            captureTasks.withLock { $0[key] = nil }
        }
        return t
    }
    return await task.value
}

/// Persist `wid`'s current visible frame to the on-disk snapshot cache.
///
/// The disk PNG is what a COLD process primes with, but until now it
/// was only written inside snapshot() replies — which the agent doesn't
/// reliably request at saver stop or before sleep (saver-only setups
/// especially, where the process is dead between sessions). Called at
/// the moments the frame is about to stop mattering while the renderer
/// is still live: the saver exit ramp, the activityState → suspended
/// transition, and invalidate.
func persistCurrentFrameToDisk(reason: String, wid: String) {
    guard let wallpaper = sharedHandlerState.get(wallpaperID: wid),
          let did = wallpaper.displayID,
          let shared = sharedHandlerState.renderer(forWallpaperID: wid) else {
        debugLog("  snapshot-save skipped reason=\(reason) wid=\(wid.prefix(8)) (no display/renderer)")
        return
    }
    let now = CFAbsoluteTimeGetCurrent()
    let debounced = snapshotSaveTimes.withLock { times in
        if let last = times[did], now - last < 3 { return true }
        times[did] = now
        return false
    }
    if debounced {
        debugLog("  snapshot-save debounced reason=\(reason) did=\(did)")
        return
    }
    let renderer = shared.renderer
    Task.detached(priority: .utility) {
        // Content dedupe: identical identity means the frame on disk is
        // already this one — skip the multi-MB encode + write outright.
        if let identity = (renderer as? VideoRenderer)?.snapshotIdentity() {
            let unchanged = snapshotContentIdentities.withLock { ids in
                if ids[did] == identity { return true }
                ids[did] = identity
                return false
            }
            if unchanged {
                debugLog("  snapshot-save skipped (unchanged) reason=\(reason) did=\(did)")
                return
            }
        }
        // Same capture ladder as snapshot(): presenting frame while
        // playing, last decoded survives deep pause, vImage blit for
        // SDR; CIContext/poster-frame capture for 10-bit HDR or a
        // renderer with nothing decoded yet.
        let buffer = renderer.presentingImageBuffer()
            ?? (renderer as? VideoRenderer)?.lastDecodedImageBuffer()
        if let buffer, let cg = bgraCGImage(from: buffer) {
            writeSnapshot(cg, for: did)
            debugLog("  snapshot-save reason=\(reason) did=\(did) src=buffer \(cg.width)x\(cg.height)")
            return
        }
        if let frame = await renderer.captureCurrentFrame() {
            writeSnapshot(frame, for: did)
            debugLog("  snapshot-save reason=\(reason) did=\(did) src=capture \(frame.width)x\(frame.height)")
        } else {
            debugLog("  snapshot-save no-frame reason=\(reason) did=\(did)")
        }
    }
}

/// Fast feed watchdog across every renderer — a renderer that claims to
/// play but stopped enqueueing recovers itself. Cheap: a guarded queue
/// hop + a timestamp compare each (bails immediately when not playing).
func checkAllFeedsHealth() {
    for shared in sharedHandlerState.allRenderers() {
        shared.renderer.checkFeedHealth()
    }
}

/// 30 s periodic progress flush. Created lazily, resumed exactly once
/// from the extension's init.
private let progressFlushTimer: DispatchSourceTimer = {
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
    timer.setEventHandler {
        flushPlaybackProgress(reason: "periodic")
        writeWallpaperStatus(reason: "periodic")
        logRendererDiagnosticsIfChanged()
        // Windows stuck on the no-video fallback get another look at
        // the cache (no-op when none are).
        DispatchQueue.main.async { retryAttachForUnfedWindows(reason: "periodic") }
    }
    return timer
}()

/// Last periodic-diagnostics block — logged only on change, so an idle
/// day costs one block, not one per 30 s.
private nonisolated(unsafe) var lastPeriodicDiagSignature = ""

/// Change-gated renderer snapshot on the 30 s flusher. Topology dumps
/// only fire on acquire/invalidate/reconcile — a mode-churn-only day
/// (like the 2026-07-08 spanned split) used to produce ZERO renderer
/// diagnostics, so a mid-session stall left no trace of when it began.
private func logRendererDiagnosticsIfChanged() {
    // diagnosticsSnapshot queue.syncs into each renderer queue — keep it
    // off the flusher's utility queue like dumpTopology does.
    extensionDiagnosticsQueue.async {
        let lines = sharedHandlerState.allRenderers()
            .sorted { $0.rendererKey < $1.rendererKey }
            .map { "🗺 periodic key=\(shortKey($0.rendererKey)) \($0.renderer.diagnosticsSnapshot())" }
        // Strip the constantly-moving fields (position/lastFeed) so the
        // gate only reacts to structural change: video, pause reasons,
        // subscriber count, skip/revive tallies.
        let signature = lines.map { line in
            line.split(separator: " ")
                .filter { !$0.hasPrefix("tbTime=") && !$0.hasPrefix("lastFeed=") && !$0.hasPrefix("fed=") }
                .joined(separator: " ")
        }.joined(separator: "\n")
        guard signature != lastPeriodicDiagSignature else { return }
        lastPeriodicDiagSignature = signature
        for line in lines { debugLog(line) }
    }
}

/// ~2 s feed-health watchdog — separate from the 30 s progress flush so a
/// dead feed is caught in seconds, not up to ~40 s. The per-renderer check
/// bails immediately when nothing is playing; leeway lets the OS coalesce
/// the wakeups, so the idle cost is negligible.
private let feedHealthTimer: DispatchSourceTimer = {
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
    timer.setEventHandler {
        checkAllFeedsHealth()
    }
    return timer
}()

func startProgressFlusher() {
    progressFlushTimer.resume()
    feedHealthTimer.resume()
    geometryAuditTimer.resume()
}


/// Hide or restore every active overlay driver based on whether the
/// login/lock screen is up, gated on the user's "hide overlays during
/// login" option. Called on every lock transition. Driven globally
/// (not per-wid): lock is a system-wide state, and a running saver's
/// wid may not itself report `locked` while a sibling does. `setHidden`
/// is idempotent, so redundant/overlapping transitions are safe.
/// Honours the `hideOverlaysDuringLogin` setting.
func applyOverlayLoginHide() {
    // Two signals OR together: the agent's per-wid `locked`
    // presentationMode (reliable for wake-to-login) and the
    // process-wide login-shield distributed notification (the only
    // signal that fires when the password prompt appears over a
    // RUNNING screensaver — the saver wid never flips to `locked`).
    let anyLocked = sharedHandlerState.allWallpapers()
        .contains { $0.wallpaper.lastPresentationMode == "locked" }
    let loginUp = anyLocked || sharedHandlerState.isLoginShieldVisible
    let shouldHide = loginUp && OverlayConfigManager.shared.config.hideOverlaysDuringLogin
    let wallpapers = sharedHandlerState.allWallpapers()
    Task { @MainActor in
        for (_, w) in wallpapers {
            w.overlayDriver?.setHidden(shouldHide)
        }
    }
    debugLog("🛡️ login overlay-hide: anyLocked=\(anyLocked) shield=\(sharedHandlerState.isLoginShieldVisible) hideSetting=\(OverlayConfigManager.shared.config.hideOverlaysDuringLogin) → hidden=\(shouldHide)")
}

/// Tokens for the login-shield distributed-notification observers,
/// held for the process lifetime (registered once from the extension's
/// init).
private nonisolated(unsafe) var loginShieldObservers: [NSObjectProtocol] = []

/// Observe the system login/password UI. This is
/// the authoritative cross-context signal: when the password prompt
/// appears over a running screensaver, the WallpaperAgent does NOT send
/// `presentationMode == locked` to the saver's wid, so the per-wid path
/// can't catch it. The notification is process-wide; we fold it into
/// `applyOverlayLoginHide()` which gates on `hideOverlaysDuringLogin`.
func registerLoginShieldObserver() {
    let dnc = DistributedNotificationCenter.default()
    let shown = dnc.addObserver(
        forName: Notification.Name("com.apple.screenLockUIIsShown"),
        object: nil, queue: .main
    ) { _ in
        sharedHandlerState.setLoginShieldVisible(true)
        debugLog("🛡️ login shield shown (distributed notification)")
        applyOverlayLoginHide()
    }
    let hidden = dnc.addObserver(
        forName: Notification.Name("com.apple.screenLockUIIsHidden"),
        object: nil, queue: .main
    ) { _ in
        sharedHandlerState.setLoginShieldVisible(false)
        debugLog("🛡️ login shield hidden (distributed notification)")
        applyOverlayLoginHide()
    }
    loginShieldObservers = [shown, hidden]
    debugLog("🛡️ login-shield observer registered")
}

/// FALLBACK screensaver-mode toggle. Stores the global flag (so a fresh acquire
/// mid-saver can pick it up via `attachWallpaper`) and applies it to every active
/// renderer. Each renderer ORs this with its acquire-driven count, so this only
/// ADDS screensaver mode — it never overrides the working acquire path. No-op when
/// already in the requested state.
func setNotificationScreensaver(_ active: Bool, reason: String) {
    guard sharedHandlerState.isNotificationScreensaverActive != active else { return }
    sharedHandlerState.setNotificationScreensaverActive(active)
    debugLog("🖥️ saver-fallback: \(reason) → screensaver mode \(active ? "ON" : "OFF")")
    if active {
        // Reuse beacon: a didstart while previous saver window(s) are
        // still alive means the agent re-shows a window that was mid
        // exit-transition — the fragile phase in every overlap report.
        let liveSavers = sharedHandlerState.allWallpapers().filter { $0.wallpaper.isScreenSaver }
        if !liveSavers.isEmpty {
            let since = lastSaverStopAt.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "?"
            // Include each reused window's layer-tree variant: the A/B/C
            // experiment only rolls at ACQUIRE, so reused windows keep
            // their original tree — this line attributes an overlap seen
            // on a quick start to the variant it happened on.
            let trees = liveSavers
                .map { "\($0.wid.prefix(8))=\($0.wallpaper.experimentVariant)" }
                .joined(separator: " ")
            debugLog("⚠️ saver didstart with \(liveSavers.count) live saver window(s) — agent reuse, \(since) after last didstop [\(trees)]")
        }
    } else {
        lastSaverStopAt = Date()
    }
    for shared in sharedHandlerState.allRenderers() {
        // Deferred pause reasons live in the renderer now — its reassert
        // re-checks them on clear; no listener reads needed here.
        shared.renderer.setScreensaverModeFromNotification(active)
    }
    wakeContentsSwapPresenters()
    // Switch overlays to match the rate: wallpaper wids were built with the DESKTOP
    // overlay layout; rebuild them for the SCREENSAVER layout (and back on clear).
    rebuildAllOverlayDrivers()
    if active {
        // Churn-mode saver detection: some sessions never acquire a
        // saver window — the agent just flips desktop wids to idle
        // (always in VMs, sometimes on real hardware). If no saver
        // window has shown up shortly after the fallback engages, the
        // idle desktop windows ARE the saver presentation — show the
        // version banner there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard sharedHandlerState.isNotificationScreensaverActive else { return }
            let wallpapers = sharedHandlerState.allWallpapers()
            guard !wallpapers.contains(where: { $0.wallpaper.isScreenSaver }) else { return }
            for (wid, wallpaper) in wallpapers
            where wallpaper.lastPresentationMode == "idle" && !wallpaper.isPreview {
                let w = wallpaper
                Task { @MainActor in
                    if let driver = w.overlayDriver {
                        driver.showVersionBannerForChurnSaver()
                    } else {
                        // No screensaver overlays configured → the engage
                        // rebuild produced no driver, but the banner
                        // needs a rendering surface.
                        rebuildOverlayDriver(wid: wid, wallpaper: w, isDesktop: false, versionBanner: .saverEngage)
                    }
                }
            }
        }
    }
    // Tell the Companion the saver state changed so its auto-pause coordinator
    // stands down (on enter) / re-checks current coverage (on exit). `saverActive`
    // now reflects this fallback flag too, not just the acquire count.
    writeWallpaperStatus(reason: "saver-fallback \(active ? "on" : "off")")
}

/// Tokens for the screensaver-fallback distributed-notification observers,
/// held for the process lifetime (registered once from the extension's init).
private nonisolated(unsafe) var screensaverObservers: [NSObjectProtocol] = []

/// Second-layer screensaver detector. The primary signal is WallpaperAgent's
/// acquire (presentationMode=idle, placement=nil), which is unreliable on macOS
/// 26/27. As a fallback, observe the classic screensaver distributed
/// notifications and toggle screensaver mode. We also LOG a wider set
/// (will*, screenIsLocked/Unlocked) purely to learn which actually fire on this
/// OS. Clearing also happens via update()→default and the acquire-driven exit, so
/// the system/acquire path keeps priority (e.g. on wake-from-sleep).
func registerScreensaverObserver() {
    let dnc = DistributedNotificationCenter.default()
    func observe(_ name: String, _ handler: @escaping () -> Void) -> NSObjectProtocol {
        dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in handler() }
    }
    var tokens: [NSObjectProtocol] = []
    tokens.append(observe("com.apple.screensaver.didstart") {
        setNotificationScreensaver(true, reason: "didstart (distributed)")
    })
    tokens.append(observe("com.apple.screensaver.didstop") {
        setNotificationScreensaver(false, reason: "didstop (distributed)")
    })
    // Diagnostics only — log to discover which signals fire on this macOS.
    for name in ["com.apple.screensaver.willstart", "com.apple.screensaver.willstop",
                 "com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
        let n = name
        tokens.append(observe(n) { debugLog("🖥️ saver-fallback: observed \(n)") })
    }
    screensaverObservers = tokens
    debugLog("🖥️ screensaver-fallback observer registered")
}

private nonisolated(unsafe) var dockObservers: [NSObjectProtocol] = []

/// Live dock-move refresh: the Dock posts this distributed notification
/// when its preferences change (position, size, autohide). The name is
/// undocumented, so this is an OPPORTUNISTIC refresh — if it turns out
/// not to fire on some macOS release, the driver rebuilds on saver
/// enter/exit and overlay-config changes remain the guaranteed
/// re-detection path. It matters because
/// `NSApplication.didChangeScreenParametersNotification` (the driver's
/// own observer) never fires in this appex — there is no NSApplication
/// run loop — so without this, a dock move goes unnoticed until the
/// next mode switch.
func registerDockObserver() {
    let token = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.apple.dock.prefchanged"),
        object: nil,
        queue: .main
    ) { _ in
        debugLog("🖥️ dock-prefchanged: refreshing overlay dock insets")
        let drivers = sharedHandlerState.allWallpapers()
            .compactMap { $0.wallpaper.overlayDriver }
        Task { @MainActor in
            for driver in drivers {
                driver.refreshDockInset()
            }
        }
    }
    dockObservers = [token]
    debugLog("🖥️ dock-prefchanged observer registered")
}

/// Reverse status channel: serialize a small alive/now-playing/pause
/// snapshot for Companion (dashboard card, auto-pause coordinator) and
/// poke it via Darwin notification. The forward control channel has no
/// acknowledgment — this is how Companion knows the extension is
/// running at all.
func writeWallpaperStatus(reason: String) {
    var status = WallpaperStatusState()
    status.pid = Int(ProcessInfo.processInfo.processIdentifier)
    status.lastSeen = Date()
    status.appliedControlVersion = WallpaperControlListener.shared.lastAppliedVersion
    status.identity = runningExtensionIdentity
    status.lockedActive = sharedHandlerState.allWallpapers()
        .contains { $0.wallpaper.lastPresentationMode == "locked" }
    for shared in sharedHandlerState.allRenderers() {
        let key = shared.rendererKey
        // One queue hop per renderer for every playback field.
        let snap = shared.renderer.statusSnapshot()
        if snap.saverActive {
            status.saverActive = true
        }
        // pausedScreens = the user/battery intent (what the dashboard's
        // play/pause reflects); coverage is echoed separately below.
        if !snap.pauseReasons.isDisjoint(with: [.user, .battery]) {
            status.pausedScreens.append(key)
        }
        status.nowPlayingPosition[key] = snap.position
        status.nowPlayingRate[key] = snap.rate
        if let override = shared.renderer.nowPlayingOverride {
            // Live feeds report identity directly — their asset path is
            // a stream URL whose last component (`index.m3u8`) would
            // mis-map in the filename lookup below.
            status.nowPlaying[key] = override.name
            status.nowPlayingId[key] = override.id
        } else {
            let assetPath = snap.assetURL.path
            let info = ExtensionVideoLoader.shared.videoInfo(forLocalPath: assetPath)
            if let name = info.name {
                status.nowPlaying[key] = name
            }
            if let id = info.id {
                status.nowPlayingId[key] = id
            }
        }
    }
    status.autoPausedScreens = WallpaperControlListener.shared.autoPausedScreens()
    _ = JSONPreferencesStore.shared.write(status, to: WallpaperStatusState.fileURL)
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(WallpaperStatusState.darwinNotificationName as CFString),
        nil, nil, true
    )
}

/// Debounced status write for ORGANIC video changes (natural EOF
/// rotation). Fired from the renderer queue via `onVideoChanged` — the
/// actual write MUST run off that queue (`writeWallpaperStatus` and
/// `flushPlaybackProgress` both `queue.sync` into renderers, which
/// would deadlock inline). Dedicated serial queue: `extensionDiagnosticsQueue`
/// stays sync-free by design; don't share it.
private let statusWriteQueue = DispatchQueue(label: "aerial-wallpaper-status-write", qos: .utility)
private nonisolated(unsafe) var pendingVideoChangeWrite: DispatchWorkItem?

func scheduleVideoChangeStatusWrite() {
    statusWriteQueue.async {
        pendingVideoChangeWrite?.cancel()
        let work = DispatchWorkItem {
            flushPlaybackProgress(reason: "video-change")
            writeWallpaperStatus(reason: "video-change")
        }
        pendingVideoChangeWrite = work
        statusWriteQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

/// Get-or-create the SharedRenderer for `rendererKey` and subscribe the
/// wallpaper's display layer to it. Shared by `acquire()` (initial
/// setup) and `reconfigureAllWallpapers()` (re-keying after a viewing-
/// mode change).
///
/// Fast path (renderer exists) is synchronous. Slow path creates the
/// renderer asynchronously and re-checks the wallpaper's key before
/// subscribing — a reconfigure may have re-keyed it while the renderer
/// was loading, and subscribing a moved layer would have two timebases
/// feeding it at once.
func attachWallpaper(
    _ wallpaper: ActiveWallpaper,
    wid: String,
    rendererKey: String,
    playlistScreenUUID: String?,
    isScreenSaver: Bool,
    advanceAtLaunch: Bool = false,
    activitySuspended: Bool,
    context: String
) {
    guard let perAcquireLayer = wallpaper.displayLayer else {
        debugLog("  attachWallpaper: no displayLayer for wid=\(wid.prefix(8)) — skipping")
        return
    }

    if let hit = sharedHandlerState.acquireExistingRenderer(key: rendererKey) {
        // Fast path: SharedRenderer already exists. Just subscribe
        // our per-acquire layer; no async work.
        let existing = hit.shared
        if advanceAtLaunch, hit.wasIdle {
            // Warm saver restart on an idle renderer: swap to the next
            // video BEFORE subscribing (see the helper).
            advanceWarmRendererForSaverLaunch(existing, playlistScreenUUID: playlistScreenUUID,
                                              context: "path=warm, \(context)")
        }
        existing.renderer.addSubscriber(perAcquireLayer)
        if isScreenSaver {
            existing.renderer.enterScreensaverMode()
        } else if sharedHandlerState.isNotificationScreensaverActive {
            // Fresh non-saver acquire while the fallback detector says a
            // screensaver is running — pick up screensaver mode.
            existing.renderer.setScreensaverModeFromNotification(true)
        }
        // Seed pause reasons AFTER saver mode: reasons resolve against
        // the inhibition, so a standing user/coverage pause can never
        // freeze a running saver (the old applyPolicy(.paused) fold did
        // exactly that on this path).
        seedPauseState(existing.renderer, rendererKey: rendererKey, activitySuspended: activitySuspended)
        noteDisplayRefresh(wallpaper, renderer: existing.renderer)
        startContentsSwapPresenterIfNeeded(wallpaper, wid: wid, renderer: existing.renderer)
        hideNoVideoFallback(for: wallpaper, wid: wid)
        debugLog("  Reused SharedRenderer (key=\(shortKey(rendererKey)), \(context)) refCount=\(existing.refCount), suspended=\(activitySuspended), video: \(existing.videoURL.lastPathComponent)")

        // Defensive prime: always refresh from the live renderer
        // when reusing one. The on-disk snapshot was written by a
        // previous process and may show a different video from the
        // playlist (each new process picks fresh); the renderer
        // we're reusing has the current frame. Disk priming at acquire
        // handles the synchronous moment; this async override
        // replaces it ~50 ms later with the correct frame AND
        // re-writes the disk cache so the next cold start primes
        // with the correct video.
        if let did = wallpaper.displayID {
            let renderer = existing.renderer
            let hadDiskPrime = wallpaper.rootLayer.contents != nil
            nonisolated(unsafe) let unsafeRoot = wallpaper.rootLayer
            let destSize = wallpaper.lastDestination.size
            let captureKey = rendererKey
            Task.detached(priority: .userInitiated) {
                // Probe OFF main: both probes queue.sync onto the busy
                // renderer queue, and running four of these as MainActor
                // tasks serialized the whole spanned engage behind decode
                // (2026-08-29 bundle: defensive primes landed 1.2-2.9 s
                // apart, the visible screen-by-screen fill). Only the
                // layer mutation hops to main.
                let buffer = renderer.presentingImageBuffer()
                    ?? (renderer as? VideoRenderer)?.lastDecodedImageBuffer()
                if let buffer,
                   let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
                    await MainActor.run {
                        applyPrime(unsafeRoot, contents: surface,
                                   pixelSize: CGSize(width: CVPixelBufferGetWidth(buffer),
                                                     height: CVPixelBufferGetHeight(buffer)),
                                   displayID: did, destSize: destSize)
                    }
                    if shouldRewriteSnapshot(did: did) {
                        DispatchQueue.global(qos: .utility).async {
                            if let cg = bgraCGImage(from: buffer) {
                                writeSnapshot(cg, for: did)
                            }
                        }
                    }
                    debugLog("  Defensive prime: refreshed from live renderer for did=\(did) (\(hadDiskPrime ? "over disk snapshot" : "rootLayer was blue"), surface)")
                    return
                }
                // Legacy: CIContext / poster-frame capture — a full 4K
                // decode, so ONE per renderer per engage (spanned lands
                // four identical requests within milliseconds; they now
                // share the task). Sliced like every other prime: the
                // poster is the full canvas frame in spanned mode.
                guard let frame = await cachedCapture(renderer: renderer, key: captureKey) else { return }
                await MainActor.run {
                    applyPrime(unsafeRoot, contents: frame,
                               pixelSize: CGSize(width: frame.width, height: frame.height),
                               displayID: did, destSize: destSize)
                }
                if shouldRewriteSnapshot(did: did) {
                    writeSnapshot(frame, for: did)
                }
                debugLog("  Defensive prime: captured live frame for did=\(did) (\(hadDiskPrime ? "over disk snapshot" : "rootLayer was blue"))")
            }
        }
    } else {
        // Slow path: create a new SharedRenderer. Pick what plays,
        // build the right engine async, install (handling races),
        // subscribe our layer.
        if advanceAtLaunch {
            // "Don't resume video at launch": this acquire's first pop
            // advances; the renderer's pre-pop that follows is untouched.
            ExtensionVideoLoader.shared.requestAdvanceOnNextPop(screenUUID: playlistScreenUUID)
            debugLog("⏭ saver launch: advancing instead of resuming (scope=\(playlistScreenUUID.map { String($0.prefix(8)) } ?? "shared"), path=slow, key=\(shortKey(rendererKey)), \(context))")
        }
        guard let selection = selectPlayback(screenUUID: playlistScreenUUID) else {
            // Nothing playable (playlist unresolvable AND no .mov in the
            // cache). Show the rainbow + label instead of parking the
            // window on the solid root colour; the retry paths swap it
            // for real playback once something lands.
            showNoVideoFallback(for: wallpaper, wid: wid, reason: context)
            return
        }
        debugLog("  Creating SharedRenderer (key=\(shortKey(rendererKey)), \(context))")
        nonisolated(unsafe) let unsafePerAcquireLayer = perAcquireLayer
        makeRenderer(
            selection: selection,
            rendererKey: rendererKey,
            playlistScreenUUID: playlistScreenUUID
        ) { renderer, videoURL in
            let candidate = SharedRenderer(rendererKey: rendererKey, videoURL: videoURL, renderer: renderer)
            let (winner, lostRace) = sharedHandlerState.installRenderer(key: rendererKey, candidate: candidate)
            if lostRace {
                debugLog("  Lost race installing SharedRenderer (key=\(shortKey(rendererKey))); discarding duplicate")
                renderer.stop()
            } else {
                debugLog("  Installed SharedRenderer (key=\(shortKey(rendererKey)))")
            }

            // Re-check before subscribing: a reconfigure may have
            // re-keyed this wallpaper (or an invalidate removed it)
            // while the renderer was loading. Release the refCount we
            // took at install and bail — the reconfigure already
            // attached the layer wherever it now belongs.
            guard sharedHandlerState.get(wallpaperID: wid)?.rendererKey == rendererKey else {
                debugLog("  Wallpaper \(wid.prefix(8)) re-keyed/removed during renderer create (key=\(shortKey(rendererKey))) — releasing")
                sharedHandlerState.releaseRenderer(key: rendererKey, gracePeriod: 1) { shared in
                    shared.renderer.stop()
                    debugLog("  Tore down orphaned SharedRenderer (key=\(shortKey(shared.rendererKey)))")
                }
                return
            }
            winner.renderer.addSubscriber(unsafePerAcquireLayer)
            if isScreenSaver {
                winner.renderer.enterScreensaverMode()
            } else if sharedHandlerState.isNotificationScreensaverActive {
                winner.renderer.setScreensaverModeFromNotification(true)
            }
            // Seed pause reasons AFTER saver mode (see fast path).
            seedPauseState(winner.renderer, rendererKey: rendererKey, activitySuspended: activitySuspended)
            // Re-fetch: the completion runs async, so start the variant-D
            // presenter (if any) against the wallpaper's CURRENT state.
            if let fresh = sharedHandlerState.get(wallpaperID: wid) {
                noteDisplayRefresh(fresh, renderer: winner.renderer)
                startContentsSwapPresenterIfNeeded(fresh, wid: wid, renderer: winner.renderer)
                hideNoVideoFallback(for: fresh, wid: wid)
            }
            // Initial Location-overlay feed: a fresh renderer's FIRST
            // video never fires onVideoChanged (that hook only fires on
            // swaps), so push it here now that the asset is loaded.
            pushCurrentVideoToOverlays(rendererKey: rendererKey)
            // The install may have changed which renderer owns audio
            // (broadcast ↔ independent races, main-display arrivals).
            reassertAudioOwnership(context: "renderer-install")
            // diagnosticsSnapshot serializes behind the queued
            // addSubscriber/enterScreensaverMode above, so this
            // dump shows the post-subscribe state.
            dumpTopology(reason: "renderer-install key=\(shortKey(rendererKey))")
        }
    }
}

// MARK: - No-video fallback (rainbow + "No videos found" label)

/// Show the colour-cycling fallback on `wallpaper` (idempotent). Port of
/// the 4.0 saver's startColorAnimation(): before this the window stayed
/// on the solid root colour, or a stale primed snapshot, for ever.
func showNoVideoFallback(for wallpaper: ActiveWallpaper, wid: String, reason: String) {
    guard wallpaper.noVideoFallback == nil else { return }
    // A 4.0-style external cache folder is the one "no videos" case the
    // user can't fix from here: say what to do instead of the generic text.
    let message = Cache.legacyExternalFolderPath != nil
        ? NoVideoFallbackLayer.externalDriveMessage
        : NoVideoFallbackLayer.message
    let layer = NoVideoFallbackLayer.make(
        size: wallpaper.lastDestination.size,
        contentsScale: wallpaper.lastDestination.scaleFactor,
        message: message
    )
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    wallpaper.rootLayer.addSublayer(layer)
    wallpaper.noVideoFallback = layer
    CATransaction.commit()
    debugLog("  🎨 no videos available — showing fallback animation (wid=\(wid.prefix(8)) key=\(shortKey(wallpaper.rendererKey)) \(reason))")
}

/// Remove the fallback once a renderer feeds this window.
func hideNoVideoFallback(for wallpaper: ActiveWallpaper, wid: String) {
    guard let layer = wallpaper.noVideoFallback else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.removeFromSuperlayer()
    wallpaper.noVideoFallback = nil
    CATransaction.commit()
    debugLog("  🎨 fallback removed (wid=\(wid.prefix(8)) — renderer attached)")
}

/// Fallback for every window parked on `key` that has no live renderer
/// (renderer creation failed — the async path only knows the key).
func showNoVideoFallbackForUnfedWindows(key: String, reason: String) {
    for (wid, wallpaper) in sharedHandlerState.allWallpapers()
    where wallpaper.rendererKey == key && sharedHandlerState.renderer(forWallpaperID: wid) == nil {
        showNoVideoFallback(for: wallpaper, wid: wid, reason: reason)
    }
}

/// Re-run `attachWallpaper` for every window currently showing the
/// fallback. Called when videos may have become available: Companion's
/// playlist-changed bump (fires after every finished download), the
/// 30 s periodic tick (Companion-less: the cache dir is scanned live)
/// and wake. A successful attach removes the fallback in its normal
/// completion path; a still-empty catalog leaves it in place (the show
/// call is idempotent). Duplicate creates from overlapping retries are
/// resolved by installRenderer's race handling.
func retryAttachForUnfedWindows(reason: String) {
    let waiting = sharedHandlerState.allWallpapers().filter { $0.wallpaper.noVideoFallback != nil }
    guard !waiting.isEmpty else { return }
    debugLog("🔁 retrying attach for \(waiting.count) window(s) showing the no-video fallback (\(reason))")
    let mode = PrefsDisplays.viewingMode
    let isShared = (mode == .cloned || mode == .spanned)
    for (wid, wallpaper) in waiting {
        let playlistUUID: String? = isShared ? nil : screenUUID(for: wallpaper.displayID)
        attachWallpaper(
            wallpaper,
            wid: wid,
            rendererKey: wallpaper.rendererKey,
            playlistScreenUUID: playlistUUID,
            isScreenSaver: wallpaper.isScreenSaver,
            activitySuspended: activitySuspended(wallpaper.lastActivityState),
            context: "retry \(reason)"
        )
    }
}

/// Seed a renderer's pause intent from the system activity state + the
/// listener's last-applied Companion state — each source lands as its
/// OWN reason (no collapsing; the old fold into a single policy enum is
/// what stranded stuck renderers that dropped every speed change).
/// "Don't resume video at launch" on a warm saver restart: the renderer
/// survived inside its teardown grace, so no pop happens on this acquire.
/// Swap to its pre-buffered next video while it is still unsubscribed — a
/// direct swap (no ghost of the old clip for a window that never showed
/// it), timeline reset with the timebase held at rate 0 — so the joining
/// window's first frame is the next clip, like a cold start. Once per
/// saver session: only the acquire that took refCount 0 → 1 gets here (a
/// second display joining the broadcast renderer sees wasIdle == false; a
/// renderer created by this acquire went through the slow path, whose pop
/// already advanced). The loader is NOT armed: the pre-buffered reader is
/// the advance, and the pre-pop after the swap must stay an ordinary one.
private func advanceWarmRendererForSaverLaunch(_ shared: SharedRenderer, playlistScreenUUID: String?, context: String) {
    let scope = playlistScreenUUID.map { String($0.prefix(8)) } ?? "shared"
    guard shared.renderer.nowPlayingOverride == nil else {
        // A live feed has no position to resume, and its advance is a
        // reconnect / engine switch — not at the fragile engage moment.
        debugLog("⏭ saver launch: warm renderer plays a live feed — not advancing (scope=\(scope), key=\(shortKey(shared.rendererKey)))")
        return
    }
    if ExtensionVideoLoader.shared.cycleMode(for: playlistScreenUUID) == .repeatOne {
        // Repeat-one pins the pre-buffered reader to the current clip;
        // jumpNow() re-invokes the provider for a real pop.
        shared.renderer.jumpNow()
    } else {
        shared.renderer.advanceNow()
    }
    debugLog("⏭ saver launch: advancing instead of resuming (scope=\(scope), \(context), key=\(shortKey(shared.rendererKey)), was \(shared.renderer.currentAssetURL.lastPathComponent))")
}

private func seedPauseState(_ renderer: any PlaybackRenderer, rendererKey: String, activitySuspended: Bool) {
    let listener = WallpaperControlListener.shared
    renderer.applyActivityPolicy(paused: activitySuspended, animated: false)
    // User/coverage are desktop concerns — dropped while Aerial isn't
    // the desktop wallpaper (see `WallpaperControlState.effectivePauseInputs`).
    let inputs = listener.effectivePauseInputs(rendererKey: rendererKey)
    renderer.syncCompanionPauseReasons(
        user: inputs.user,
        battery: listener.currentBatteryPaused,
        coverage: inputs.coverage,
        thermal: listener.currentThermalPaused,
        camera: listener.currentCameraPaused
    )
}

/// Prime a fresh acquire's rootLayer with the best available frame so
/// the gap between reply and first live video shows current content.
/// The agent paints its own backdrop behind a transparent context
/// (verified 2026-07-27), so priming with SOMETHING is required; a warm
/// process can do far better than the disk snapshot, which may be
/// sessions old (the "wrong image at startup" reports). Best first:
///  1. a same-display live window's swap-layer surface — the literally
///     on-screen frame; survives deep pause (presenter retains it);
///  2. the prospective renderer's presenting frame (playing; also
///     covers variant-A/HDR windows which have no swap layer);
///  3. its last DECODED frame — survives deep pause, ≤~2 s ahead of
///     the visible frame;
///  4. the on-disk snapshot (cold process — the only case left);
///  5. nothing (the aerial-blue background set by the caller).
private func primeRootLayer(_ rootLayer: CALayer, displayID: UInt32?, destSize: CGSize) {
    if let did = displayID {
        for (wid, wallpaper) in sharedHandlerState.allWallpapers()
        where wallpaper.displayID == did && !wallpaper.isPreview {
            if let contents = wallpaper.contentsSwapLayer?.contents {
                let pixelSize = (contents as? IOSurface).map {
                    CGSize(width: $0.width, height: $0.height)
                }
                applyPrime(rootLayer, contents: contents, pixelSize: pixelSize,
                           displayID: displayID, destSize: destSize)
                debugLog("  Primed from live window wid=\(wid.prefix(8)) for did=\(did)")
                return
            }
        }
    }

    // Prospective renderer for this acquire — peek WITHOUT acquiring a
    // refCount (allRenderers is a plain snapshot).
    let mode = PrefsDisplays.viewingMode
    let key = makeRendererKey(for: displayID, isShared: mode == .cloned || mode == .spanned)
    if let shared = sharedHandlerState.allRenderers().first(where: { $0.rendererKey == key }) {
        if let buffer = shared.renderer.presentingImageBuffer(),
           let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
            applyPrime(rootLayer, contents: surface,
                       pixelSize: CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
                       displayID: displayID, destSize: destSize)
            debugLog("  Primed from live renderer (presenting) key=\(shortKey(key))")
            return
        }
        if let buffer = (shared.renderer as? VideoRenderer)?.lastDecodedImageBuffer(),
           let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
            applyPrime(rootLayer, contents: surface,
                       pixelSize: CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
                       displayID: displayID, destSize: destSize)
            debugLog("  Primed from live renderer (last decoded) key=\(shortKey(key))")
            return
        }
    }

    if let did = displayID, let cached = loadCachedSnapshotImage(displayID: did) {
        // Slice like tiers 1-3: in spanned mode the cached frame is the
        // FULL canvas — priming it aspect-filled per display showed the
        // whole canvas on every screen at cold boot.
        applyPrime(rootLayer, contents: cached,
                   pixelSize: CGSize(width: cached.width, height: cached.height),
                   displayID: displayID, destSize: destSize)
        debugLog("  Primed rootLayer.contents from cached snapshot for did=\(did)")
    }
}

/// Assign primed contents with geometry that matches what playback
/// will show. In spanned mode the surface is the FULL video frame while
/// this window shows only its slice — replicate the video layer's
/// aspect-fill + slice via `contentsRect` (the historical full-frame
/// prime was the visible "reframe jump" at spanned starts).
private func applyPrime(_ rootLayer: CALayer, contents: Any, pixelSize: CGSize?, displayID: UInt32?, destSize: CGSize) {
    rootLayer.contents = contents
    if let pixelSize, pixelSize.width > 0, pixelSize.height > 0,
       let frame = spannedLayerFrame(for: displayID),
       let slice = SpannedGeometry.visibleSlice(layerFrame: frame, windowSize: destSize) {
        // `visibleSlice` is WINDOW-space (log-verified 2026-07-27: both
        // displays report (0,0,w,h) with different layerFrames) —
        // translate into canvas space before mapping into the image,
        // or every display primes with the canvas's leftmost slice.
        let canvasSlice = slice.offsetBy(dx: -frame.origin.x, dy: -frame.origin.y)
        // Aspect-fill scale of the video into the canvas (canvas points
        // per video pixel), then this display's slice normalized into
        // the image's unit space. contentsRect is bottom-left based on
        // an unflipped macOS layer; if a stacked spanned layout ever
        // shows the wrong VERTICAL band, flip here: y = 1-(y+height).
        let scale = max(frame.width / pixelSize.width, frame.height / pixelSize.height)
        let overhangX = (pixelSize.width * scale - frame.width) / 2
        let overhangY = (pixelSize.height * scale - frame.height) / 2
        let unitSlice = CGRect(
            x: ((canvasSlice.minX + overhangX) / scale) / pixelSize.width,
            y: ((canvasSlice.minY + overhangY) / scale) / pixelSize.height,
            width: (canvasSlice.width / scale) / pixelSize.width,
            height: (canvasSlice.height / scale) / pixelSize.height
        )
        rootLayer.contentsRect = unitSlice.sanitized(
            "prime contentsRect did=\(displayID ?? 0)", fallback: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        rootLayer.contentsGravity = .resize
    } else {
        rootLayer.contentsGravity = .resizeAspectFill
    }
}

/// Full local teardown of one wallpaper window: unsubscribe its layer
/// from the SharedRenderer (reconciling saver/locked counts BEFORE the
/// release so the rate falls back while the renderer is live), stop
/// the overlay driver and contents-swap presenter, blank the layer
/// tree (a zombie hosting context shows transparency instead of stale
/// frames), release the renderer refCount (grace-deferred teardown),
/// and drop the ActiveWallpaper. Shared by the agent's `invalidate`
/// and the churn eviction path — the agent never invalidates the
/// windows it abandons, so eviction must do the identical cleanup.
@discardableResult
func teardownWallpaperWindow(wid uuid: String, gracePeriod: TimeInterval, context: String) -> Bool {
    if let wallpaper = sharedHandlerState.get(wallpaperID: uuid),
       let layer = wallpaper.displayLayer,
       let shared = sharedHandlerState.renderer(forWallpaperID: uuid) {
        if wallpaper.isScreenSaver {
            // Any pause deferred while the saver ran re-lands inside
            // the renderer's reassert as this saver subscriber detaches.
            shared.renderer.exitScreensaverMode()
            // An armed reuse-advance dies with the window: the next start
            // is an acquire, and the fast path's idle guard owns it.
            saverReenterAdvanceArmed.withLock { _ = $0.remove(shared.rendererKey) }
        }
        if wallpaper.lastPresentationMode == "locked" {
            // A window that dies while `locked` takes its +1 with it —
            // its unlock update will never come. Without this, the
            // leaked count pins the rate to lockedScreenRate AND
            // inhibits every Companion pause forever (2026-07-10 wake
            // incident).
            debugLog("  window died in locked mode — reconciling locked count")
            shared.renderer.exitLockedMode()
        }
        shared.renderer.removeSubscriber(layer)
        if let swap = wallpaper.contentsSwapLayer {
            (shared.renderer as? VideoRenderer)?.removeGhostHost(swap)
        }
    }
    // Also stop the per-acquire overlay driver (timer + OverlayState
    // cleanup). Hop to main since the driver is MainActor-isolated.
    if let wallpaper = sharedHandlerState.get(wallpaperID: uuid),
       let driver = wallpaper.overlayDriver {
        Task { @MainActor in
            driver.stop()
        }
    }
    sharedHandlerState.releaseRenderer(forWallpaperID: uuid, gracePeriod: gracePeriod) { shared in
        // Remember what was on screen (mirror read, non-blocking) so the
        // next acquire for this scope resumes it instead of popping the
        // next entry — a saver restarted 2–5 min later used to change
        // video while shorter and longer gaps both kept it. Live feeds
        // carry no file position; they rotate as before.
        if shared.renderer.nowPlayingOverride == nil {
            let snap = shared.renderer.statusSnapshot()
            ExtensionVideoLoader.shared.noteRendererTornDown(
                presentingLocalPath: snap.assetURL.path,
                timestamp: snap.position > 0 ? snap.position : nil,
                screenUUID: shared.rendererKey == broadcastRendererKey ? nil : shared.rendererKey
            )
        }
        shared.renderer.stop()
        debugLog("  Tore down SharedRenderer (key=\(shortKey(shared.rendererKey))) after grace period")
    }
    // Blank the tree before dropping our reference: if the hosting side
    // keeps compositing this context (zombie window), it now shows
    // transparency instead of stale video frames.
    if let wallpaper = sharedHandlerState.get(wallpaperID: uuid) {
        wallpaper.contentsSwapPresenter?.stop()
        wallpaper.contentsSwapPresenter = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaper.debugBadge = nil
        wallpaper.noVideoFallback = nil
        wallpaper.rootLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        wallpaper.rootLayer.contents = nil
        wallpaper.rootLayer.backgroundColor = nil
        CATransaction.commit()
        CATransaction.flush()
        debugLog("  🧹 blanked tree for wid=\(uuid.prefix(8)) — zombie hosting now shows transparency (\(context))")
    }
    return sharedHandlerState.remove(wallpaperID: uuid) != nil
}

/// Churn mitigation (Tahoe 26.5.2 agent window churn — 9+ windows piled
/// on 2 displays in the 2026-07-25 field bundle): when the agent
/// re-acquires a display WITHOUT invalidating the previous window, the
/// old one is abandoned — nothing composites it, its layer jams, and it
/// leaks a subscriber + presenter until process death. Self-clean it,
/// under a triple guard, because multiple same-display windows are
/// legitimate (one per Space):
///  1. the churn detector currently flags this display,
///  2. the candidate is old (>120 s — not part of this engage burst),
///  3. its layer is demonstrably stuck (not-ready across a whole
///     fan-out streak — the abandoned-window signature).
private func evictSupersededWindows(newWid: String, displayID: UInt32?, isScreenSaver: Bool) {
    guard let displayID, WindowChurnDetector.shared.isChurning(did: displayID) else { return }
    let now = CFAbsoluteTimeGetCurrent()
    for (wid, wallpaper) in sharedHandlerState.allWallpapers() {
        guard wid != newWid,
              wallpaper.displayID == displayID,
              wallpaper.isScreenSaver == isScreenSaver,
              !wallpaper.isPreview,
              now - wallpaper.acquiredAt > 120,
              let layer = wallpaper.displayLayer,
              let shared = sharedHandlerState.renderer(forWallpaperID: wid),
              (shared.renderer as? VideoRenderer)?.isSubscriberStuck(layer) == true
        else { continue }
        let age = Int(now - wallpaper.acquiredAt)
        debugLog("🌀🧹 evicting superseded window wid=\(wid.prefix(8)) did=\(displayID) age=\(age)s — churn-flagged display, stuck layer, superseded by wid=\(newWid.prefix(8))")
        teardownWallpaperWindow(wid: wid, gracePeriod: 120, context: "churn-evict")
    }
}

/// Report the refresh rate of `wallpaper`'s display to the renderer's
/// frame-thinning cap (VideoRenderer-only — the live engine has no
/// reader to thin). Called wherever a wallpaper's layer subscribes.
private func noteDisplayRefresh(_ wallpaper: ActiveWallpaper, renderer: any PlaybackRenderer) {
    guard let did = wallpaper.displayID,
          let hz = CGDisplayCopyDisplayMode(did)?.refreshRate, hz > 0 else { return }
    (renderer as? VideoRenderer)?.noteDisplayRefresh(hz)
}

/// Variant D: start (or restart) the contents-swap presenter for a
/// window whose tree was built without an in-tree AVSBDL. Works for
/// both engines (`presentingImageBuffer()` is on the protocol). Also
/// (re-)registers the swap layer as a transition ghost host on file
/// engines — its AVSBDL twin is an off-tree orphan the ghost pass
/// skips. Called from both `attachWallpaper` paths, the dest-change
/// re-layout, and the live↔file engine switch.
private func startContentsSwapPresenterIfNeeded(_ wallpaper: ActiveWallpaper, wid: String, renderer: any PlaybackRenderer) {
    guard let layer = wallpaper.contentsSwapLayer else { return }
    wallpaper.contentsSwapPresenter?.stop()
    wallpaper.contentsSwapPresenter = nil
    (renderer as? VideoRenderer)?.addGhostHost(layer)
    wallpaper.contentsSwapPresenter = ContentsSwapPresenter(
        layer: layer,
        renderer: renderer,
        wid: wid,
        displayID: wallpaper.displayID
    )
}

/// Kick every idle contents-swap presenter back to vsync ahead of a
/// state change that may set frames moving again (control reconcile,
/// saver-mode toggle). Cheap and safe to over-call: a running presenter
/// ignores it, a woken one re-idles ~2 s later if nothing changed.
func wakeContentsSwapPresenters() {
    for (_, wallpaper) in sharedHandlerState.allWallpapers() {
        wallpaper.contentsSwapPresenter?.wake()
    }
}

/// Build the right engine for `selection`, install its playlist hooks,
/// start it, and hand it back with its creation URL. File engines load
/// their first track asynchronously; live engines are synchronous but
/// delivered through the same completion for one call shape.
private func makeRenderer(
    selection: PlaybackSelection,
    rendererKey: String,
    playlistScreenUUID: String?,
    onFailure: (@Sendable () -> Void)? = nil,
    completion: @escaping @Sendable (any PlaybackRenderer, URL) -> Void
) {
    switch selection {
    case .file(let videoURL, let resumeAt, let rotation, let playDuration):
        Task {
            let renderer: VideoRenderer
            do {
                renderer = try await VideoRenderer.create(videoURL: videoURL, startAt: resumeAt,
                                                          extraRotation: rotation, playDuration: playDuration)
            } catch {
                debugLog("  Renderer create failed (key=\(shortKey(rendererKey))): \(error).")
                showNoVideoFallbackForUnfedWindows(key: rendererKey, reason: "renderer create failed")
                onFailure?()
                return
            }
            installFileHooks(on: renderer, rendererKey: rendererKey, playlistScreenUUID: playlistScreenUUID)
            renderer.setNominalRate(WallpaperControlListener.shared.currentSpeed)
            renderer.setTransitionConfig(WallpaperControlListener.shared.currentTransitionConfig)
            renderer.setLoopCurrentVideo(ExtensionVideoLoader.shared.cycleMode(for: playlistScreenUUID) == .repeatOne)
            renderer.setAudio(
                enabled: WallpaperControlListener.shared.currentAudioEnabled && isAudioOwnerKey(rendererKey),
                volume: WallpaperControlListener.shared.currentAudioVolume
            )
            renderer.start()
            AudioSpike.runIfRequested(videoURL: videoURL)
            completion(renderer, videoURL)
        }
    case .live(let url, _, _, _):
        let renderer = LiveStreamRenderer(selection: selection)
        installLiveHooks(on: renderer, rendererKey: rendererKey, playlistScreenUUID: playlistScreenUUID)
        renderer.setAudio(
            enabled: WallpaperControlListener.shared.currentAudioEnabled && isAudioOwnerKey(rendererKey),
            volume: WallpaperControlListener.shared.currentAudioVolume
        )
        renderer.start()
        completion(renderer, url)
    }
}

/// Playlist hooks for the FILE engine, including the stash-and-defer
/// live handoff. Shared mode passes nil so `resolvePlaylist` returns
/// the sharedPlaylist — same content across all subscribed displays.
private func installFileHooks(on renderer: VideoRenderer, rendererKey: String, playlistScreenUUID: String?) {
    renderer.nextVideoProvider = {
        // A stashed live entry: this call IS the loop boundary (the
        // first pop happened at the START of the current video) — hand
        // the slot to the live engine now.
        if let pending = sharedHandlerState.takePendingSwitch(key: rendererKey) {
            switchSharedRenderer(key: rendererKey, to: pending, playlistScreenUUID: playlistScreenUUID)
            return nil   // loop current until the switch lands
        }
        // shouldLoop unused — see selectPlayback. resumeTimestamp is
        // irrelevant here: loop boundaries always start the next video at
        // zero. playDuration travels with the pop for bounded looping.
        guard let selection = selectPlayback(screenUUID: playlistScreenUUID) else { return nil }
        switch selection {
        case .file(let url, _, _, let playDuration):
            return VideoRenderer.NextVideo(url: url, playDuration: playDuration)
        case .live:
            sharedHandlerState.setPendingSwitch(selection, key: rendererKey)
            debugLog("  live entry queued for key=\(shortKey(rendererKey)) — engine switch at the loop boundary")
            return nil
        }
    }

    renderer.previousVideoProvider = {
        guard let result = ExtensionVideoLoader.shared.popPreviousFromPlaylist(
            screenUUID: playlistScreenUUID
        ) else { return nil }
        guard let selection = playbackSelection(for: result.video, resumeAt: nil,
                                                playDuration: result.playDuration) else { return nil }
        switch selection {
        case .file(let url, _, _, let playDuration):
            return VideoRenderer.NextVideo(url: url, playDuration: playDuration)
        case .live:
            // User-initiated — switch right away, no boundary to respect.
            switchSharedRenderer(key: rendererKey, to: selection, playlistScreenUUID: playlistScreenUUID)
            return nil
        }
    }

    // Per-video rotation override for the videos the hooks hand over by
    // URL (the first video's value travels in the selection).
    renderer.rotationOverrideProvider = { url in
        rotationOverride(for: url)
    }

    // Organic-change echo: the Companion's now-playing follows natural
    // rotation within ~1 s instead of the next 30 s periodic flush.
    // Fired on the renderer queue — only enqueues; the write runs on
    // statusWriteQueue. The overlay push resolves off-thread too
    // (it reads the renderer's mirror for the asset URL).
    renderer.onVideoChanged = {
        scheduleVideoChangeStatusWrite()
        pushCurrentVideoToOverlays(rendererKey: rendererKey)
    }

    // Watchdog escalation: the reader cancel did not free the pump. Log
    // only for now — the mirror keeps status/snapshot/control served;
    // a renderer replacement hangs off this hook if field logs show it.
    renderer.onQueueWedged = {
        debugLog("🐕 [Handler] renderer key=\(shortKey(rendererKey)) queue still wedged after the watchdog cancel — replacement not implemented; status/snapshot keep serving from the mirror")
    }
}

/// Hooks for the LIVE engine: playlist pops, URL refresh for stall
/// recovery, and the way back to the file engine.
private func installLiveHooks(on renderer: LiveStreamRenderer, rendererKey: String, playlistScreenUUID: String?) {
    renderer.selectNext = {
        selectPlayback(screenUUID: playlistScreenUUID)
    }
    renderer.selectPrevious = {
        guard let result = ExtensionVideoLoader.shared.popPreviousFromPlaylist(
            screenUUID: playlistScreenUUID
        ) else { return nil }
        return playbackSelection(for: result.0, resumeAt: nil)
    }
    renderer.requestRendererSwitch = { selection in
        switchSharedRenderer(key: rendererKey, to: selection, playlistScreenUUID: playlistScreenUUID)
    }
    renderer.refreshStreamURL = { videoId in
        // Re-parse the cached manifests — picks up the Companion's
        // TTL-gated re-resolve written to entries.json. Cheap and
        // network-free for the live source.
        VideoList.instance.reloadSources()
        guard let video = VideoList.instance.videos.first(where: { $0.id == videoId }), video.isLive else {
            return nil
        }
        return video.url
    }
    renderer.requestCachedFallback = {
        guard let fallback = pickRandomCachedVideo() else { return }
        switchSharedRenderer(
            key: rendererKey,
            to: .file(url: fallback, resumeAt: nil, rotation: rotationOverride(for: fallback), playDuration: nil),
            playlistScreenUUID: playlistScreenUUID
        )
    }
    renderer.onVideoChanged = {
        scheduleVideoChangeStatusWrite()
        pushCurrentVideoToOverlays(rendererKey: rendererKey)
    }
}

/// Push the renderer's current video into every overlay driver on that
/// renderer — the Location overlay needs the video (POI timeline) plus
/// a playback-position source, and the AVPlayer-less engine can't feed
/// it any other way. Safe from any thread: resolution hops to a utility
/// queue (reading the asset URL queue.syncs into the renderer, which
/// must never happen from the renderer's own queue — onVideoChanged
/// fires there).
func pushCurrentVideoToOverlays(rendererKey: String) {
    DispatchQueue.global(qos: .utility).async {
        guard let shared = sharedHandlerState.allRenderers()
            .first(where: { $0.rendererKey == rendererKey }) else { return }
        let renderer = shared.renderer

        let video: AerialVideo?
        if let override = renderer.nowPlayingOverride {
            video = VideoList.instance.videos.first { $0.id == override.id }
        } else if let id = ExtensionVideoLoader.shared.videoId(forLocalPath: renderer.currentAssetURL.path) {
            video = VideoList.instance.videos.first { $0.id == id }
        } else {
            video = nil
        }
        guard let video else { return }

        let targets = sharedHandlerState.allWallpapers()
            .filter { $0.wallpaper.rendererKey == rendererKey }
            .compactMap { $0.wallpaper.overlayDriver }
        guard !targets.isEmpty else { return }

        let positionProvider: () -> Double = { [weak renderer] in
            renderer?.currentContentPosition ?? 0
        }
        debugLog("  📍 location → \(video.secondaryName) (\(video.poi.count) POI entries) → \(targets.count) overlay(s)")
        Task { @MainActor in
            for driver in targets {
                driver.setCurrentVideo(video, positionProvider: positionProvider)
            }
        }
    }
}

/// Serial queue for engine switches: keeps replace/migrate/stop
/// ordering deterministic and safely OFF both renderers' queues
/// (calling `stop()` from a renderer's own queue would deadlock its
/// internal `queue.sync`; the provider closures that trigger switches
/// run on renderer queues).
private let rendererSwitchQueue = DispatchQueue(label: "aerial-wallpaper-engine-switch", qos: .userInitiated)
/// Keys with a switch in flight — touched only on rendererSwitchQueue.
private nonisolated(unsafe) var switchesInFlight: Set<String> = []

/// Replace the engine behind `key` with the right renderer for
/// `selection` (live↔file). Preserves the acquire bookkeeping
/// (`replaceRenderer` keeps the refCount), migrates the subscriber
/// layers, re-seeds live state, and stops the old engine. Hard cut —
/// no ghost transition across engines (v1).
func switchSharedRenderer(key: String, to selection: PlaybackSelection, playlistScreenUUID: String?) {
    rendererSwitchQueue.async {
        guard !switchesInFlight.contains(key) else {
            debugLog("  engine switch already in flight for key=\(shortKey(key)) — ignoring")
            return
        }
        switchesInFlight.insert(key)
        makeRenderer(
            selection: selection,
            rendererKey: key,
            playlistScreenUUID: playlistScreenUUID,
            // A failed create never reaches the completion below, which is
            // where the in-flight mark used to be cleared — without this
            // the key stayed blocked for every later engine switch.
            onFailure: { rendererSwitchQueue.async { switchesInFlight.remove(key) } }
        ) { newRenderer, videoURL in
            rendererSwitchQueue.async {
                defer { switchesInFlight.remove(key) }
                let candidate = SharedRenderer(rendererKey: key, videoURL: videoURL, renderer: newRenderer)
                guard let old = sharedHandlerState.replaceRenderer(key: key, candidate: candidate) else {
                    debugLog("  engine switch: key=\(shortKey(key)) vanished — discarding new renderer")
                    newRenderer.stop()
                    return
                }
                // Migrate every wallpaper on this key (rekey ordering):
                // the per-acquire layers survive; only the feeder moves.
                for (wid, wallpaper) in sharedHandlerState.allWallpapers() where wallpaper.rendererKey == key {
                    if let layer = wallpaper.displayLayer {
                        old.renderer.removeSubscriber(layer)
                        newRenderer.addSubscriber(layer)
                        noteDisplayRefresh(wallpaper, renderer: newRenderer)
                    }
                    if wallpaper.isScreenSaver {
                        newRenderer.enterScreensaverMode()
                    }
                    // Variant D: the presenter holds the OLD renderer
                    // weakly — rebind to the new engine (also re-registers
                    // the ghost host when the new engine is file-based).
                    startContentsSwapPresenterIfNeeded(wallpaper, wid: wid, renderer: newRenderer)
                }
                if sharedHandlerState.isNotificationScreensaverActive {
                    newRenderer.setScreensaverModeFromNotification(true)
                }
                seedPauseState(newRenderer, rendererKey: key, activitySuspended: false)
                old.renderer.stop()
                debugLog("🔁 engine switch key=\(shortKey(key)) → \(videoURL.lastPathComponent)")
                dumpTopology(reason: "engine-switch key=\(shortKey(key))")
                writeWallpaperStatus(reason: "engine-switch")
            }
        }
    }
}

/// Re-key and re-layout every active wallpaper after a displays-settings
/// change (viewing mode / display mode / aspect / margins). WallpaperAgent
/// never re-acquires for OUR settings, so this is the only path by which
/// a live wallpaper adopts a new topology. Settings must already be
/// reloaded (ScreensaverSettingsManager.reloadFromDisk) and
/// DisplayDetection refreshed by the caller.
func reconfigureAllWallpapers() {
    let mode = PrefsDisplays.viewingMode
    let isShared = (mode == .cloned || mode == .spanned)
    debugLog("🔧 reconfigure: viewingMode=\(mode.displayName) aspect=\(PrefsDisplays.aspectMode == .fill ? "fill" : "fit")")
    // Beacon: re-keying while saver windows are live doubles the window
    // count and races per-window renderer creation (four-monitor log:
    // duplicate Creating SharedRenderer + Lost race per key) — flag it
    // so overlap reports can be correlated with this phase.
    let saverWids = sharedHandlerState.allWallpapers().filter { $0.wallpaper.isScreenSaver }
    if !saverWids.isEmpty || sharedHandlerState.isNotificationScreensaverActive {
        debugLog("⚠️ reconfigure while saver active (\(saverWids.count) saver wid(s), fallback=\(sharedHandlerState.isNotificationScreensaverActive))")
    }

    for (wid, wallpaper) in sharedHandlerState.allWallpapers() {
        let newKey = makeRendererKey(for: wallpaper.displayID, isShared: isShared)
        let newPlaylistUUID: String? = isShared ? nil : screenUUID(for: wallpaper.displayID)

        // Geometry + gravity re-apply unconditionally — aspect or
        // margins may have changed even when the renderer key didn't.
        reapplyGeometry(to: wallpaper)

        rekeyWallpaper(wallpaper, wid: wid, newKey: newKey, newPlaylistUUID: newPlaylistUUID, context: "reconfigure")

        // Rebuild the diagnostic badge to the current toggle state —
        // this is the settings funnel, so flipping the Advanced-panel
        // switch lands here via the settings-changed reconcile.
        applyDiagnosticBadge(to: wallpaper, wid: wid)
    }
    // Viewing-mode flips move audio ownership (broadcast ↔ main-display
    // renderer) — converge the survivors; freshly re-keyed renderers get
    // seeded at creation.
    reassertAudioOwnership(context: "reconfigure")
    dumpTopology(reason: "reconfigure")
}

/// Re-apply gravity + frame (spanned slice, or the full window) to one
/// wallpaper's video layer and its swap layer, without animation.
func reapplyGeometry(to wallpaper: ActiveWallpaper) {
    guard let layer = wallpaper.displayLayer else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.videoGravity = videoGravity(for: PrefsDisplays.aspectMode)
    if let spanned = spannedLayerFrame(for: wallpaper.displayID) {
        layer.frame = spanned.sanitized("rebind spanned")
    } else {
        layer.frame = CGRect(origin: .zero, size: wallpaper.lastDestination.size).sanitized("rebind per-display")
    }
    if let swap = wallpaper.contentsSwapLayer {
        swap.contentsGravity = contentsGravity(for: PrefsDisplays.aspectMode)
        swap.frame = layer.frame
    }
    CATransaction.commit()
}

/// Last display-set signature a topology check saw. Serializes the
/// checks themselves: acquire (XPC thread), invalidate, the control
/// listener (main) and the wake pass (global queue) can all land
/// together on a hot-plug.
/// Renderer keys whose saver windows flipped idle → default with "Don't
/// resume video at launch" in force: the default → idle re-enter (window
/// reuse, no acquire) advances once per key. Cleared on invalidate — the
/// next start is then an acquire and the fast path's idle guard owns it.
private let saverReenterAdvanceArmed = OSAllocatedUnfairLock<Set<String>>(initialState: [])

private let topologyLock = OSAllocatedUnfairLock<String?>(initialState: nil)

/// Re-detect displays and, in spanned mode, re-slice EVERY active
/// wallpaper when the display set actually changed.
///
/// Why: the spanned canvas is a snapshot of `DisplayDetection.screens`,
/// and each window's slice is computed against it at ITS acquire. A
/// display that appears later (a DisplayLink monitor attaching seconds
/// after boot/wake — sometimes under a new id), one that disappears, or
/// a rearrangement in System Settings leaves the survivors on the old
/// canvas: WallpaperAgent acquires only the newcomer and never
/// re-acquires the rest, and `reconfigureAllWallpapers()` runs for OUR
/// settings changes only (2026-08-22 four-display bundle: the late
/// display showed a centre crop while three windows kept the old
/// canvas). The signature compare makes churn acquires/invalidates a
/// no-op; the first call in a process just seeds the signature.
@discardableResult
func refreshTopologyAndResliceIfChanged(reason: String) -> Bool {
    let resliced: Int? = topologyLock.withLock { last -> Int? in
        let detection = DisplayDetection.sharedInstance
        detection.detectDisplays()
        let signature = detection.topologySignature
        let previous = last
        last = signature
        guard let previous, previous != signature else { return nil }
        guard PrefsDisplays.viewingMode == .spanned else { return nil }
        let wallpapers = sharedHandlerState.allWallpapers()
        let before = previous.isEmpty ? 0 : previous.split(separator: "|").count
        debugLog("🧭 topology changed (\(reason)): \(before)→\(detection.screens.count) display(s) — re-slicing \(wallpapers.count) window(s)")
        for (_, wallpaper) in wallpapers {
            reapplyGeometry(to: wallpaper)
        }
        return wallpapers.count
    }
    guard resliced != nil else { return false }
    dumpTopology(reason: "topology \(reason)")
    return true
}

/// Detach `wallpaper` from its current renderer and attach it under
/// `newKey` (get-or-create). No-op when the key is unchanged. Shared by
/// `reconfigureAllWallpapers` (viewing-mode changes) and `update()`'s
/// destination-move path (wallpaper migrated to a different physical
/// screen). Callers handle any geometry changes themselves.
func rekeyWallpaper(_ wallpaper: ActiveWallpaper, wid: String, newKey: String, newPlaylistUUID: String?, context: String) {
    guard newKey != wallpaper.rendererKey else { return }
    let oldKey = wallpaper.rendererKey

    // Detach from the old renderer: screensaver count first (so the
    // rate falls back while it's live), unsubscribe, release the OLD
    // key — all before mutating rendererKey, which the wid-based
    // release resolves through.
    if let old = sharedHandlerState.renderer(forWallpaperID: wid) {
        if wallpaper.isScreenSaver {
            old.renderer.exitScreensaverMode()
        }
        if let layer = wallpaper.displayLayer {
            old.renderer.removeSubscriber(layer)
        }
    }
    sharedHandlerState.releaseRenderer(forWallpaperID: wid, gracePeriod: 5) { shared in
        shared.renderer.stop()
        debugLog("  Tore down SharedRenderer (key=\(shortKey(shared.rendererKey))) after re-key grace")
    }
    wallpaper.rendererKey = newKey
    // A live↔file switch queued against the OLD key is stale now.
    sharedHandlerState.clearPendingSwitch(key: oldKey)
    debugLog("  re-keyed wid=\(wid.prefix(8)) \(shortKey(oldKey)) → \(shortKey(newKey)) (\(context))")

    // We don't have a live activityState here; if the process were
    // suspended we wouldn't be running, so assume active. The
    // Companion-driven pause reasons re-seed inside attachWallpaper.
    attachWallpaper(
        wallpaper,
        wid: wid,
        rendererKey: newKey,
        playlistScreenUUID: newPlaylistUUID,
        isScreenSaver: wallpaper.isScreenSaver,
        activitySuspended: false,
        context: context
    )
}

/// Stop and recreate every wallpaper's overlay driver against the
/// (re-read) overlay config. The separate-desktop gate inside
/// `OverlayRenderingDriver.create` applies, so toggling that setting —
/// or any overlay-editor save — adds/removes/refreshes wallpaper
/// overlays without waiting for a process respawn.
/// Tear down and rebuild one window's overlay driver (on the MainActor).
/// Rebuilds never INITIATE the version banner — with the default
/// `.none` request a banner that's mid-display on the old driver is
/// carried over so the rebuild doesn't kill it early. Pass
/// `.saverEngage` only for a genuine saver engagement (the churn-saver
/// nil-driver path).
func rebuildOverlayDriver(
    wid: String,
    wallpaper: ActiveWallpaper,
    isDesktop: Bool,
    versionBanner: OverlayRenderingDriver.VersionBannerRequest = .none
) {
    let w = wallpaper
    let widShort = String(wid.prefix(8))
    Task { @MainActor in
        var bannerRequest = versionBanner
        if let old = w.overlayDriver {
            if bannerRequest == .none, old.isShowingVersionBanner {
                bannerRequest = .carryOver
            }
            old.stop()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            old.overlayLayer.removeFromSuperlayer()
            CATransaction.commit()
            w.overlayDriver = nil
        }
        let driver = OverlayRenderingDriver.create(
            screenUUID: screenUUID(for: w.displayID),
            displayID: w.displayID,
            displaySize: w.lastDestination.size,
            contentsScale: w.lastDestination.scaleFactor,
            systemAppearance: w.lastSystemAppearance,
            isDesktop: isDesktop,
            versionBanner: bannerRequest
        )
        if let driver {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            w.rootLayer.addSublayer(driver.overlayLayer)
            CATransaction.commit()
        }
        w.overlayDriver = driver
        debugLog("  rebuilt overlay for wid=\(widShort): \(driver != nil ? "active" : "none")")
        if driver != nil {
            // Fresh driver knows nothing about the playing video —
            // feed the Location overlay.
            pushCurrentVideoToOverlays(rendererKey: w.rendererKey)
        }
    }
}

func rebuildAllOverlayDrivers() {
    // Honour the screensaver-mode fallback: while it's active a wallpaper wid shows
    // the SCREENSAVER overlay layout (isDesktop=false), matching the 1.0× rate.
    let fallbackActive = sharedHandlerState.isNotificationScreensaverActive
    for (wid, wallpaper) in sharedHandlerState.allWallpapers() {
        rebuildOverlayDriver(
            wid: wid,
            wallpaper: wallpaper,
            isDesktop: !(wallpaper.isScreenSaver || fallbackActive)
        )
    }
}


final class WallpaperXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    var agentProxy: (any WallpaperExtensionProxyXPCProtocol)?

    // MARK: - Lifecycle

    func acquire(withId id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        let seq = nextSeq()
        let acquireStart = CFAbsoluteTimeGetCurrent()
        debugLog("=== ACQUIRE === seq=\(seq) build=\(buildTimestamp)")

        // Refresh display topology so spanned/advanced-margin geometry
        // reflects the current monitor layout and the latest margin
        // prefs (basic + advanced). `detectDisplays()` is idempotent —
        // it resets `screens` first — and routes to the right zeroed-
        // origin calculator based on `PrefsDisplays.displayMarginsAdvanced`.
        // If the display SET changed since the last look (hot-plug, a
        // DisplayLink monitor attaching late after boot/wake), the
        // windows already on screen are re-sliced against the new
        // canvas here — the agent only acquires the newcomer.
        refreshTopologyAndResliceIfChanged(reason: "acquire seq=\(seq)")

        // Verbose diagnostics follow Companion's advanced debug-mode
        // setting (live via the settings-changed reconcile). The Mirror
        // walks + dozens of log lines per request are exactly what made
        // acquires slow enough to visibly stagger multi-display setup.
        if PrefsAdvanced.debugMode {
            if let idObj = id as? NSObject {
                dumpMirror(idObj, label: "acquire.id", depth: 4)
            }
            if let reqObj = request as? NSObject {
                dumpMirror(reqObj, label: "acquire.request", depth: 6)
            }
            debugLog("  NSScreen.screens (\(NSScreen.screens.count)):")
            for (i, screen) in NSScreen.screens.enumerated() {
                let did = screen.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID ?? 0
                debugLog("    [\(i)] did=\(did) frame=\(screen.frame) name=\(screen.localizedName)")
            }
        }

        // Extract wallpaperID UUID for invalidate() cleanup
        var wallpaperIDString: String?
        if let idObj = id as? NSObject {
            let idStr = String(describing: Mirror(reflecting: idObj).children.first?.value ?? "")
            if let range = idStr.range(of: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}", options: .regularExpression) {
                wallpaperIDString = String(idStr[range])
            }
        }

        // Extract destination via Mirror.
        let dest = extractDestination(request) ?? (CGSize(width: 2560, height: 1440), 2.0, nil)
        let destSize = dest.size
        let scaleFactor = dest.scaleFactor
        let displayID = dest.displayID

        // Extract the descriptor's choice configuration (which video to
        // play). The optionValues placement/color come back via `ctx`.
        var choiceConfiguration: String?
        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            for child in mirror.children {
                let reqMirror = Mirror(reflecting: child.value)
                for prop in reqMirror.children where prop.label == "descriptor" {
                    let descMirror = Mirror(reflecting: prop.value)
                    for descProp in descMirror.children where descProp.label == "configuration" {
                        if let data = descProp.value as? Data, !data.isEmpty {
                            choiceConfiguration = String(data: data, encoding: .utf8)
                        }
                    }
                }
            }
        }

        // Presentation context — full request data. `presentationMode`
        // and `activityState` drive the initial playback policy.
        // `systemAppearance` flows through to the overlay driver.
        // `cacheDirectory` becomes our snapshot cache root.
        // `placement` / `hasFallbackColor` are surfaced for visibility
        // only (no behaviour change today).
        let ctx = extractRequestContext(request)

        // Note: `ctx.cacheDirectory` points into WallpaperAgent's
        // sandbox container — our entitlements don't cover it, so the
        // snapshot cache stays on `/Users/Shared/Aerial/`. We keep the
        // URL in the log line for visibility but don't adopt it.

        debugLog("  destination: \(destSize) @\(scaleFactor)x, displayID: \(displayID ?? 0), wallpaperID: \(wallpaperIDString ?? "nil"), choice: \(choiceConfiguration ?? "nil"), mode=\(ctx.presentationMode), activity=\(ctx.activityState), appearance=\(ctx.systemAppearance), preview=\(ctx.isPreview), placement=\(ctx.placement ?? "nil"), fallbackColor=\(ctx.hasFallbackColor), cacheDir=\(ctx.cacheDirectory?.lastPathComponent ?? "nil")")
        WindowChurnDetector.shared.noteAcquire(did: displayID, isPreview: ctx.isPreview)

        // 1. Create remote CAContext for cross-process rendering.
        //    contentsScale is declared AT CREATION: the post-creation
        //    setter no-ops on macOS 26.5.2 (setter removed — see the
        //    beta3 field bundle: fresh saver acquires there rendered
        //    the AVSBDL surface at 1×, the half-width "overlap", over
        //    our own root-contents snapshot). The creation-options
        //    path is the only remaining way to declare the ×2 mapping.
        var contextOptions: [String: Any] = ["contentsScale": scaleFactor]
        if let did = displayID {
            contextOptions["displayId"] = did
        }
        // Private class method — an OS that renames it raises an
        // unrecognized-selector exception; caught, it is just the nil path.
        let caContext = ObjCException.attempt("CAContext.remoteContextWithOptions:") {
            CAContext.perform(
                NSSelectorFromString("remoteContextWithOptions:"), with: contextOptions
            )?.takeUnretainedValue() as? CAContext
        }.flatMap { $0 }
        let contextId = caContext?.contextId ?? 0
        debugLog("  CAContext id: \(contextId)")

        guard let caContext, contextId != 0 else {
            debugLog("  ERROR: remoteContextWithOptions: \(caContext == nil ? "returned nil / not a CAContext" : "contextId == 0")")
            reply(nil, NSError(domain: "Aerial4WallpaperExtension", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create CAContext",
            ]))
            return
        }

        // 1a. Tell the context its display scale explicitly. The hosting
        //     side otherwise has to infer the Retina ×2 mapping when it
        //     adopts the context; Logs-5 caught it compositing a fully
        //     correct 2056×1329@2x tree at 1× — exactly half width/height
        //     in a corner (the "quarter overlap"), with every window and
        //     layer frame verified full-screen. KVC through the private
        //     property, responds-guarded so an OS that drops the setter
        //     just no-ops.
        if caContext.responds(to: NSSelectorFromString("setContentsScale:")) {
            let applied = ObjCException.attempt("CAContext setContentsScale: (KVC)") {
                caContext.setValue(scaleFactor, forKey: "contentsScale")
            }
            debugLog("  CAContext contentsScale → \(scaleFactor)\(applied == nil ? " FAILED (exception caught)" : "")")
        } else {
            debugLog("  CAContext has no setContentsScale: — skipped (creation option is the declaration)")
        }
        // Read back what actually stuck — the getter can survive a
        // dropped setter. The next diagnostic bundle proves whether the
        // creation option took (2.0) or the OS ignored it too (1.0/0).
        if caContext.responds(to: NSSelectorFromString("contentsScale")) {
            let effective = ObjCException.attempt("CAContext contentsScale (KVC get)") {
                caContext.value(forKey: "contentsScale")
            }.flatMap { $0 } ?? "?"
            debugLog("  CAContext effective contentsScale: \(effective) (declared \(scaleFactor))")
        } else {
            debugLog("  CAContext has no contentsScale getter — effective scale unknown")
        }

        // 2. Wrap contextId in WallpaperRemoteContextXPC
        guard let replyObj = createRemoteContextXPC(contextId: contextId) else {
            reply(nil, NSError(domain: "Aerial4WallpaperExtension", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create WallpaperRemoteContextXPC",
            ]))
            return
        }

        // 3. Build the layer. Aerial blue is the background fallback
        //    under the video. If we have a previously-stashed frame
        //    for this display, prime `rootLayer.contents` with it so
        //    the gap between reply and first-frame doesn't show blue.
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: destSize).sanitized("acquire root")
        rootLayer.contentsScale = scaleFactor
        rootLayer.backgroundColor = aerialBlue
        primeRootLayer(rootLayer, displayID: displayID, destSize: destSize)
        // Private property setter — same unrecognized-selector risk as
        // the constructor above, and the last point where a clean error
        // reply is still possible.
        do {
            try ObjCException.catching("CAContext.setLayer:") { caContext.layer = rootLayer }
        } catch {
            reply(nil, NSError(domain: "Aerial4WallpaperExtension", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Failed to attach the layer to the CAContext: \(error)",
            ]))
            return
        }
        CATransaction.flush()

        // 4. Branch on viewing mode. Shared modes (cloned / spanned)
        //    collapse all displays into one broadcast SharedRenderer
        //    with one decoder; independent mode gives each displayID
        //    its own renderer.
        let mode = PrefsDisplays.viewingMode
        let isShared = (mode == .cloned || mode == .spanned)
        let rendererKey = makeRendererKey(for: displayID, isShared: isShared)
        // The playlist screen UUID: per-display in independent, nil in
        // shared mode so `resolvePlaylist(nil)` returns `sharedPlaylist`.
        let playlistScreenUUID: String? = isShared ? nil : screenUUID(for: displayID)

        // 5. Build a fresh per-acquire displayLayer that will subscribe
        //    to whichever SharedRenderer we end up with. The geometry
        //    mutations are wrapped in a no-actions transaction so the
        //    layer doesn't implicitly animate from its initial frame to
        //    the spanned-frame target — WindowServer compositing
        //    a mid-animation state would render the layer at half size
        //    in the bottom-left, which has been seen in the wild.
        // 5b. Compositor-mapping workaround: macOS 26.5.2 removed every
        //     API that declares a remote context's contentsScale, and
        //     the agent's adoption races to a wrong point↔pixel mapping
        //     for the AVSBDL surface (the "overlap" photos — clean
        //     trees, half-size live video over our root snapshot).
        //     D (contents-swap — no video-surface node in the
        //     serialized context for the agent's special-casing to
        //     mis-map) is the production default. A (plain AVSBDL
        //     sublayer, the pre-26 construction) is the only variant
        //     that negotiates EDR, so HDR formats get A despite the
        //     adoption race. Retired 2026-07 after D superseded them:
        //     B (1x video surface, failed) and C (rasterized container
        //     — fixed the overlap but flattened video, no EDR, one
        //     offscreen pass per frame). The variant is chosen only at
        //     acquire — settings changes don't re-pick attached
        //     windows — and the auto-select reads the GLOBAL format
        //     only (per-video `videoFormatOverride` is a known
        //     limitation). Revisit if macOS 27 fixes the adoption race
        //     (the extension point itself is 26+ only).
        let experimentVariant: String
        if PrefsAdvanced.showDiagnosticBadges {
            // Manual override — honored literally, even against an HDR
            // format.
            switch PrefsAdvanced.overlapWorkaround {
            case .variantA: experimentVariant = "A"
            case .variantD: experimentVariant = "D"
            }
        } else {
            // D is the production default; A is the only EDR-capable
            // construction, so HDR formats get A.
            experimentVariant = PrefsVideos.videoFormat.isHDR ? "A" : "D"
        }

        let perAcquireLayer = VideoRenderer.makeDisplayLayer(size: destSize, contentsScale: scaleFactor)
        var contentsSwapLayer: CALayer?
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch experimentVariant {
        case "D":
            // Contents-swap: the AVSBDL stays OFF the tree (an orphan
            // subscriber that drives the renderer's pump/pacing); video
            // is shown by a plain CALayer whose `contents` a 30 Hz
            // presenter swaps to the renderer's presenting IOSurface.
            // The serialized context then carries NO video-surface node
            // for the agent's special-casing to detach (the VM miniature
            // repro proved it detaches the AVSBDL even from inside a
            // rasterized container).
            let swap = CALayer()
            swap.frame = CGRect(origin: .zero, size: destSize).sanitized("acquire swap")
            swap.contentsScale = scaleFactor
            swap.masksToBounds = true
            rootLayer.addSublayer(swap)
            contentsSwapLayer = swap
        default:
            rootLayer.addSublayer(perAcquireLayer)
        }
        if PrefsAdvanced.showDiagnosticBadges {
            debugLog("  🧪 variant=\(experimentVariant) (manual) seq=\(seq)")
        } else {
            debugLog("  variant=\(experimentVariant) (auto, hdrFormat=\(PrefsVideos.videoFormat.isHDR)) seq=\(seq)")
        }
        // 5a. Apply user aspect preference + spanned-mode geometry.
        //     In `.spanned`, the layer extends across the union of all
        //     active displays with origin offset by -this-display's
        //     zeroedOrigin. WindowServer's per-display wallpaper window
        //     naturally clips to the right portion — so identical
        //     sample buffers fed to every subscriber form one
        //     continuous image across screens.
        perAcquireLayer.videoGravity = videoGravity(for: PrefsDisplays.aspectMode)
        if let spannedFrame = spannedLayerFrame(for: displayID) {
            perAcquireLayer.frame = spannedFrame.sanitized("acquire spanned")
            debugLog("  spanned: layer frame=\(spannedFrame) for did=\(displayID ?? 0), gravity=\(perAcquireLayer.videoGravity.rawValue)")
        }
        if let swap = contentsSwapLayer {
            swap.contentsGravity = contentsGravity(for: PrefsDisplays.aspectMode)
            if let spannedFrame = spannedLayerFrame(for: displayID) {
                swap.frame = spannedFrame.sanitized("acquire swap spanned")
            }
        }
        CATransaction.commit()

        // Classify the acquire (rule + rationale in `SaverAcquireRule`):
        // `mode=idle` on a FIRST acquire is the saver session; the role
        // additionally needs no picker placement while Aerial is also the
        // desktop wallpaper (a desktop window re-acquired mid-saver
        // carries one). Previews never count. The role routes overlays,
        // subscriber accounting and the status echo; playback correctness
        // rides on the process-wide flag raised right below.
        let desktopActive = WallpaperControlListener.shared.currentDesktopWallpaperActive
        let verdict = SaverAcquireRule.classify(
            presentationMode: ctx.presentationMode, isPreview: ctx.isPreview,
            placement: ctx.placement, desktopWallpaperActive: desktopActive
        )
        let isScreenSaver = verdict.isSaverRole
        // "Don't resume video at launch" — see SaverAcquireRule.advancesAtLaunch.
        let advanceAtLaunch = SaverAcquireRule.advancesAtLaunch(
            verdict, desktopWallpaperActive: desktopActive, optionEnabled: PrefsVideos.saverAdvanceAtLaunch
        )
        debugLog("  role: screensaver=\(isScreenSaver) advanceAtLaunch=\(advanceAtLaunch) rendererKey=\(shortKey(rendererKey)) playlistUUID=\(playlistScreenUUID.map { String($0.prefix(8)) } ?? "shared")")
        if verdict.saverRunning {
            // The acquire itself is the live saver signal: a process
            // spawned FOR the saver has already missed the didstart
            // notification (it fires ~0.1 s before INIT), and the
            // update→idle path needs a transition this window never
            // makes. Raise the process-wide flag now so `attachWallpaper`
            // seeds the renderer against the saver inhibition, whatever
            // the role says — the 2026-09-17 frozen-first-start report
            // (saver-only install, `placement=Crop` on the acquire).
            setNotificationScreensaver(true, reason: "acquire→idle wid=\(wallpaperIDString.map { String($0.prefix(8)) } ?? "?")")
            if !isScreenSaver {
                debugLog("  🖥️ idle acquire without saver role: placement=\(ctx.placement ?? "nil") preview=\(ctx.isPreview) desktopActive=\(desktopActive) activity=\(ctx.activityState)")
            }
        }

        // 6. Park ActiveWallpaper NOW (before reply) so a fast
        //    UPDATE/INVALIDATE that arrives before async renderer
        //    setup finishes still finds the right entry. Stash
        //    `presentationMode` so the first `update()` doesn't see a
        //    spurious lock-transition diff against the default value.
        if let wid = wallpaperIDString {
            let wallpaper = ActiveWallpaper(
                caContext: caContext,
                rootLayer: rootLayer,
                displayID: displayID,
                rendererKey: rendererKey,
                displayLayer: perAcquireLayer,
            )
            wallpaper.lastPresentationMode = ctx.presentationMode
            wallpaper.lastSystemAppearance = ctx.systemAppearance
            wallpaper.lastPlacement = ctx.placement
            wallpaper.lastDestination = (destSize, scaleFactor, displayID)
            wallpaper.isScreenSaver = isScreenSaver
            wallpaper.isPreview = ctx.isPreview
            wallpaper.acquireSeq = seq
            wallpaper.experimentVariant = experimentVariant
            wallpaper.contentsSwapLayer = contentsSwapLayer
            sharedHandlerState.store(wallpaperID: wid, wallpaper: wallpaper)
            applyDiagnosticBadge(to: wallpaper, wid: wid)

            // 6b. Overlay driver — fully async, post-park. Overlays are
            //     cosmetic (1 Hz) and the driver's initial SwiftUI
            //     ImageRenderer pass is main-thread work; the old
            //     500 ms semaphore here serialized multi-display setup
            //     behind overlay rendering. The re-fetch guards handle
            //     an invalidate (or a config-driven rebuild) racing the
            //     creation.
            let appearance = ctx.systemAppearance
            let useDesktopLayout = !(isScreenSaver || sharedHandlerState.isNotificationScreensaverActive)
            let overlayDID = displayID
            let overlaySize = destSize
            let overlayScale = scaleFactor
            Task { @MainActor in
                let driver = OverlayRenderingDriver.create(
                    screenUUID: screenUUID(for: overlayDID),
                    displayID: overlayDID,
                    displaySize: overlaySize,
                    contentsScale: overlayScale,
                    systemAppearance: appearance,
                    isDesktop: useDesktopLayout,
                    // Explicit request: only windows acquired AS the
                    // screensaver announce the version. Desktop acquires
                    // never do, even while the saver fallback is active.
                    versionBanner: isScreenSaver ? .saverEngage : .none,
                )
                guard let driver else { return }
                guard let parked = sharedHandlerState.get(wallpaperID: wid),
                      parked.overlayDriver == nil else {
                    // Invalidated while rendering, or a rebuild beat us
                    // to it — don't leak a live timer/layer.
                    driver.stop()
                    return
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                parked.rootLayer.addSublayer(driver.overlayLayer)
                CATransaction.commit()
                parked.overlayDriver = driver
                // Feed the Location overlay with whatever this window's
                // renderer is already playing (a REUSED renderer never
                // fires onVideoChanged for the current video; a fresh
                // renderer pushes again from its install completion).
                pushCurrentVideoToOverlays(rendererKey: parked.rendererKey)
            }
        }

        // 7. Get-or-create the SharedRenderer and subscribe our layer.
        //    Compute the initial policy from the user pause flag and the
        //    system-reported presentationMode/activityState — applied to
        //    the renderer on both fast (reuse) and slow (create) paths
        //    so the first frame matches the requested state.

        // WallpaperControl's pause is a wallpaper-only concept — if the
        // user explicitly invokes the screensaver they want video,
        // regardless of whether the wallpaper is paused via the
        // Companion panel. Include window-coverage auto-pause so a fresh
        // acquire for an already-covered display cold-starts paused.
        if let wid = wallpaperIDString, let wallpaper = sharedHandlerState.get(wallpaperID: wid) {
            attachWallpaper(
                wallpaper,
                wid: wid,
                rendererKey: rendererKey,
                playlistScreenUUID: playlistScreenUUID,
                isScreenSaver: isScreenSaver,
                advanceAtLaunch: advanceAtLaunch,
                activitySuspended: activitySuspended(ctx.activityState),
                context: "acquire mode=\(mode.displayName)"
            )
            // Churn eviction for this acquire runs post-reply (see the
            // reply block below) — its stuck-layer check syncs onto the
            // renderer queue and must not delay the engage.
        } else {
            // Never observed in the field — every acquire carries a
            // wallpaperID. Without one we can't track the subscription
            // for invalidate, so don't create an untrackable one.
            debugLog("  No wallpaperID — skipping renderer attach")
        }

        // 8. Sanity-check the landed layer geometry before reply.
        //    A "top-left quarter" symptom has been observed once where
        //    the spanned-mode perAcquireLayer ended up at the wrong
        //    bounds. If we detect a mismatch, log loudly and re-apply
        //    the intended frame so the next composite is correct.
        if let expected = spannedLayerFrame(for: displayID) {
            let actual = perAcquireLayer.frame
            let tolerance: CGFloat = 0.5
            let driftedSize = abs(actual.width - expected.width) > tolerance
                || abs(actual.height - expected.height) > tolerance
            let driftedOrigin = abs(actual.origin.x - expected.origin.x) > tolerance
                || abs(actual.origin.y - expected.origin.y) > tolerance
            if driftedSize || driftedOrigin {
                debugLog("  SANITY: perAcquireLayer.frame=\(actual) drifted from expected=\(expected); re-applying")
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                perAcquireLayer.frame = expected.sanitized("sanity re-apply")
                CATransaction.commit()
            }
        }

        // Log the actual landed layer state. The earlier "spanned:
        // layer frame=…" logs the INTENT; this captures the post-CATransaction
        // reality. Future debugging of mis-rendered acquires starts here.
        debugLog("  final: rootLayer bounds=\(rootLayer.bounds) contentsScale=\(rootLayer.contentsScale) sublayers=\(rootLayer.sublayers?.count ?? 0)")
        debugLog("  final: perAcquireLayer bounds=\(perAcquireLayer.bounds) position=\(perAcquireLayer.position) anchor=\(perAcquireLayer.anchorPoint) contentsScale=\(perAcquireLayer.contentsScale) gravity=\(perAcquireLayer.videoGravity.rawValue)")

        // Flush before reply so WindowServer sees the complete tree
        // (rootLayer + perAcquireLayer + optional overlayLayer) in
        // its final geometry. Without this the sublayer additions and
        // frame changes after the initial caContext.layer assignment
        // sit in implicit transactions whose commit timing depends on
        // runloop state — composites caught mid-implicit have been
        // observed to mis-render in spanned mode.
        CATransaction.flush()

        // Reply FIRST, diagnostics after — and OFF this thread. The
        // agent serializes multi-display engages behind this reply
        // (the next display's acquire arrives ~3 ms after it), and the
        // topology/status dumps queue.sync into a renderer queue that
        // is busy decoding during an engage: the 2026-07-26 field
        // bundle measured 360-609 ms per acquire with ~80% of it in
        // those hops — visible as saver windows appearing one by one
        // on a 4-display setup. The dumps still serialize behind the
        // queued addSubscriber (per-renderer-queue ordering), so they
        // show the post-subscribe state exactly as before; they just
        // no longer gate the next display's window.
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - acquireStart) * 1000)
        debugLog("  Replying to acquire seq=\(seq) (contextId: \(contextId), active contexts now: \(sharedHandlerState.count)) — handled in \(elapsedMs) ms")
        reply(replyObj, nil)

        let evictWid = wallpaperIDString
        let evictDisplayID = displayID
        let evictIsSaver = isScreenSaver
        DispatchQueue.global(qos: .utility).async {
            dumpTopology(reason: "acquire seq=\(seq)")
            writeWallpaperStatus(reason: "acquire")
            // Churn mitigation runs post-reply too: its stuck-layer
            // check is a renderer-queue sync hop and must not delay
            // the engage either.
            if let evictWid {
                evictSupersededWindows(newWid: evictWid, displayID: evictDisplayID, isScreenSaver: evictIsSaver)
            }
        }
    }

    func update(withId id: Any?, request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        let seq = nextSeq()
        debugLog("=== UPDATE === seq=\(seq)")
        if PrefsAdvanced.debugMode {
            if let idObj = id as? NSObject {
                dumpMirror(idObj, label: "update.id", depth: 3)
            }
            if let reqObj = request as? NSObject {
                dumpMirror(reqObj, label: "update.request", depth: 5)
            }
        }

        // Extract wallpaperID from id (same regex as invalidate). Lets us
        // look up the renderer in sharedHandlerState.
        var wallpaperIDString: String?
        if let idObj = id as? NSObject {
            let idStr = String(describing: Mirror(reflecting: idObj).children.first?.value ?? "")
            if let range = idStr.range(of: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}", options: .regularExpression) {
                wallpaperIDString = String(idStr[range])
            }
        }

        let ctx = extractRequestContext(request)
        let updatedDestination = extractDestination(request)

        // Apply the system activity policy to this wallpaper's renderer.
        // Only the `.policy` pause reason is touched — an active update
        // can no longer stomp a user/coverage pause (the old applyPolicy
        // (.full) resumed deliberately-paused renderers). Ramp only on
        // genuine lock transitions while the process is still active;
        // multiple wallpaperIDs on the same display coalesce naturally
        // (the reason toggle is a no-op when it already matches).
        if let wid = wallpaperIDString, let wallpaper = sharedHandlerState.get(wallpaperID: wid) {
            let oldMode = wallpaper.lastPresentationMode
            wallpaper.lastPresentationMode = ctx.presentationMode
            let oldActivity = wallpaper.lastActivityState
            wallpaper.lastActivityState = ctx.activityState
            let isLockTransition = (oldMode == "locked") != (ctx.presentationMode == "locked")
            let animated = isLockTransition && ctx.activityState == "active"
            let shared = sharedHandlerState.renderer(forWallpaperID: wid)
            shared?.renderer.applyActivityPolicy(
                paused: activitySuspended(ctx.activityState),
                animated: animated
            )

            // Display just went to sleep — typically the last signal
            // this process sees before full system sleep (no willSleep
            // arrives in the appex). The renderer paused above with the
            // last-visible frame still decoded; persist it so the
            // wake-side cold acquire primes with the pre-sleep frame
            // instead of an older session's PNG.
            if activitySuspended(ctx.activityState), !activitySuspended(oldActivity) {
                persistCurrentFrameToDisk(reason: "activity-suspend", wid: wid)
            }

            // Lock-screen pause inhibition: the login UI shows the
            // wallpaper, so the renderer must keep playing — track the
            // locked state per wallpaper; deferred pause reasons re-land
            // at unlock via the renderer's reassert.
            if isLockTransition {
                if ctx.presentationMode == "locked" {
                    shared?.renderer.enterLockedMode()
                } else {
                    shared?.renderer.exitLockedMode()
                }
                statusWriteQueue.async { writeWallpaperStatus(reason: "lock-transition") }
            }

            // A saver wid flipping idle → default means the screensaver
            // is no longer presenting — but WallpaperAgent won't send its
            // INVALIDATE for another ~5 s. Start easing back to the
            // wallpaper's nominal rate NOW; the invalidate becomes pure
            // bookkeeping.
            if wallpaper.isScreenSaver, oldMode == "idle", ctx.presentationMode == "default" {
                shared?.renderer.beginScreensaverExitRamp()
                // "Don't resume video at launch": a quick restart inside the
                // invalidate window reuses these windows (no acquire), so the
                // advance is armed here and fired on the default → idle flip.
                if let key = shared?.rendererKey, PrefsVideos.saverAdvanceAtLaunch,
                   !WallpaperControlListener.shared.currentDesktopWallpaperActive {
                    saverReenterAdvanceArmed.withLock { _ = $0.insert(key) }
                }
                // The saver visually exited (rate ramps down now). `saverActive`
                // is gated on `!screensaverRateSuspended`, so writing status here
                // flips it false ~5 s before the INVALIDATE — let the Companion
                // coordinator re-check coverage now rather than at invalidate.
                statusWriteQueue.async { writeWallpaperStatus(reason: "saver-exit-ramp") }
                // Saver-only setups get no wallpaper snapshot() requests
                // between sessions — persist this session's frame now so
                // the next cold engage primes with it.
                persistCurrentFrameToDisk(reason: "saver-exit-ramp", wid: wid)
            }

            // The symmetric re-entry: a quick saver restart inside the
            // ~5-15 s invalidate window makes WallpaperAgent REUSE the
            // live saver windows — no fresh acquire, so the renderer's
            // enterScreensaverMode never fires. The wid flipping back
            // default → idle is the acquire-path signal that the saver
            // is presenting again; undo the exit ramp. (Deliberately NOT
            // enterScreensaverMode(): these windows were never
            // invalidated, so the subscriber count still includes them —
            // incrementing again would drift it.)
            if wallpaper.isScreenSaver, oldMode == "default", ctx.presentationMode == "idle" {
                debugLog("  saver re-enter (reuse): wid=\(wid.prefix(8)) variant=\(wallpaper.experimentVariant)")
                shared?.renderer.cancelScreensaverExitRamp()
                if let shared, saverReenterAdvanceArmed.withLock({ $0.remove(shared.rendererKey) != nil }) {
                    // Renderer live and subscribed here: the normal skip
                    // transition runs, which is right for a visible restart.
                    advanceWarmRendererForSaverLaunch(
                        shared,
                        playlistScreenUUID: shared.rendererKey == broadcastRendererKey ? nil : shared.rendererKey,
                        context: "path=reuse wid=\(wid.prefix(8))"
                    )
                }
                statusWriteQueue.async { writeWallpaperStatus(reason: "saver-reenter") }
            }

            // FALLBACK screensaver detector (second layer; the acquire-driven
            // isScreenSaver path is unreliable on macOS 26/27). A non-saver
            // wallpaper wid transitioning to `idle` means a screensaver is
            // presenting even without a fresh screensaver acquire; a transition
            // to `default` (any wid) means the desktop is back. The renderer ORs
            // this with the acquire count, and the →default clear also drops any
            // stuck fallback flag — so the acquire/system path keeps priority
            // (e.g. wake-from-sleep, which drives the count via a real acquire).
            // Preview windows are excluded both ways: a System Settings
            // preview flipping to idle must not put every renderer into
            // saver mode, and one flipping back to default must not clear
            // a fallback owned by a real running saver. (Update requests
            // carry no preview field — the stored acquire-time flag is
            // the source of truth.)
            if oldMode != ctx.presentationMode {
                if ctx.presentationMode == "idle", !wallpaper.isScreenSaver, !wallpaper.isPreview {
                    setNotificationScreensaver(true, reason: "update→idle wid=\(wid.prefix(8))")
                } else if ctx.presentationMode == "default", !wallpaper.isPreview {
                    setNotificationScreensaver(false, reason: "update→default wid=\(wid.prefix(8))")
                }
            }

            // Lock transition → hide / restore overlays, globally and
            // gated on the user's "hide overlays during login" option.
            // Global (not just this wid) because a running saver's wid
            // may not itself flip to `locked`, yet its overlays must
            // still vanish behind the login UI.
            if isLockTransition {
                applyOverlayLoginHide()
            }

            // Appearance delta → re-render the overlay in the new
            // colour scheme. Driver compares internally and no-ops on
            // unchanged values.
            var appearanceChanged = false
            if ctx.systemAppearance != wallpaper.lastSystemAppearance {
                appearanceChanged = true
                wallpaper.lastSystemAppearance = ctx.systemAppearance
                if let driver = wallpaper.overlayDriver {
                    let value = ctx.systemAppearance
                    Task { @MainActor in driver.setSystemAppearance(value) }
                }
            }

            // Destination delta → re-layout the per-acquire display
            // layer. Resolution / scale-factor changes that don't
            // trigger invalidate+re-acquire are rare but possible.
            var destChanged = false
            if let new = updatedDestination {
                let old = wallpaper.lastDestination
                if new.size != old.size || new.scaleFactor != old.scaleFactor || new.displayID != old.displayID {
                    destChanged = true
                    wallpaper.lastDestination = (new.size, new.scaleFactor, new.displayID)
                    if new.displayID != old.displayID {
                        // Display re-enumeration (sleep/wake, replug) or a
                        // genuine move. Keep displayID current — spanned
                        // frames, snapshots and overlays look up by it —
                        // and re-key if the underlying physical screen
                        // changed. (Same screen, new ID → same UUID key →
                        // rekey is a no-op; the stale-key cold-create +
                        // double-decoder leak dies here.)
                        wallpaper.displayID = new.displayID
                        DisplayDetection.sharedInstance.detectDisplays()
                        let vm = PrefsDisplays.viewingMode
                        let nowShared = (vm == .cloned || vm == .spanned)
                        let newKey = makeRendererKey(for: new.displayID, isShared: nowShared)
                        let newUUID = nowShared ? nil : screenUUID(for: new.displayID)
                        rekeyWallpaper(wallpaper, wid: wid, newKey: newKey, newPlaylistUUID: newUUID, context: "dest-move")
                    }
                    if let layer = wallpaper.displayLayer {
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        if let spanned = spannedLayerFrame(for: new.displayID) {
                            layer.frame = spanned.sanitized("update spanned")
                        } else {
                            layer.frame = CGRect(origin: .zero, size: new.size).sanitized("update per-display")
                        }
                        layer.contentsScale = new.scaleFactor
                        if let swap = wallpaper.contentsSwapLayer {
                            swap.frame = layer.frame
                            swap.contentsScale = new.scaleFactor
                        }
                        wallpaper.rootLayer.contentsScale = new.scaleFactor
                        CATransaction.commit()
                    } else {
                        wallpaper.rootLayer.contentsScale = new.scaleFactor
                    }
                    wallpaper.noVideoFallback?.resize(to: new.size, contentsScale: new.scaleFactor)
                    // Variant D: the presenter's display link is bound
                    // to the OLD displayID — rebuild it against the new
                    // one. Fresh renderer lookup: a dest-move re-key
                    // above may have swapped the renderer behind wid.
                    if wallpaper.contentsSwapLayer != nil,
                       let current = sharedHandlerState.renderer(forWallpaperID: wid) {
                        startContentsSwapPresenterIfNeeded(wallpaper, wid: wid, renderer: current.renderer)
                    }
                }
            }

            debugLog("  summary seq=\(seq) mode=\(ctx.presentationMode) activity=\(ctx.activityState) appearance=\(ctx.systemAppearance) suspended=\(activitySuspended(ctx.activityState)) animated=\(animated) appChg=\(appearanceChanged) destChg=\(destChanged) wallpaperID=\(wid) renderer=\(shared != nil ? "ok" : "none")")
        } else {
            debugLog("  summary seq=\(seq) mode=\(ctx.presentationMode) activity=\(ctx.activityState) appearance=\(ctx.systemAppearance) suspended=\(activitySuspended(ctx.activityState)) (no matching wallpaper)")
        }
        reply(nil)
    }

    func invalidate(withId id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        let seq = nextSeq()
        debugLog("=== INVALIDATE === seq=\(seq)")
        WindowChurnDetector.shared.noteInvalidate()
        if PrefsAdvanced.debugMode, let idObj = id as? NSObject {
            dumpMirror(idObj, label: "invalidate.id", depth: 3)
        }

        // Last guaranteed moment with a live position for this acquire's
        // renderer — flush so a follow-up cold start resumes close by.
        // Off the XPC thread: the teardown below is grace-deferred, so
        // the renderer is still there when this runs.
        statusWriteQueue.async { flushPlaybackProgress(reason: "invalidate") }

        var cleaned = false
        var uuidStr: String?
        if let idObj = id as? NSObject {
            let idStr = String(describing: Mirror(reflecting: idObj).children.first?.value ?? "")
            if let range = idStr.range(of: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}", options: .regularExpression) {
                let uuid = String(idStr[range])
                uuidStr = uuid
                // Persist the visible frame while the renderer is
                // guaranteed live — same "last moment" rationale as the
                // progress flush above. The debounce collapses this to
                // a no-op when the exit ramp or suspend transition
                // already saved seconds ago.
                persistCurrentFrameToDisk(reason: "invalidate", wid: uuid)
                // Unsubscribe THIS acquire's displayLayer from its
                // SharedRenderer BEFORE releasing refCount + removing
                // the ActiveWallpaper. Teardown is still deferred via
                // a 30s grace timer (quick Space switches won't churn
                // the decoder).
                //
                // If the wallpaper being invalidated was the
                // screensaver, also decrement the renderer's screensaver
                // count BEFORE releasing — order matters: we want the
                // rate to fall back to `nominalRate` while the renderer
                // is still live. Doing it after `releaseRenderer` would
                // race the grace-period teardown.
                // 120 s grace (was 30): quick saver cycles and Space
                // churn now reuse warm pipelines far more often, and a
                // warm reuse is what makes multi-display starts land
                // together. Cold creates are ~0.5 s and snapshot-bridged,
                // so this is a comfort knob, not a correctness one.
                cleaned = teardownWallpaperWindow(wid: uuid, gracePeriod: 120, context: "invalidate")
            }
        }
        debugLog("  invalidated wallpaperID=\(uuidStr ?? "nil") cleaned=\(cleaned) remaining=\(sharedHandlerState.count)")
        // A display unplug arrives as an invalidate with no follow-up
        // acquire for the survivors — re-slice them if the set shrank.
        refreshTopologyAndResliceIfChanged(reason: "invalidate seq=\(seq)")
        dumpTopology(reason: "invalidate seq=\(seq)")
        statusWriteQueue.async { writeWallpaperStatus(reason: "invalidate") }
        reply(nil)
    }

    func snapshot(withId id: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        let seq = nextSeq()
        debugLog("=== SNAPSHOT === seq=\(seq)")
        if PrefsAdvanced.debugMode, let idObj = id as? NSObject {
            dumpMirror(idObj, label: "snapshot.id", depth: 3)
        }

        // Resolve wallpaperID → displayID → SharedRenderer. If we
        // can capture a real frame, save it to disk (for next cold
        // start) AND serve it via IOSurface. Else fall back to either
        // a previously-cached on-disk snapshot or synthetic blue.
        var wallpaperIDString: String?
        if let idObj = id as? NSObject {
            let idStr = String(describing: Mirror(reflecting: idObj).children.first?.value ?? "")
            if let range = idStr.range(of: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}", options: .regularExpression) {
                wallpaperIDString = String(idStr[range])
            }
        }

        let displayID: UInt32? = wallpaperIDString.flatMap { sharedHandlerState.get(wallpaperID: $0)?.displayID }
        let shared: SharedRenderer? = wallpaperIDString.flatMap { sharedHandlerState.renderer(forWallpaperID: $0) }

        Task {
            // Fast path: blit the decoded frame straight into the
            // reply surface (vImage, ~15 ms) — no CIContext render.
            // presentingImageBuffer = exact visible frame while
            // playing; lastDecodedImageBuffer survives deep pause.
            if let renderer = shared?.renderer {
                let buffer = renderer.presentingImageBuffer()
                    ?? (renderer as? VideoRenderer)?.lastDecodedImageBuffer()
                if let buffer, let xpc = makeSnapshotXPC(fromPixelBuffer: buffer) {
                    reply(xpc, nil)
                    debugLog("  Snapshot replied (blit \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)))")
                    // Disk-cache refresh off the critical path; the
                    // buffer retain briefly pins one pool surface.
                    // 3 s-gated: the engage/exit bursts used to stack
                    // several multi-MB rewrites of the same frame.
                    if let did = displayID, shouldRewriteSnapshot(did: did) {
                        DispatchQueue.global(qos: .utility).async {
                            if let cg = bgraCGImage(from: buffer) {
                                writeSnapshot(cg, for: did)
                            }
                        }
                    }
                    return
                }
            }
            // Legacy path (10-bit HDR formats, or no decoded frame yet).
            // Two rungs, neither may wait on the renderer queue: the
            // newest decoded frame via CIContext (mirror read), then the
            // poster-frame generator — a fresh VideoToolbox decode that
            // is skipped while the pump is stuck and raced against a
            // 1.5 s deadline otherwise. WallpaperAgent kills the process
            // when this reply is ~30 s late (2026-09-20 wake bundle), so
            // the disk cache / synthetic rungs below must stay reachable.
            if let renderer = shared?.renderer {
                var captured = renderer.captureFromLastSample()
                if captured == nil, (renderer.pumpBlockedSeconds ?? 0) <= PumpWatchdogPolicy.posterSkipAfter {
                    captured = await withTaskGroup(of: CGImage?.self) { group in
                        group.addTask { await renderer.captureCurrentFrame() }
                        group.addTask {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            return nil
                        }
                        let first = await group.next() ?? nil
                        group.cancelAll()
                        return first
                    }
                }
                if let captured {
                    if let did = displayID, shouldRewriteSnapshot(did: did) {
                        writeSnapshot(captured, for: did)
                    }
                    if let xpc = makeSnapshotXPC(from: captured) {
                        reply(xpc, nil)
                        debugLog("  Snapshot replied (live frame \(captured.width)x\(captured.height))")
                        return
                    }
                }
            }
            // Fallback: previously-saved on-disk snapshot for this display.
            if let did = displayID, let cached = loadCachedSnapshotImage(displayID: did),
               let xpc = makeSnapshotXPC(from: cached) {
                reply(xpc, nil)
                debugLog("  Snapshot replied (cached frame for did=\(did))")
                return
            }
            // Last resort: synthetic blue.
            reply(makeSyntheticBlueSnapshot(), nil)
            debugLog("  Snapshot replied (synthetic blue)")
        }
    }

    /// Snapshot XPC straight from a decoded pixel buffer: vImage-blit
    /// into the reply IOSurface, skipping the ~250 ms 4K CIContext
    /// render (which fired 2-3× inside the first second of every saver
    /// engage). nil for unhandled formats (10-bit HDR) — caller falls
    /// back to the CGImage path.
    private func makeSnapshotXPC(fromPixelBuffer buffer: CVPixelBuffer) -> AnyObject? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let surfaceProps: [IOSurfacePropertyKey: any Sendable] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: 0x4247_5241,  // 'BGRA'
        ]
        guard let surface = IOSurface(properties: surfaceProps) else { return nil }
        surface.lock(options: [], seed: nil)
        let converted = blitBGRA(from: buffer, to: surface.baseAddress, rowBytes: surface.bytesPerRow)
        surface.unlock(options: [], seed: nil)
        guard converted else { return nil }
        return createSnapshotXPC(surface: surface)
    }

    /// Wrap a CGImage in a WallpaperSnapshotXPC via an IOSurface.
    private func makeSnapshotXPC(from image: CGImage) -> AnyObject? {
        let width = image.width
        let height = image.height
        let surfaceProps: [IOSurfacePropertyKey: any Sendable] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: 0x4247_5241,  // 'BGRA'
        ]
        guard let surface = IOSurface(properties: surfaceProps) else { return nil }
        surface.lock(options: [], seed: nil)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let ctx = CGContext(
            data: surface.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: surface.bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        surface.unlock(options: [], seed: nil)
        return createSnapshotXPC(surface: surface)
    }

    /// Fallback: 1024×768 solid blue IOSurface. Returned only when we
    /// have no real frame available.
    private func makeSyntheticBlueSnapshot() -> AnyObject? {
        let width = 1024
        let height = 768
        let surfaceProps: [IOSurfacePropertyKey: any Sendable] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: 0x4247_5241,
        ]
        guard let surface = IOSurface(properties: surfaceProps) else { return nil }
        surface.lock(options: [], seed: nil)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let ctx = CGContext(
            data: surface.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: surface.bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) {
            ctx.setFillColor(aerialBlue)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        surface.unlock(options: [], seed: nil)
        return createSnapshotXPC(surface: surface)
    }


    // MARK: - Debug & Notifications

    func handleDebugRequest(for req: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        debugLog("=== DEBUG REQUEST ===")
        if let obj = req as? NSObject { dumpMirror(obj, label: "debug.req", depth: 4) }
        reply(nil, nil)
    }

    func handleNotification(withNamed name: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        debugLog("handleNotification(\(name ?? "nil"))")
        // hostDidWake fires once per full wake (observed ×26 in a 2-day
        // log) — the exact moment the wake-stall is born: a display's
        // hosted surface stops compositing across the sleep while its
        // layer still reports healthy, so no per-layer detector fires
        // (2026-07-06, did=3 frozen with revived=0). Flush + re-prime +
        // re-register everything, now and again at +2 s once the
        // idle→locked mode churn has settled (the trace shows ~2 s
        // between hostDidWake and the locked updates).
        if String(describing: name ?? "").contains("hostDidWake") {
            recoverAllRenderersAfterWake(reason: "hostDidWake")
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                recoverAllRenderersAfterWake(reason: "hostDidWake+2s")
                // Displays can come back re-numbered after sleep
                // (DisplayLink) — re-slice spanned windows if the set
                // changed. A monitor that attaches even later arrives
                // as its own acquire, which runs the same check.
                refreshTopologyAndResliceIfChanged(reason: "hostDidWake+2s")
                DispatchQueue.main.async { retryAttachForUnfedWindows(reason: "hostDidWake+2s") }
            }
        }
        reply(nil)
    }
}

/// Fan the wake recovery out to every live renderer (each hops to its own
/// queue internally). Module-level so it reaches renderers regardless of
/// which XPC handler instance is current.
func recoverAllRenderersAfterWake(reason: String) {
    for shared in sharedHandlerState.allRenderers() {
        shared.renderer.recoverAllLayers(reason: reason)
    }
}

// Geometry + diagnostics for the wallpaper XPC handler: the spanned
// layer-frame computation (🧭 self-check), the topology dump (🗺 with
// stale/unfed-layer detectors), the 1 Hz saver-session geometry audit
// (📐), and the diagnostic badge attach/remove (🏷️). Split out of
// WallpaperXPCHandler.swift (2026-07-07), verbatim — this is the
// corner-overlap investigation's instrumentation home.

import AppKit
import AVFoundation
import Foundation
import os
import QuartzCore

/// In `.spanned` viewing mode, the per-acquire sample-buffer layer must
/// extend across the union of all active displays, with its origin
/// offset by `-Screen.zeroedOrigin` so the slice that falls inside each
/// display's wallpaper window forms a continuous image across screens.
/// Returns nil when we're not in spanned mode or the screen can't be
/// resolved — caller keeps the default per-display sizing.
///
/// Coord math is NSScreen-based with a bottom-left origin.
func spannedLayerFrame(for displayID: UInt32?) -> CGRect? {
    guard PrefsDisplays.viewingMode == .spanned, let did = displayID else { return nil }
    let detection = DisplayDetection.sharedInstance
    let zRect = detection.getZeroedActiveSpannedRect()
    guard let screen = detection.findScreenWith(id: did) else {
        debugLog("  🧭 spanned did=\(did): screen NOT FOUND in DisplayDetection — falling back to per-display sizing")
        return nil
    }
    let frame = SpannedGeometry.layerFrame(canvas: zRect, zeroedOrigin: screen.zeroedOrigin)
    // Belt for the NaN family: a degenerate detection pass (display
    // detaching mid-enumeration, zero-size canvas, poisoned margins)
    // must fall back to per-display sizing, never reach CALayer —
    // setPosition throws on non-finite values and aborts the extension
    // (2026-08-28 field crash). This is the single choke point every
    // spanned frame consumer goes through.
    guard frame.origin.x.isFinite, frame.origin.y.isFinite,
          frame.width.isFinite, frame.height.isFinite,
          frame.width > 0, frame.height > 0 else {
        debugLog("  🧭 spanned did=\(did): non-finite/empty layerFrame \(frame) (canvas=\(zRect)) — falling back to per-display sizing")
        return nil
    }
    // Self-check trail for the wrong-slice reports: the visible slice is
    // the part of the giant layer that falls inside this screen's window.
    // With the raw frame + zeroedOrigin logged per display, the zeroing
    // math can be verified offline against the user's exact layout —
    // negative-origin screens (left of / below main) are the suspects.
    let slice = SpannedGeometry.visibleSlice(layerFrame: frame, windowSize: screen.bottomLeftFrame.size)
    debugLog("  🧭 spanned did=\(did) raw=\(screen.bottomLeftFrame) zeroedOrigin=\(screen.zeroedOrigin) canvas=\(zRect) layerFrame=\(frame) visibleSlice=\(slice.map { "\($0)" } ?? "NONE (layer misses window!)")")
    return frame
}

/// Log a one-block snapshot of the full module topology: every active
/// wallpaperID with its display/renderer binding, and every live
/// SharedRenderer with its subscriber/rate state. Called after
/// acquire/invalidate, after async renderer install, and on control
/// reconciles — turns any manual test session into a self-documenting
/// lifecycle trace (process identity is the pid= in every line's prefix).
func dumpTopology(reason: String) {
    // Runs on the logging queue, off the calling (XPC / main / control)
    // thread — diagnosticsSnapshot() below queue.syncs into each
    // renderer queue and can momentarily block behind the feed loop,
    // which must never stall an acquire reply.
    extensionDiagnosticsQueue.async {
        let wallpapers = sharedHandlerState.allWallpapers()
        let renderers = sharedHandlerState.allRenderers()
        // presenters= is a leak canary: one ContentsSwapPresenter runs a
        // 60 Hz CVDisplayLink per wallpaper — 22 piled up in the 2026-07
        // Tahoe churn incident (the user-visible 35% CPU spin).
        let presenters = wallpapers.filter { $0.wallpaper.contentsSwapPresenter != nil }.count
        debugLog("🗺 topology (\(reason)): \(wallpapers.count) wallpapers, \(renderers.count) renderers, \(presenters) presenters")
        for (wid, w) in wallpapers.sorted(by: { $0.wid < $1.wid }) {
            debugLog("  🗺 wid=\(wid.prefix(8)) did=\(w.displayID.map(String.init) ?? "nil") key=\(shortKey(w.rendererKey)) saver=\(w.isScreenSaver) preview=\(w.isPreview) variant=\(w.experimentVariant) mode=\(w.lastPresentationMode) overlay=\(w.overlayDriver != nil) presenter=\(w.contentsSwapPresenter != nil)")
        }
        for shared in renderers.sorted(by: { $0.rendererKey < $1.rendererKey }) {
            debugLog("  🗺 renderer key=\(shortKey(shared.rendererKey)) refCount=\(shared.refCount) video=\(shared.videoURL.lastPathComponent) \(shared.renderer.diagnosticsSnapshot())")
        }
        // Stale/unfed layer detector: every window's hosted layer must be
        // fed by the renderer its key names. A layer fed by a DIFFERENT
        // renderer is a re-key leftover (live "second video" candidate);
        // a layer fed by nobody renders whatever frame it last got —
        // frozen content. Transient one-shots right after an acquire are
        // benign (subscribe is async); repeated hits are the bug.
        for (wid, w) in wallpapers {
            guard let layer = w.displayLayer else { continue }
            if let owner = renderers.first(where: { $0.renderer.feedsLayer(layer) }) {
                if owner.rendererKey != w.rendererKey {
                    debugLog("  ⚠️ stale layer: wid=\(wid.prefix(8)) hosts a layer fed by key=\(shortKey(owner.rendererKey)) but window key=\(shortKey(w.rendererKey))")
                }
            } else {
                debugLog("  ⚠️ unfed layer: wid=\(wid.prefix(8)) key=\(shortKey(w.rendererKey)) — no live renderer feeds its layer (frozen)")
            }
        }
        for shared in renderers {
            let windowCount = wallpapers.filter { $0.wallpaper.rendererKey == shared.rendererKey }.count
            let subs = shared.renderer.subscriberCount
            if subs != windowCount {
                debugLog("  ⚠️ subscriber mismatch key=\(shortKey(shared.rendererKey)): \(subs) subscriber layer(s) vs \(windowCount) window(s)")
            }
        }
    }
}

// MARK: - Saver-session layer-geometry audit

/// Timestamp of the last saver-fallback OFF transition — feeds the
/// reuse beacon in `setNotificationScreensaver`. Main-queue only (the
/// distributed-notification observers deliver on .main).
nonisolated(unsafe) var lastSaverStopAt: Date?

/// Last audit block we logged; the audit re-logs only on change so an
/// idle saver session costs one block, not one per second.
private nonisolated(unsafe) var lastGeometryAuditSignature = ""

/// 1 s layer-geometry audit, active only while a saver window exists or
/// the saver-mode fallback is on. Dumps OUR side of every hosted layer
/// tree — root frame/scale/transform, each sublayer's class+frame — so
/// a mis-sized/mis-transformed tree or a leftover sublayer (ghost,
/// re-key remnant) shows up in the log with geometry attached. Runs on
/// main (layers are touched from main elsewhere); logs only on change.
let geometryAuditTimer: DispatchSourceTimer = {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
    timer.setEventHandler { auditLayerGeometry() }
    return timer
}()

private func rectDesc(_ r: CGRect) -> String {
    String(format: "(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.width, r.height)
}

/// One layer's audit entry. `r` marks an actually-rasterized layer
/// (variant C's container as applied, not just as selected), and
/// rasterized containers get one level of recursion — variant C nests
/// the video layer inside the container, and the audit's whole point is
/// the video layer's frame + renderer health.
private func auditLayerDesc(_ sub: CALayer) -> String {
    let cls = String(describing: type(of: sub))
    let short = cls.replacingOccurrences(of: "AVSampleBufferDisplayLayer", with: "Video")
    // Surface renderer sickness inline: a FAILED renderer is the
    // frozen-window mechanism (drops enqueues silently), so tester
    // logs can tie the frozen surface to its layer directly.
    var health = ""
    if let av = sub as? AVSampleBufferDisplayLayer {
        let r = av.sampleBufferRenderer
        if r.status == .failed { health += " st=FAILED" }
        if r.requiresFlushToResumeDecoding { health += " needsFlush" }
    }
    var desc = "\(short)\(rectDesc(sub.frame))\(sub.shouldRasterize ? "r" : "")\(health)\(sub.isHidden ? " HIDDEN" : "")\(sub.opacity < 1 ? String(format: " a=%.2f", sub.opacity) : "")"
    if sub.shouldRasterize, let children = sub.sublayers, !children.isEmpty {
        desc += "[" + children.map(auditLayerDesc).joined(separator: " ") + "]"
    }
    return desc
}

private func auditLayerGeometry() {
    let wallpapers = sharedHandlerState.allWallpapers()
    let saverActive = sharedHandlerState.isNotificationScreensaverActive
        || wallpapers.contains { $0.wallpaper.isScreenSaver }
    guard saverActive else {
        lastGeometryAuditSignature = ""
        return
    }
    var lines: [String] = []
    for (wid, w) in wallpapers.sorted(by: { $0.wid < $1.wid }) {
        let root = w.rootLayer
        let t = root.transform
        let tDesc = CATransform3DIsIdentity(t)
            ? "id"
            : String(format: "[%.3f %.3f tx=%.1f ty=%.1f]", t.m11, t.m22, t.m41, t.m42)
        let subs = (root.sublayers ?? []).map(auditLayerDesc).joined(separator: " ")
        // contents= : whether the root carries the defensive-prime
        // snapshot — the "background pane" that shows through wherever
        // a mis-scaled AVSBDL surface leaves the video layer transparent
        // (the beta3 overlap photo's second half).
        lines.append("📐 #\(w.acquireSeq) wid=\(wid.prefix(8)) did=\(w.displayID.map(String.init) ?? "nil") saver=\(w.isScreenSaver) preview=\(w.isPreview) variant=\(w.experimentVariant) root=\(rectDesc(root.frame))@\(root.contentsScale) contents=\(root.contents == nil ? "nil" : "set") t=\(tDesc) subs=[\(subs)]")
    }
    let signature = lines.joined(separator: "\n")
    guard signature != lastGeometryAuditSignature else { return }
    lastGeometryAuditSignature = signature
    debugLog("📐 geometry audit (\(wallpapers.count) windows):")
    for line in lines { debugLog("  \(line)") }
}

/// Attach or remove the diagnostic badge on one wallpaper according to
/// the current `PrefsAdvanced.showDiagnosticBadges` setting. Idempotent
/// — always clears any existing badge first, so it doubles as the
/// removal path when the toggle goes off. Runs on the caller's thread
/// (same threads that build the rest of the tree).
func applyDiagnosticBadge(to wallpaper: ActiveWallpaper, wid: String) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    wallpaper.debugBadge?.removeFromSuperlayer()
    wallpaper.debugBadge = nil
    if PrefsAdvanced.showDiagnosticBadges {
        // "P" outranks "S": a Settings preview of the saver is still a
        // preview window — the letter tells photos which composite path
        // (thumbnail vs fullscreen) the badge lives in.
        let role = wallpaper.isPreview ? "P" : (wallpaper.isScreenSaver ? "S" : "W")
        let badge = DebugBadgeLayer.make(
            seq: wallpaper.acquireSeq,
            role: role,
            did: wallpaper.displayID,
            wid: wid,
            size: wallpaper.lastDestination.size,
            contentsScale: wallpaper.lastDestination.scaleFactor,
            variant: wallpaper.experimentVariant
        )
        wallpaper.rootLayer.addSublayer(badge)
        wallpaper.debugBadge = badge
        debugLog("  🏷️ badge #\(wallpaper.acquireSeq) wid=\(wid.prefix(8)) role=\(wallpaper.isPreview ? "preview" : (wallpaper.isScreenSaver ? "saver" : "wallpaper")) did=\(wallpaper.displayID.map(String.init) ?? "nil") variant=\(wallpaper.experimentVariant)")
    }
    CATransaction.commit()
}

// MARK: - Variant D: contents-swap presenter

/// Variant D (contents-swap, the production default): mirrors the
/// renderer's presenting frame into a plain CALayer's `contents` at
/// 30 Hz, so the window's serialized layer tree carries NO
/// AVSampleBufferDisplayLayer node for WallpaperAgent's video-surface
/// special-casing to detach (the VM miniature repro proved the agent
/// detaches the AVSBDL even from inside the retired variant C's
/// rasterized container). The window's AVSBDL still exists as an
/// off-tree orphan subscriber — it keeps driving the renderer's
/// requestMediaDataWhenReady pump and pacing, so the playback engine is
/// untouched.
///
/// Presentation correctness rides the renderer's presenting ring /
/// live bridge (timebase pick), so pause/rate/loops need no handling
/// here — an unchanged frame is skipped by identity. HDR: no EDR
/// negotiation (plain contents) — which is why HDR formats auto-select
/// variant A (plain AVSBDL) instead.
///
/// Pacing: a per-display CVDisplayLink at the display's native refresh.
/// CVDisplayLink is soft-deprecated (macOS 15) but is the only
/// AppKit-free vsync source available here — the modern NSScreen/NSView
/// display links need live AppKit state, and the appex's NSScreen data
/// is frozen at first access (no NSApplication run loop). Falls back to
/// a 60 Hz timer when the link can't be created. Ticks are coalesced
/// onto main (the CV callback thread must not touch layers directly).
///
/// Idle downshift: the vsync tick pays a cross-queue hop into the
/// renderer even when nothing changes, so a paused wallpaper burned a
/// constant ~1% CPU per window. After ~2 s of identical frames the
/// vsync source is parked and a 1 Hz poll takes over; any changed frame
/// (or an explicit `wake()` from the resume/jump paths) restores the
/// vsync source. The poll makes staleness self-healing — a missed wake
/// costs at most 1 s of latency, never a stuck frame. Leaked presenters
/// on agent-abandoned windows (the Tahoe churn pile-up) idle the same
/// way instead of spinning at 60 Hz forever.
final class ContentsSwapPresenter {
    /// Unchanged ticks before parking the vsync source (~2 s at 60 Hz).
    private static let idleThreshold = 120

    private var displayLink: CVDisplayLink?
    private var fastTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    private weak var layer: CALayer?
    private weak var renderer: (any PlaybackRenderer)?
    private let wid: String
    /// Strong ref to the displayed buffer — `contents` holds the
    /// IOSurface, not the CVPixelBuffer that owns it. Main-only.
    private var presented: CVPixelBuffer?
    /// Main-only state machine: consecutive no-change ticks and whether
    /// the presenter is parked on the 1 Hz idle poll.
    private var unchangedTicks = 0
    private var isIdle = false
    private var stopped = false
    /// Coalesces display-link callbacks: at most one presentation block
    /// in flight on main, so a busy main queue never accumulates ticks.
    private let tickPending = OSAllocatedUnfairLock(initialState: false)

    init(layer: CALayer, renderer: any PlaybackRenderer, wid: String, displayID: UInt32?) {
        self.layer = layer
        self.renderer = renderer
        self.wid = wid

        var link: CVDisplayLink?
        if let did = displayID {
            CVDisplayLinkCreateWithCGDisplay(did, &link)
        }
        if let link {
            let pending = tickPending
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                let alreadyQueued = pending.withLock { queued -> Bool in
                    if queued { return true }
                    queued = true
                    return false
                }
                if !alreadyQueued {
                    DispatchQueue.main.async {
                        pending.withLock { $0 = false }
                        self?.tick()
                    }
                }
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(link)
            displayLink = link
            debugLog("  🧪 contents-swap presenter started (display link did=\(displayID ?? 0)) wid=\(wid.prefix(8))")
        } else {
            startFastTimer()
            debugLog("  🧪 contents-swap presenter started (60 Hz fallback) wid=\(wid.prefix(8))")
        }
    }

    /// Main-only. Mirror the presenting frame if it changed; otherwise
    /// advance the unchanged streak that parks the vsync source.
    private func tick() {
        guard !stopped else { return }
        if let layer, let renderer,
           let buffer = renderer.presentingImageBuffer(),
           buffer !== presented,
           let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
            presented = buffer
            unchangedTicks = 0
            if isIdle { upshift() }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = surface
            CATransaction.commit()
        } else if !isIdle {
            unchangedTicks += 1
            if unchangedTicks >= Self.idleThreshold { downshift() }
        }
    }

    /// Any-thread. Kick an idle presenter back to vsync ahead of
    /// expected frame changes (resume/jump/saver engage) so the mirror
    /// doesn't spend its first second at the 1 Hz poll rate. Missing a
    /// wake path is safe — the poll catches the change within 1 s.
    func wake() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped, self.isIdle else { return }
            self.upshift()
        }
    }

    /// Main-only. Park the vsync source; a 1 Hz poll keeps watching.
    private func downshift() {
        isIdle = true
        unchangedTicks = 0
        if let displayLink { CVDisplayLinkStop(displayLink) }
        fastTimer?.cancel()
        fastTimer = nil
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        idleTimer = timer
        debugLog("  🧪 presenter idle (1 Hz poll) wid=\(wid.prefix(8))")
    }

    /// Main-only. Restore the vsync source after idling.
    private func upshift() {
        isIdle = false
        unchangedTicks = 0
        idleTimer?.cancel()
        idleTimer = nil
        if let displayLink {
            CVDisplayLinkStart(displayLink)
        } else {
            startFastTimer()
        }
        debugLog("  🧪 presenter wake (vsync) wid=\(wid.prefix(8))")
    }

    private func startFastTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        fastTimer = timer
    }

    func stop() {
        stopped = true
        if let displayLink {
            CVDisplayLinkStop(displayLink)
            self.displayLink = nil
        }
        fastTimer?.cancel()
        fastTimer = nil
        idleTimer?.cancel()
        idleTimer = nil
        presented = nil
    }

    deinit {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        fastTimer?.cancel()
        idleTimer?.cancel()
    }
}

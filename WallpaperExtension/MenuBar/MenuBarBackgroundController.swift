//
//  MenuBarBackgroundController.swift
//  Aerial4WallpaperExtension
//
//  Owns the "Menu bar background" band on every window: whether it
//  exists (`MenuBarBackgroundRule`), how big it is (menu bar geometry
//  relayed by Companion — the appex's own NSScreen is frozen), and its
//  colour (white, black, or sampled once per video at the visible cut)
//  or picture (the blur styles: a tinted blur of what is behind the bar,
//  refreshed about once a second while the picture changes).
//  The handler only calls in here; nothing in the render path knows the
//  band exists.
//

import AVFoundation
import os
import QuartzCore

enum MenuBarBackgroundController {

    /// Last sampled band colour per renderer key ("Color from video"). A
    /// broadcast renderer shares one colour across its windows.
    private static let videoColors = OSAllocatedUnfairLock<[String: CGColor]>(initialState: [:])

    private static let sampleQueue = DispatchQueue(label: "aerial-menubar-sample", qos: .utility)

    /// A renderer that hasn't presented its first frame yet is re-sampled
    /// this many times, one second apart.
    private static let sampleRetries = 3

    private static let white = CGColor(gray: 1, alpha: 1)
    private static let black = CGColor(gray: 0, alpha: 1)

    // MARK: Blur state (handler queue only)

    /// Refresh interval of the blur styles, and the cross-fade between
    /// two images — kept under the interval so fades never overlap.
    private static let blurInterval: TimeInterval = 1
    private static let blurFade: CFTimeInterval = 0.9

    /// What a window's band last rendered from; an unchanged stamp (video
    /// paused, same geometry and tint) skips the render.
    private struct BlurStamp: Equatable {
        let buffer: ObjectIdentifier
        let source: CGRect
        let scale: Double
        let bias: Double
        let blur: Double
    }

    private static var blurTicker: DispatchSourceTimer?
    private static var blurStamps: [String: BlurStamp] = [:]

    /// Attach, re-frame, re-colour or remove the band on one window.
    /// Idempotent. Handler queue only (it edits the root tree and the
    /// window's mirror).
    static func apply(to wallpaper: ActiveWallpaper, wid: String) {
        assertHandlerQueue("MenuBarBackgroundController.apply")
        let state = wallpaper.mirror
        let listener = WallpaperControlListener.shared
        let style = listener.currentMenuBarBackground
        let uuid = state.displayID.map { DisplayDetection.displayUUID(for: $0) } ?? ""
        let geometry = listener.currentMenuBarGeometry[uuid] ?? .none
        let show = MenuBarBackgroundRule.shouldShow(
            style: style,
            menuBarHeight: Double(geometry.height),
            isScreenSaver: wallpaper.isScreenSaver,
            isPreview: wallpaper.isPreview,
            saverExcluded: state.saverExcluded,
            saverFallbackActive: sharedHandlerState.isNotificationScreensaverActive,
            presentationMode: state.lastPresentationMode
        )

        guard show else {
            guard let band = state.menuBarBand else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            band.removeFromSuperlayer()
            CATransaction.commit()
            wallpaper.mutate { $0.menuBarBand = nil }
            blurStamps[wid] = nil
            debugLog("🎚️ [MenuBar] band off wid=\(wid.prefix(8)) style=\(style.rawValue) mode=\(state.lastPresentationMode) height=\(geometry.height)")
            return
        }

        let color: CGColor
        switch style {
        case .white: color = white
        case .videoColor:
            if let sampled = videoColors.withLock({ $0[state.rendererKey] }) {
                color = sampled
            } else {
                color = black
                if let shared = sharedHandlerState.renderer(forWallpaperID: wid) {
                    sample(rendererKey: shared.rendererKey, renderer: shared.renderer, reason: "apply")
                }
            }
        case .lightBlur, .darkBlur:
            // Shown until the first image lands: the tint over mid-grey.
            let tint = MenuBarBackgroundRule.blurTint(
                style: style, strength: MenuBarBackgroundRule.blurStrength(listener.currentMenuBarBlurStrength))
            color = CGColor(gray: tint.scale * 0.5 + tint.bias, alpha: 1)
        default: color = black
        }

        let size = state.lastDestination.size
        let scale = state.lastDestination.scaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let band = state.menuBarBand {
            band.resize(to: size, height: geometry.height, contentsScale: scale)
            if band.backgroundColor != color { band.setColor(color, animated: false) }
            if !style.isBlur {
                band.clearImage()
                blurStamps[wid] = nil
            }
            CATransaction.commit()
            if style.isBlur { startBlurTicker() }
            return
        }
        let band = MenuBarBackgroundLayer.make(size: size, height: geometry.height,
                                               contentsScale: scale, color: color)
        wallpaper.rootLayer.addSublayer(band)
        CATransaction.commit()
        wallpaper.mutate { $0.menuBarBand = band }
        blurStamps[wid] = nil
        if style.isBlur { startBlurTicker() }
        debugLog("🎚️ [MenuBar] band on wid=\(wid.prefix(8)) style=\(style.rawValue) height=\(geometry.height) notch=\(geometry.hasNotch) size=\(Int(size.width))x\(Int(size.height))")
    }

    /// Re-apply to every window — style or geometry changed, or the
    /// saver fallback flipped. Safe from any thread.
    static func applyAll(reason: String) {
        handlerQueue.async {
            let wallpapers = sharedHandlerState.allWallpapers()
            debugLog("🎚️ [MenuBar] apply all (\(reason)) → \(wallpapers.count) window(s)")
            for (wid, wallpaper) in wallpapers {
                apply(to: wallpaper, wid: wid)
            }
        }
    }

    /// The renderer's picture just cut to a new video: re-sample its
    /// colour (or blur) and fade every band on that renderer to it.
    /// No-op for the fixed styles. Safe from any thread.
    static func videoDidChange(rendererKey: String, renderer: any PlaybackRenderer, reason: String) {
        let style = WallpaperControlListener.shared.currentMenuBarBackground
        if style == .videoColor {
            sample(rendererKey: rendererKey, renderer: renderer, reason: reason)
        } else if style.isBlur {
            // Don't wait for the next tick: the old video's blur would linger.
            handlerQueue.async {
                refreshBlur(fade: MenuBarBackgroundLayer.colorFadeSeconds, onlyRendererKey: rendererKey)
            }
        }
    }

    // MARK: Blur styles

    /// Start the refresh timer (no-op when running) and render once right
    /// away so a new band or a new tint doesn't wait a full interval.
    private static func startBlurTicker() {
        assertHandlerQueue("MenuBarBackgroundController.startBlurTicker")
        handlerQueue.async { refreshBlur(fade: 0.15) }
        guard blurTicker == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: handlerQueue)
        timer.schedule(deadline: .now() + blurInterval, repeating: blurInterval, leeway: .milliseconds(100))
        timer.setEventHandler { refreshBlur(fade: blurFade) }
        timer.resume()
        blurTicker = timer
        debugLog("🎚️ [MenuBar] blur ticker on")
    }

    private static func stopBlurTicker() {
        guard let timer = blurTicker else { return }
        timer.cancel()
        blurTicker = nil
        blurStamps.removeAll()
        debugLog("🎚️ [MenuBar] blur ticker off")
    }

    /// One pass over the blur bands: for every window whose presenting
    /// frame, geometry or tint changed, render a new image off-queue and
    /// fade the band to it. Stops the ticker when no blur band is left.
    private static func refreshBlur(fade: CFTimeInterval, onlyRendererKey: String? = nil) {
        assertHandlerQueue("MenuBarBackgroundController.refreshBlur")
        let listener = WallpaperControlListener.shared
        let style = listener.currentMenuBarBackground
        guard style.isBlur else { stopBlurTicker(); return }
        let tint = MenuBarBackgroundRule.blurTint(
            style: style, strength: MenuBarBackgroundRule.blurStrength(listener.currentMenuBarBlurStrength))
        let blur = MenuBarBackgroundRule.blurWidthFraction(
            amount: MenuBarBackgroundRule.blurAmount(listener.currentMenuBarBlurAmount))

        var bands = 0
        for (wid, wallpaper) in sharedHandlerState.allWallpapers() {
            let state = wallpaper.mirror
            guard let band = state.menuBarBand else { continue }
            bands += 1
            if let onlyRendererKey, state.rendererKey != onlyRendererKey { continue }
            // The presenting ring is empty in deep pause; the newest decoded
            // frame survives it, so a restyle while paused still has a picture.
            let renderer = sharedHandlerState.renderer(forWallpaperID: wid)?.renderer
            guard let buffer = renderer?.presentingImageBuffer()
                    ?? (renderer as? VideoRenderer)?.lastDecodedImageBuffer(),
                  let source = sourceRect(for: band, in: wallpaper, buffer: buffer) else {
                // No picture at all: don't leave an image with the old tint
                // over the new base colour.
                if let old = blurStamps[wid], old.scale != tint.scale || old.bias != tint.bias {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    band.clearImage()
                    CATransaction.commit()
                    blurStamps[wid] = nil
                }
                continue
            }
            let stamp = BlurStamp(buffer: ObjectIdentifier(buffer), source: source,
                                  scale: tint.scale, bias: tint.bias, blur: blur)
            guard blurStamps[wid] != stamp else { continue }
            blurStamps[wid] = stamp

            sampleQueue.async {
                guard let image = MenuBarBlurSampler.image(from: buffer, sourceRect: source,
                                                                 blurFraction: blur, tint: tint) else {
                    debugLog("🎚️ [MenuBar] blur render failed wid=\(wid.prefix(8))")
                    return
                }
                handlerQueue.async {
                    // The band may have been removed, replaced or switched
                    // to another style while the image rendered.
                    guard wallpaper.mirror.menuBarBand === band,
                          WallpaperControlListener.shared.currentMenuBarBackground == style else { return }
                    // Explicit transaction: this queue has no run loop, so an
                    // implicit one would only reach the screen with the next
                    // unrelated commit (never, while the video is paused).
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    band.setImage(image, fade: fade)
                    CATransaction.commit()
                }
            }
        }
        if bands == 0 { stopBlurTicker() }
    }

    /// The frame region behind `band`, from the video host layer's frame
    /// and scaling (the contents-swap layer, or the display layer on the
    /// HDR path).
    private static func sourceRect(for band: MenuBarBackgroundLayer, in wallpaper: ActiveWallpaper,
                                   buffer: CVPixelBuffer) -> CGRect? {
        let layerFrame: CGRect
        let gravity: MenuBarBandGravity
        if let swap = wallpaper.contentsSwapLayer {
            layerFrame = swap.frame
            switch swap.contentsGravity {
            case .resizeAspect: gravity = .fit
            case .resize: gravity = .stretch
            default: gravity = .fill
            }
        } else {
            layerFrame = wallpaper.displayLayer.frame
            switch wallpaper.displayLayer.videoGravity {
            case .resizeAspect: gravity = .fit
            case .resize: gravity = .stretch
            default: gravity = .fill
            }
        }
        return MenuBarBackgroundRule.sourceRect(
            bandRect: band.frame, windowSize: wallpaper.rootLayer.bounds.size,
            layerFrame: layerFrame, gravity: gravity,
            imageSize: CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
    }

    private static func sample(rendererKey: String, renderer: any PlaybackRenderer,
                               reason: String, attempt: Int = 0) {
        let buffer = renderer.presentingImageBuffer()
            ?? (renderer as? VideoRenderer)?.lastDecodedImageBuffer()
        sampleQueue.async { [weak renderer] in
            guard let buffer else {
                guard attempt < sampleRetries, let renderer else { return }
                sampleQueue.asyncAfter(deadline: .now() + 1) {
                    sample(rendererKey: rendererKey, renderer: renderer, reason: reason, attempt: attempt + 1)
                }
                return
            }
            guard let color = MenuBarColorSampler.color(from: buffer) else {
                debugLog("🎚️ [MenuBar] sample failed key=\(shortKey(rendererKey)) (\(reason))")
                return
            }
            videoColors.withLock { $0[rendererKey] = color }
            debugLog("🎚️ [MenuBar] colour \(describe(color)) key=\(shortKey(rendererKey)) (\(reason))")
            handlerQueue.async {
                CATransaction.begin()
                for (_, wallpaper) in sharedHandlerState.allWallpapers()
                where wallpaper.mirror.rendererKey == rendererKey {
                    wallpaper.mirror.menuBarBand?.setColor(color, animated: true)
                }
                CATransaction.commit()
            }
        }
    }

    private static func describe(_ color: CGColor) -> String {
        (color.components ?? []).prefix(3).map { String(format: "%.2f", $0) }.joined(separator: ",")
    }
}

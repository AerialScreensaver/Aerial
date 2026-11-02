//
//  MenuBarBackgroundController.swift
//  Aerial4WallpaperExtension
//
//  Owns the "Menu bar background" band on every window: whether it
//  exists (`MenuBarBackgroundRule`), how big it is (menu bar geometry
//  relayed by Companion — the appex's own NSScreen is frozen), and its
//  colour (white, black, or sampled once per video at the visible cut).
//  The handler only calls in here; nothing in the render path knows the
//  band exists.
//

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
        default: color = black
        }

        let size = state.lastDestination.size
        let scale = state.lastDestination.scaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let band = state.menuBarBand {
            band.resize(to: size, height: geometry.height, contentsScale: scale)
            if band.backgroundColor != color { band.setColor(color, animated: false) }
            CATransaction.commit()
            return
        }
        let band = MenuBarBackgroundLayer.make(size: size, height: geometry.height,
                                               contentsScale: scale, color: color)
        wallpaper.rootLayer.addSublayer(band)
        CATransaction.commit()
        wallpaper.mutate { $0.menuBarBand = band }
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
    /// colour and fade every band on that renderer to it. No-op unless
    /// the style is "Color from video". Safe from any thread.
    static func videoDidChange(rendererKey: String, renderer: any PlaybackRenderer, reason: String) {
        guard WallpaperControlListener.shared.currentMenuBarBackground == .videoColor else { return }
        sample(rendererKey: rendererKey, renderer: renderer, reason: reason)
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

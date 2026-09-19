//
//  NoVideoFallbackLayer.swift
//  Aerial4WallpaperExtension
//
//  The "no videos" fallback: a colour-cycling background plus a centred
//  "No videos found…" label, shown on a window whose acquire found
//  nothing playable (empty cache on a fresh install, a wiped cache, a
//  playlist that resolves to nothing). Port of AerialSaverView's
//  startColorAnimation()/showFallbackLabel() from the 4.0 saver to this
//  CALayer-only appex: same six Apple-rainbow hues, same 1 s hold +
//  2 s fade cadence, same text. Before this the window sat on the solid
//  Aerial-blue root layer (or a stale primed snapshot) for ever.
//
//  Differences that matter here:
//  - The cycle is ONE repeating CAKeyframeAnimation owned by the render
//    server — no timer, no main-thread work in the appex, and it keeps
//    running even if our process is paused.
//  - `timeOffset` phase-locks every window to wall-clock time so
//    spanned/cloned displays cycle in step.
//  - The label is a CATextLayer with an explicit contentsScale (the
//    DebugBadgeLayer recipe) — there is no NSView to host a text field.
//
//  Attached/removed by WallpaperXPCHandler (showNoVideoFallback /
//  hideNoVideoFallback); `retryAttachForUnfedWindows` swaps it out for
//  real playback as soon as something becomes playable.
//

import AppKit
import QuartzCore

final class NoVideoFallbackLayer: CALayer {

    /// Same wording as the 4.0 saver (neither target ships a strings table).
    static let message = "No videos found, please check your settings or download videos in Aerial.app"

    /// The one "no videos" case the user cannot fix from the extension's
    /// side: a plain cache folder outside /Users/Shared (external drive or
    /// home folder), which this sandboxed process can never read.
    /// Companion offers the conversion.
    static let externalDriveMessage = "Your video cache is in a folder the wallpaper can't read. Open Aerial and follow the prompt to move it into a disk image (Settings › Cache)."

    /// What the label says; set once by `make`.
    private var messageText: String = NoVideoFallbackLayer.message

    /// Six hues from the original (1977–1998) Apple rainbow logo,
    /// top-to-bottom: green, yellow, orange, red, purple, blue.
    static let palette: [CGColor] = [
        NSColor(srgbRed: 0x61 / 255.0, green: 0xBB / 255.0, blue: 0x46 / 255.0, alpha: 1).cgColor,
        NSColor(srgbRed: 0xFD / 255.0, green: 0xB8 / 255.0, blue: 0x27 / 255.0, alpha: 1).cgColor,
        NSColor(srgbRed: 0xF5 / 255.0, green: 0x82 / 255.0, blue: 0x1F / 255.0, alpha: 1).cgColor,
        NSColor(srgbRed: 0xE0 / 255.0, green: 0x3A / 255.0, blue: 0x3E / 255.0, alpha: 1).cgColor,
        NSColor(srgbRed: 0x96 / 255.0, green: 0x3D / 255.0, blue: 0x97 / 255.0, alpha: 1).cgColor,
        NSColor(srgbRed: 0x00 / 255.0, green: 0x9D / 255.0, blue: 0xDC / 255.0, alpha: 1).cgColor,
    ]

    /// Per hue: flat for `holdSeconds`, then cross-fade to the next over
    /// `fadeSeconds` (the saver's 3 s timer + 2 s CABasicAnimation).
    static let holdSeconds: Double = 1.0
    static let fadeSeconds: Double = 2.0

    private static let labelInset: CGFloat = 32
    private static let labelFontSize: CGFloat = 22

    private let label = CATextLayer()

    /// Build a fallback covering `size` (the window/rootLayer bounds).
    static func make(size: CGSize, contentsScale: CGFloat,
                     message: String = NoVideoFallbackLayer.message) -> NoVideoFallbackLayer {
        let layer = NoVideoFallbackLayer()
        layer.messageText = message
        layer.frame = CGRect(origin: .zero, size: size).sanitized("fallback layer")
        layer.contentsScale = contentsScale
        layer.isOpaque = true
        // Above the (empty) video/swap layers and the primed root
        // contents, below the diagnostic badge at 10 000. Sibling
        // overlays sit at 0, so the label covers them — same as the
        // saver, where the label is the topmost subview.
        layer.zPosition = 1_000
        layer.backgroundColor = palette.first
        layer.installColorCycle()
        layer.installLabel(size: size, contentsScale: contentsScale)
        return layer
    }

    /// Keyframe schedule for the colour cycle: each hue holds for `hold`
    /// then fades to the next over `fade`; the last fades back to the
    /// first so the loop is seamless. 2n+1 values, keyTimes in 0…1.
    static func keyframes(colors: [CGColor], hold: Double, fade: Double)
        -> (values: [CGColor], keyTimes: [NSNumber], duration: Double) {
        guard let first = colors.first else { return ([], [], 0) }
        let step = hold + fade
        let duration = Double(colors.count) * step
        var values: [CGColor] = []
        var keyTimes: [NSNumber] = []
        for (index, color) in colors.enumerated() {
            let start = Double(index) * step
            values.append(color)
            keyTimes.append(NSNumber(value: start / duration))
            values.append(color)
            keyTimes.append(NSNumber(value: (start + hold) / duration))
        }
        values.append(first)
        keyTimes.append(NSNumber(value: 1.0))
        return (values, keyTimes, duration)
    }

    /// Re-frame after a destination change (resolution / scale / spanned
    /// re-layout keeps the fallback full-window on purpose).
    func resize(to size: CGSize, contentsScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = CGRect(origin: .zero, size: size).sanitized("fallback resize")
        self.contentsScale = contentsScale
        label.contentsScale = contentsScale
        layoutLabel(size: size)
        CATransaction.commit()
    }

    // MARK: - Pieces

    private func installColorCycle() {
        let schedule = Self.keyframes(colors: Self.palette, hold: Self.holdSeconds, fade: Self.fadeSeconds)
        let cycle = CAKeyframeAnimation(keyPath: "backgroundColor")
        cycle.values = schedule.values
        cycle.keyTimes = schedule.keyTimes
        cycle.duration = schedule.duration
        cycle.calculationMode = .linear
        cycle.repeatCount = .infinity
        cycle.isRemovedOnCompletion = false
        // Phase-lock to wall-clock time: every window that starts this
        // animation shows the same hue at the same instant, whatever its
        // acquire time (spanned / cloned displays cycle together).
        cycle.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: schedule.duration)
        add(cycle, forKey: "noVideoColorCycle")
    }

    private func installLabel(size: CGSize, contentsScale: CGFloat) {
        label.contentsScale = contentsScale
        label.alignmentMode = .center
        label.isWrapped = true
        label.truncationMode = .none
        label.string = attributedMessage()
        // NSShadow(black 0.6, blur 6, offset (0,-1)) on the saver's label.
        label.shadowColor = CGColor(gray: 0, alpha: 1)
        label.shadowOpacity = 0.6
        label.shadowRadius = 6
        label.shadowOffset = CGSize(width: 0, height: -1)
        addSublayer(label)
        layoutLabel(size: size)
    }

    private func attributedMessage() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: messageText, attributes: [
            .font: NSFont.systemFont(ofSize: Self.labelFontSize, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])
    }

    /// Centre the label with ≥`labelInset` on each side, wrapping to as
    /// many lines as the width needs (y-up layer coordinates).
    private func layoutLabel(size: CGSize) {
        let width = max(size.width - Self.labelInset * 2, 100)
        let measured = attributedMessage().boundingRect(
            with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = ceil(measured.height) + 4
        let labelFrame = CGRect(x: (size.width - width) / 2,
                                y: (size.height - height) / 2,
                                width: width,
                                height: height)
        label.frame = labelFrame.sanitized("fallback label")
    }
}

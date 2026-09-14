//
//  DebugBadgeLayer.swift
//  Aerial4WallpaperExtension
//
//  Diagnostic instance badge for the corner-overlap / frozen-window
//  investigation. Attached to an instance's rootLayer (so it inherits
//  whatever the hosting side does to our tree) and designed so a single
//  tester photo answers three questions at once:
//
//  - WHICH instance is this window? — the center chip carries the
//    acquire seq + role + displayID, on a background hue hashed from
//    the wallpaperID (visually unique per instance).
//  - Was the tree SCALED or CROPPED by the host? — four fixed-color
//    corner squares (TL red, TR green, BL blue, BR yellow, identical on
//    every window): a small window showing all four = the whole tree
//    was scaled; only some = we're seeing a crop/offset.
//  - Is compositing ALIVE? — the chip's counter ticks once per second.
//    Counter ticking over frozen video = the surface composites and the
//    stall is in the video presentation path (our side). Counter frozen
//    too = WindowServer isn't compositing this surface at all
//    (agent-side).
//

import Foundation
import QuartzCore

final class DebugBadgeLayer: CALayer {
    private static let cornerSize: CGFloat = 48
    private static let chipSize = CGSize(width: 360, height: 120)

    /// All live badges, ticked by the shared 1 Hz timer. Weak so a badge
    /// removed with its tree just drops out. Main-queue only.
    nonisolated(unsafe) private static let liveBadges = NSHashTable<DebugBadgeLayer>.weakObjects()

    nonisolated(unsafe) private static var tickTimer: DispatchSourceTimer?   // main-queue only, see above

    private let counterLayer = CATextLayer()
    private let createdAt = CFAbsoluteTimeGetCurrent()

    /// Build a badge covering `size` (the window/rootLayer bounds).
    /// Call on whatever thread owns the layer tree; registration for
    /// ticking hops to main.
    static func make(
        seq: UInt64,
        role: String,
        did: UInt32?,
        wid: String,
        size: CGSize,
        contentsScale: CGFloat,
        variant: String = "D"
    ) -> DebugBadgeLayer {
        let badge = DebugBadgeLayer()
        badge.frame = CGRect(origin: .zero, size: size).sanitized("badge frame")
        badge.zPosition = 10_000   // above video, ghosts and overlays

        // Corner squares — fixed colors, y-up coordinates (TL = max y).
        let s = cornerSize
        let corners: [(CGColor, CGPoint)] = [
            (CGColor(red: 1, green: 0, blue: 0, alpha: 0.9), CGPoint(x: 0, y: size.height - s)),          // TL red
            (CGColor(red: 0, green: 0.8, blue: 0, alpha: 0.9), CGPoint(x: size.width - s, y: size.height - s)), // TR green
            (CGColor(red: 0, green: 0.3, blue: 1, alpha: 0.9), CGPoint(x: 0, y: 0)),                      // BL blue
            (CGColor(red: 1, green: 0.85, blue: 0, alpha: 0.9), CGPoint(x: size.width - s, y: 0)),        // BR yellow
        ]
        for (color, origin) in corners {
            let square = CALayer()
            square.frame = CGRect(origin: origin, size: CGSize(width: s, height: s)).sanitized("badge corner")
            square.backgroundColor = color
            badge.addSublayer(square)
        }

        // Identity chip — hue hashed from the wid so every instance is
        // visually distinct; stable across photos of the same instance.
        let hue = CGFloat(abs(wid.hashValue % 360)) / 360.0
        let chip = CALayer()
        let chipFrame = CGRect(
            x: (size.width - chipSize.width) / 2,
            y: (size.height - chipSize.height) / 2,
            width: chipSize.width,
            height: chipSize.height
        )
        chip.frame = chipFrame.sanitized("badge chip")
        chip.backgroundColor = CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            components: hueToRGB(hue) + [0.85]
        )
        chip.cornerRadius = 12
        badge.addSublayer(chip)

        let idLayer = CATextLayer()
        idLayer.frame = CGRect(x: 0, y: 34, width: chipSize.width, height: 80).sanitized("badge id")
        // Variant letter = compositor-mapping construction (D
        // contents-swap default / A HDR-compatible AVSBDL) —
        // photo-attributable.
        idLayer.string = "#\(seq) \(role)\(did.map(String.init) ?? "?")·\(variant)  \(wid.prefix(8))"
        idLayer.fontSize = 34
        idLayer.alignmentMode = .center
        idLayer.foregroundColor = CGColor(gray: 0, alpha: 1)
        idLayer.contentsScale = contentsScale
        chip.addSublayer(idLayer)

        badge.counterLayer.frame = CGRect(x: 0, y: 4, width: chipSize.width, height: 34).sanitized("badge counter")
        badge.counterLayer.string = "0s"
        badge.counterLayer.fontSize = 26
        badge.counterLayer.alignmentMode = .center
        badge.counterLayer.foregroundColor = CGColor(gray: 0, alpha: 1)
        badge.counterLayer.contentsScale = contentsScale
        chip.addSublayer(badge.counterLayer)

        DispatchQueue.main.async {
            liveBadges.add(badge)
            startTickTimerIfNeeded()
        }
        return badge
    }

    /// 1 Hz counter updates while any badge is alive; stops itself when
    /// the last badge goes away. Main queue.
    private static func startTickTimerIfNeeded() {
        guard tickTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler {
            let badges = liveBadges.allObjects
            guard !badges.isEmpty else {
                tickTimer?.cancel()
                tickTimer = nil
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for badge in badges {
                let elapsed = Int(CFAbsoluteTimeGetCurrent() - badge.createdAt)
                badge.counterLayer.string = "\(elapsed)s"
            }
            CATransaction.commit()
        }
        tickTimer = timer
        timer.resume()
    }

    private static func hueToRGB(_ hue: CGFloat) -> [CGFloat] {
        // Small HSV→RGB (s=0.55, v=1.0) — pastel enough for black text.
        let h = hue * 6
        let c: CGFloat = 0.55
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (CGFloat, CGFloat, CGFloat) = switch Int(h) % 6 {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        let m = 1 - c
        return [r + m, g + m, b + m]
    }
}

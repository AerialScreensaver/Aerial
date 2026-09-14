//
//  AVAsset+VideoOrientation.swift
//  AVAsset+VideoOrientation
//
//  Created by Guillaume Louel on 26/08/2021.
//  Copyright © 2021 Guillaume Louel. All rights reserved.
//
//  Originally translated from https://gist.github.com/lukabernardi/5020724,
//  rewritten 2026-09-12: the angle-bucket version declared every clip with
//  a ±90° (or unrecognised) transform vertical WITHOUT looking at its size,
//  which mislabelled landscape drone/phone footage stored rotated
//  (e.g. DJI Mavic: coded 3384×6016 + 90° matrix = 6016×3384 on screen).
//

import AVFoundation
import CoreGraphics

/// Pure orientation math, kept separate from AVAsset so it can be unit
/// tested with synthetic sizes and transforms.
enum VideoOrientationMath {

    /// Portrait in DISPLAY space: the track's coded `naturalSize` with its
    /// `preferredTransform` applied (rotation/flip metadata that players
    /// such as QuickTime honour), compared on absolute values — a 90°
    /// matrix swaps the axes and a flip negates a component, neither of
    /// which changes the on-screen aspect. Baked-in portrait (1080×1920
    /// with an identity transform) is portrait too. Zero or non-finite
    /// dimensions read as horizontal, the safe default for a consumer
    /// that only ever asks for landscape content.
    static func isVertical(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> Bool {
        let display = naturalSize.applying(preferredTransform)
        let width = abs(display.width)
        let height = abs(display.height)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return false }
        return height > width
    }
}

extension AVAsset {

    /// Whether the first video track is portrait on screen. Note that the
    /// wallpaper file engine (`VideoRenderer`) reads the raw track and does
    /// not apply `preferredTransform`, so a rotated-but-landscape clip is
    /// correctly labelled horizontal here yet still plays rotated there.
    func isVertical() -> Bool {
        guard let track = self.tracks(withMediaType: .video).first else {
            return false
        }
        return VideoOrientationMath.isVertical(
            naturalSize: track.naturalSize,
            preferredTransform: track.preferredTransform
        )
    }
}

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

    /// What a track needs to appear upright: the size of the rotated
    /// picture and the transform that lands it at the origin of a canvas
    /// of that size. `isIdentity` means no rotation at all, so a renderer
    /// can stay on its raw track path.
    struct DisplayGeometry: Equatable {
        let renderSize: CGSize
        let transform: CGAffineTransform
        let isIdentity: Bool
    }

    /// Clockwise on-screen rotation by a multiple of 90°, as an exact
    /// matrix (no trig rounding): 90° is the matrix iPhone portrait clips
    /// carry (a 0, b 1, c -1, d 0). Other values normalise modulo 360.
    static func rotation(degrees: Int) -> CGAffineTransform {
        let quarter = ((degrees % 360) + 360) % 360 / 90
        switch quarter {
        case 1: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        case 3: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        default: return .identity
        }
    }

    /// The track's `preferredTransform` with the user's extra rotation
    /// applied after it, normalised so the rotated picture's bounding box
    /// starts at (0, 0). The translation the file carries is ignored — it
    /// is recomputed from the size, which also repairs files whose matrix
    /// has a bogus offset. Non-finite or negative dimensions count as 0.
    static func displayGeometry(naturalSize: CGSize, preferredTransform: CGAffineTransform,
                                extraRotation: Int = 0) -> DisplayGeometry {
        let linear = CGAffineTransform(a: preferredTransform.a, b: preferredTransform.b,
                                       c: preferredTransform.c, d: preferredTransform.d, tx: 0, ty: 0)
        let effective = linear.concatenating(rotation(degrees: extraRotation))
        let width = naturalSize.width.isFinite ? max(naturalSize.width, 0) : 0
        let height = naturalSize.height.isFinite ? max(naturalSize.height, 0) : 0
        let box = CGRect(origin: .zero, size: CGSize(width: width, height: height)).applying(effective)
        // Even dimensions: 4:2:0 pixel formats need them.
        let render = CGSize(width: (box.width / 2).rounded() * 2, height: (box.height / 2).rounded() * 2)
        let transform = effective.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
        let tolerance: CGFloat = 0.001
        let isIdentity = abs(effective.a - 1) < tolerance && abs(effective.d - 1) < tolerance
            && abs(effective.b) < tolerance && abs(effective.c) < tolerance
        return DisplayGeometry(renderSize: render, transform: transform, isIdentity: isIdentity)
    }

    /// Portrait in DISPLAY space: the track's coded `naturalSize` with its
    /// `preferredTransform` (and the user's extra rotation) applied,
    /// compared on absolute values — a 90° matrix swaps the axes and a
    /// flip negates a component, neither of which changes the on-screen
    /// aspect. Baked-in portrait (1080×1920 with an identity transform)
    /// is portrait too. Zero or non-finite dimensions read as horizontal,
    /// the safe default for a consumer that only ever asks for landscape
    /// content.
    static func isVertical(naturalSize: CGSize, preferredTransform: CGAffineTransform,
                           extraRotation: Int = 0) -> Bool {
        let display = naturalSize.applying(preferredTransform.concatenating(rotation(degrees: extraRotation)))
        let width = abs(display.width)
        let height = abs(display.height)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return false }
        return height > width
    }
}

extension AVAsset {

    /// Whether the first video track is portrait on screen, after its
    /// own orientation metadata and the user's extra rotation
    /// (`PrefsVideos.rotationOverride`, degrees clockwise). The wallpaper
    /// file engine applies the same two inputs at playback.
    func isVertical(extraRotation: Int = 0) -> Bool {
        guard let track = self.tracks(withMediaType: .video).first else {
            return false
        }
        return VideoOrientationMath.isVertical(
            naturalSize: track.naturalSize,
            preferredTransform: track.preferredTransform,
            extraRotation: extraRotation
        )
    }
}

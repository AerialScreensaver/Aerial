//
//  SpannedGeometry.swift
//  Aerial
//
//  The pure math behind spanned-mode layout, extracted from
//  DisplayDetection + the wallpaper extension's spannedLayerFrame() so
//  it can be unit-tested with synthetic screen configurations (this is
//  the corner-overlap bug family's home turf). Everything here is
//  side-effect free: inputs are global-Cocoa-coordinate screen frames
//  (NSScreen.frame style, y-up, main display's bottom-left at 0,0) and
//  margin values already converted to points.
//
//  Behavior notes preserved from the originals (characterization, not
//  cleanup):
//  - Bounding folds are seeded with 0, not the first screen — a layout
//    whose screens all sit at positive coordinates still extends to the
//    origin. Real layouts always include the main screen at (0,0), so
//    this only shows up with exotic active-screen filters.
//  - Border counting ("screens fully to the left/below") mirrors
//    detectBorders and fails the same way on tetris-like grids.
//

import Foundation
import CoreGraphics

enum SpannedGeometry {

    /// Count screens fully to the left of / fully below `frames[index]`.
    /// Port of `DisplayDetection.detectBorders` — used to inject the
    /// per-gap spanned margins into each screen's zeroed origin.
    static func borderCounts(for index: Int, frames: [CGRect]) -> (left: CGFloat, below: CGFloat) {
        let target = frames[index]
        var left: CGFloat = 0
        var below: CGFloat = 0
        for (i, frame) in frames.enumerated() where i != index {
            if frame.origin.x < target.origin.x && frame.maxX <= target.origin.x {
                left += 1
            }
            if frame.origin.y < target.origin.y && frame.maxY <= target.origin.y {
                below += 1
            }
        }
        return (left, below)
    }

    /// Min/max fold over frames, seeded with 0 (see header). The basis
    /// of both the global rect and the spanned canvas.
    static func boundingRect(frames: [CGRect]) -> CGRect {
        var minX: CGFloat = 0, minY: CGFloat = 0, maxX: CGFloat = 0, maxY: CGFloat = 0
        for frame in frames {
            if frame.origin.x < minX { minX = frame.origin.x }
            if frame.origin.y < minY { minY = frame.origin.y }
            if frame.maxX > maxX { maxX = frame.maxX }
            if frame.maxY > maxY { maxY = frame.maxY }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A screen's origin re-based to the global rect's origin, plus the
    /// margin contribution of every screen gap to its left/below. Port
    /// of the `calculateZeroedOrigins` per-screen formula.
    static func zeroedOrigin(
        frame: CGRect,
        globalOrigin: CGPoint,
        borders: (left: CGFloat, below: CGFloat),
        leftMargin: CGFloat,
        belowMargin: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: frame.origin.x - globalOrigin.x + borders.left * leftMargin,
            y: frame.origin.y - globalOrigin.y + borders.below * belowMargin
        )
    }

    /// The spanned canvas: bounding fold over the ACTIVE screens,
    /// re-based to the global (all-screens) origin, with the total
    /// margin span added to the size. Port of the regular branch of
    /// `getZeroedActiveSpannedRect`.
    static func spannedCanvas(
        activeFrames: [CGRect],
        globalOrigin: CGPoint,
        widthMargin: CGFloat,
        heightMargin: CGFloat
    ) -> CGRect {
        let bounds = boundingRect(frames: activeFrames)
        return CGRect(
            x: bounds.origin.x - globalOrigin.x,
            y: bounds.origin.y - globalOrigin.y,
            width: bounds.width + widthMargin,
            height: bounds.height + heightMargin
        )
    }

    /// Where one display's canvas-sized layer sits in its own window's
    /// coordinate space: the canvas shifted so this screen's slice lands
    /// at the window origin. Port of the `spannedLayerFrame()` kernel.
    static func layerFrame(canvas: CGRect, zeroedOrigin: CGPoint) -> CGRect {
        CGRect(
            x: canvas.origin.x - zeroedOrigin.x,
            y: canvas.origin.y - zeroedOrigin.y,
            width: canvas.width,
            height: canvas.height
        )
    }

    /// The part of the giant layer actually visible through a window of
    /// `windowSize` at the origin — nil when the layer misses the window
    /// entirely (the "NONE (layer misses window!)" case).
    static func visibleSlice(layerFrame: CGRect, windowSize: CGSize) -> CGRect? {
        let window = CGRect(origin: .zero, size: windowSize)
        let slice = layerFrame.intersection(window)
        return slice.isNull ? nil : slice
    }

    /// Per-display result of the full regular-path pipeline.
    struct DisplayLayout: Equatable {
        var zeroedOrigin: CGPoint
        var layerFrame: CGRect
        var visibleSlice: CGRect?
    }

    /// Run the whole regular-path pipeline (border counts → zeroed
    /// origins → canvas → per-display layer frames and slices) for a
    /// synthetic configuration. Convenience for tests and invariants;
    /// production code calls the pieces individually from
    /// DisplayDetection / the extension.
    static func spannedLayout(
        frames: [CGRect],
        activeIndices: Set<Int>? = nil,
        leftMargin: CGFloat = 0,
        belowMargin: CGFloat = 0
    ) -> (canvas: CGRect, displays: [DisplayLayout]) {
        let allBorders = frames.indices.map { borderCounts(for: $0, frames: frames) }
        let maxLeft = allBorders.map(\.left).max() ?? 0
        let maxBelow = allBorders.map(\.below).max() ?? 0
        let globalOrigin = boundingRect(frames: frames).origin

        let active = activeIndices ?? Set(frames.indices)
        let canvas = spannedCanvas(
            activeFrames: frames.indices.filter(active.contains).map { frames[$0] },
            globalOrigin: globalOrigin,
            widthMargin: maxLeft * leftMargin,
            heightMargin: maxBelow * belowMargin
        )

        let displays = frames.indices.map { index -> DisplayLayout in
            let origin = zeroedOrigin(
                frame: frames[index],
                globalOrigin: globalOrigin,
                borders: allBorders[index],
                leftMargin: leftMargin,
                belowMargin: belowMargin
            )
            let layer = layerFrame(canvas: canvas, zeroedOrigin: origin)
            return DisplayLayout(
                zeroedOrigin: origin,
                layerFrame: layer,
                visibleSlice: visibleSlice(layerFrame: layer, windowSize: frames[index].size)
            )
        }
        return (canvas, displays)
    }
}

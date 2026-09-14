//
//  SpannedGeometryPropertyTests.swift
//  AerialTests
//
//  Property tests for the pure spanned-mode layout math. The golden
//  fixtures in SpannedGeometryTests pin real-world layouts; these pin the
//  invariants for ANY layout the seeded generator can dream up — 1–6
//  displays, negative origins, overlaps, margins — and prove that
//  degenerate input (NaN, ±inf, zero sizes, empty lists, bad indices)
//  never traps. A NaN in, NaN out is acceptable here: the appex's
//  `.sanitized()` choke point is the layer that turns it into a fallback.
//

import CoreGraphics
import Foundation
import Testing
@testable import Aerial

@Suite("SpannedGeometry properties")
struct SpannedGeometryPropertyTests {
    private static let eps: CGFloat = 1e-3

    private func approxEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < Self.eps && abs(a.minY - b.minY) < Self.eps
            && abs(a.width - b.width) < Self.eps && abs(a.height - b.height) < Self.eps
    }

    private func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        inner.minX >= outer.minX - Self.eps && inner.minY >= outer.minY - Self.eps
            && inner.maxX <= outer.maxX + Self.eps && inner.maxY <= outer.maxY + Self.eps
    }

    @Test("boundingRect contains every frame")
    func boundingRectContainsAll() {
        forAll(iterations: 500) { rng, _ in
            let frames = (0..<rng.int(0...6)).map { _ in rng.displayFrame() }
            let bounds = SpannedGeometry.boundingRect(frames: frames)
            #expect(bounds.isFiniteRect, "\(rng.trail)")
            for frame in frames {
                #expect(contains(bounds, frame), "\(rng.trail) frame=\(frame) bounds=\(bounds)")
            }
        }
    }

    @Test("visibleSlice is the window∩layer intersection: inside both, nil only when disjoint")
    func visibleSliceWithinBoth() {
        forAll(iterations: 500) { rng, _ in
            let layer = rng.finiteRect()
            let window = CGSize(width: CGFloat(rng.int(1...8192)), height: CGFloat(rng.int(1...8192)))
            let windowRect = CGRect(origin: .zero, size: window)
            let slice = SpannedGeometry.visibleSlice(layerFrame: layer, windowSize: window)
            if let slice {
                #expect(contains(windowRect, slice), "\(rng.trail) slice=\(slice) window=\(window)")
                #expect(contains(layer, slice), "\(rng.trail) slice=\(slice) layer=\(layer)")
            } else {
                #expect(layer.intersection(windowRect).isNull, "\(rng.trail) layer=\(layer) window=\(window)")
            }
        }
    }

    @Test("all displays active: every window is fully covered by the shared canvas, with any margins")
    func fullCoverageWhenAllActive() {
        forAll(iterations: 400) { rng, _ in
            let frames = (0..<rng.int(1...6)).map { _ in rng.displayFrame() }
            let leftMargin = CGFloat(rng.int(0...300))
            let belowMargin = CGFloat(rng.int(0...300))
            let layout = SpannedGeometry.spannedLayout(frames: frames, leftMargin: leftMargin, belowMargin: belowMargin)
            #expect(layout.displays.count == frames.count, "\(rng.trail)")
            #expect(layout.canvas.isFiniteRect, "\(rng.trail)")
            for (index, display) in layout.displays.enumerated() {
                let fullWindow = CGRect(origin: .zero, size: frames[index].size)
                #expect(display.layerFrame.isFiniteRect, "\(rng.trail)")
                #expect(display.layerFrame.size == layout.canvas.size, "\(rng.trail) display=\(index)")
                guard let slice = display.visibleSlice else {
                    Issue.record("\(rng.trail) display \(index) not covered: layer=\(display.layerFrame) frame=\(frames[index])")
                    continue
                }
                #expect(approxEqual(slice, fullWindow), "\(rng.trail) display=\(index) slice=\(slice) window=\(fullWindow) layer=\(display.layerFrame) canvas=\(layout.canvas)")
            }
        }
    }

    @Test("subset active: the active displays are still fully covered, inactive ones never trap")
    func activeSubsetCoverage() {
        forAll(iterations: 400) { rng, _ in
            let frames = (0..<rng.int(1...6)).map { _ in rng.displayFrame() }
            var active = Set(frames.indices.filter { _ in rng.bool(probability: 0.6) })
            if active.isEmpty { active = [rng.int(0...(frames.count - 1))] }
            if rng.bool(probability: 0.2) { active.insert(99) }   // stale index from a detached display
            let layout = SpannedGeometry.spannedLayout(
                frames: frames, activeIndices: active,
                leftMargin: CGFloat(rng.int(0...300)), belowMargin: CGFloat(rng.int(0...300))
            )
            for index in frames.indices where active.contains(index) {
                let fullWindow = CGRect(origin: .zero, size: frames[index].size)
                guard let slice = layout.displays[index].visibleSlice else {
                    Issue.record("\(rng.trail) active display \(index) not covered")
                    continue
                }
                #expect(approxEqual(slice, fullWindow), "\(rng.trail) display=\(index) slice=\(slice) window=\(fullWindow)")
            }
        }
    }

    @Test("degenerate input never traps: NaN/inf/zero/negative frames, empty lists, stale active indices")
    func degenerateInputNeverTraps() {
        forAll(iterations: 400) { rng, _ in
            let frames = (0..<rng.int(0...5)).map { _ in rng.anyRect() }
            let active: Set<Int>? = rng.bool() ? nil : Set((0..<rng.int(0...3)).map { _ in rng.int(-2...8) })
            let layout = SpannedGeometry.spannedLayout(
                frames: frames, activeIndices: active,
                leftMargin: rng.anyCGFloat(), belowMargin: rng.anyCGFloat()
            )
            #expect(layout.displays.count == frames.count, "\(rng.trail)")
            _ = SpannedGeometry.boundingRect(frames: frames)
            _ = SpannedGeometry.visibleSlice(layerFrame: rng.anyRect(), windowSize: CGSize(width: rng.anyCGFloat(), height: rng.anyCGFloat()))
            _ = SpannedGeometry.layerFrame(canvas: rng.anyRect(), zeroedOrigin: CGPoint(x: rng.anyCGFloat(), y: rng.anyCGFloat()))
        }
        // Empty topology: no displays, an empty canvas, nothing to slice.
        let empty = SpannedGeometry.spannedLayout(frames: [])
        #expect(empty.displays.isEmpty)
        #expect(empty.canvas == .zero)
    }
}

//
//  SpannedGeometryTests.swift
//  AerialTests
//
//  Tests for the pure spanned-mode layout math (SpannedGeometry) —
//  extracted from DisplayDetection + the wallpaper extension's
//  spannedLayerFrame(). The golden fixtures reproduce real-world
//  configurations from the corner-overlap investigation logs:
//
//  - "guillaume-2x1440p": two 2560×1440 side by side; expectations are
//    byte-for-byte the 🧭 self-check lines from
//    /Users/Shared/Aerial/Logs/wallpaper.txt (2026-07-07).
//  - "tester-4-display": the portrait-left 4-display layout from the
//    logs040726 report (📺 found lines, 2026-07-04) — main 1440p,
//    second 1440p to its right, MacBook below-right, 1440×2560
//    portrait at (-1440, -712).
//

import Testing
import Foundation
@testable import Aerial

@Suite("Spanned Geometry")
struct SpannedGeometryTests {

    // MARK: - Kernel pieces

    @Test("layerFrame shifts the canvas by the screen's zeroed origin")
    func layerFrameKernel() {
        let canvas = CGRect(x: 0, y: 0, width: 5120, height: 1440)
        let frame = SpannedGeometry.layerFrame(canvas: canvas, zeroedOrigin: CGPoint(x: 2560, y: 0))
        #expect(frame == CGRect(x: -2560, y: 0, width: 5120, height: 1440))
    }

    @Test("visibleSlice clips the layer to the window, nil on a miss")
    func visibleSliceKernel() {
        let window = CGSize(width: 2560, height: 1440)
        #expect(
            SpannedGeometry.visibleSlice(
                layerFrame: CGRect(x: -2560, y: 0, width: 5120, height: 1440),
                windowSize: window
            ) == CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )
        // The "NONE (layer misses window!)" case from the 🧭 self-check.
        #expect(
            SpannedGeometry.visibleSlice(
                layerFrame: CGRect(x: -7000, y: 0, width: 5120, height: 1440),
                windowSize: window
            ) == nil
        )
    }

    @Test("boundingRect fold is seeded at zero (characterized quirk)")
    func boundingRectSeedQuirk() {
        // A lone frame at positive coordinates still pulls the bounds
        // back to the origin — DisplayDetection has always folded from
        // (0,0,0,0). Harmless in practice (the main screen sits at 0,0)
        // but pinned here so a "cleanup" doesn't silently change canvas
        // math for active-screen subsets.
        let bounds = SpannedGeometry.boundingRect(frames: [CGRect(x: 2560, y: 0, width: 2560, height: 1440)])
        #expect(bounds == CGRect(x: 0, y: 0, width: 5120, height: 1440))
    }

    // MARK: - Golden fixture: Guillaume's 2×2560×1440 side by side

    @Test("two side-by-side 1440p displays match the logged 🧭 values")
    func guillaumeTwoDisplays() {
        let frames = [
            CGRect(x: 0, y: 0, width: 2560, height: 1440),     // did=3 (main)
            CGRect(x: 2560, y: 0, width: 2560, height: 1440),  // did=6
        ]
        let (canvas, displays) = SpannedGeometry.spannedLayout(frames: frames)

        #expect(canvas == CGRect(x: 0, y: 0, width: 5120, height: 1440))

        // 🧭 spanned did=3 raw=(0,0,2560,1440) zeroedOrigin=(0,0)
        //    layerFrame=(0,0,5120,1440) visibleSlice=(0,0,2560,1440)
        #expect(displays[0].zeroedOrigin == CGPoint(x: 0, y: 0))
        #expect(displays[0].layerFrame == CGRect(x: 0, y: 0, width: 5120, height: 1440))
        #expect(displays[0].visibleSlice == CGRect(x: 0, y: 0, width: 2560, height: 1440))

        // 🧭 spanned did=6 raw=(2560,0,2560,1440) zeroedOrigin=(2560,0)
        //    layerFrame=(-2560,0,5120,1440) visibleSlice=(0,0,2560,1440)
        #expect(displays[1].zeroedOrigin == CGPoint(x: 2560, y: 0))
        #expect(displays[1].layerFrame == CGRect(x: -2560, y: 0, width: 5120, height: 1440))
        #expect(displays[1].visibleSlice == CGRect(x: 0, y: 0, width: 2560, height: 1440))
    }

    // MARK: - Golden fixture: tester's 4-display portrait-left layout

    /// 📺 found (logs040726): main 1440p at origin, 1440p right,
    /// MacBook 1512×982 below-right, portrait 1440×2560 at (-1440,-712).
    private let testerFrames = [
        CGRect(x: 0, y: 0, width: 2560, height: 1440),        // did=2 main
        CGRect(x: 2560, y: 0, width: 2560, height: 1440),     // did=3 right (overlap reports)
        CGRect(x: 2560, y: -982, width: 1512, height: 982),   // did=1 MacBook
        CGRect(x: -1440, y: -712, width: 1440, height: 2560), // did=20 portrait
    ]

    @Test("tester 4-display layout: canvas, origins, slices")
    func testerFourDisplays() {
        let (canvas, displays) = SpannedGeometry.spannedLayout(frames: testerFrames)

        // Union spans x ∈ [-1440, 5120], y ∈ [-982, 1848].
        #expect(canvas == CGRect(x: 0, y: 0, width: 6560, height: 2830))

        #expect(displays[0].zeroedOrigin == CGPoint(x: 1440, y: 982))
        #expect(displays[1].zeroedOrigin == CGPoint(x: 4000, y: 982))
        #expect(displays[2].zeroedOrigin == CGPoint(x: 4000, y: 0))
        #expect(displays[3].zeroedOrigin == CGPoint(x: 0, y: 270))

        #expect(displays[1].layerFrame == CGRect(x: -4000, y: -982, width: 6560, height: 2830))
        #expect(displays[3].layerFrame == CGRect(x: 0, y: -270, width: 6560, height: 2830))

        // Every window is fully covered by its slice — a partial slice
        // here is exactly the wrong-slice / corner-overlap symptom.
        for (index, display) in displays.enumerated() {
            #expect(
                display.visibleSlice == CGRect(origin: .zero, size: testerFrames[index].size),
                "display \(index) not fully covered"
            )
        }
    }

    @Test("tester 4-display layout: slices tile the canvas without overlap")
    func testerFourDisplaysInvariants() {
        let (canvas, displays) = SpannedGeometry.spannedLayout(frames: testerFrames)

        // Map each window-space slice into canvas space: the canvas
        // point behind window point w is w + zeroedOrigin (canvas
        // origin is 0 here).
        let canvasSlices: [CGRect] = displays.compactMap { display in
            display.visibleSlice?.offsetBy(
                dx: display.zeroedOrigin.x,
                dy: display.zeroedOrigin.y
            )
        }
        #expect(canvasSlices.count == displays.count)

        for slice in canvasSlices {
            #expect(canvas.contains(slice), "slice \(slice) escapes the canvas")
        }
        for i in canvasSlices.indices {
            for j in canvasSlices.indices where j > i {
                let overlap = canvasSlices[i].intersection(canvasSlices[j])
                #expect(
                    overlap.isNull || overlap.isEmpty,
                    "slices \(i) and \(j) overlap in canvas space: \(overlap)"
                )
            }
        }
    }

    // MARK: - Margins

    @Test("horizontal margin widens the canvas and opens a bezel gap")
    func horizontalMargin() {
        let frames = [
            CGRect(x: 0, y: 0, width: 2560, height: 1440),
            CGRect(x: 2560, y: 0, width: 2560, height: 1440),
        ]
        let (canvas, displays) = SpannedGeometry.spannedLayout(frames: frames, leftMargin: 100)

        #expect(canvas == CGRect(x: 0, y: 0, width: 5220, height: 1440))
        // Right display shifts by the margin; the canvas band
        // x ∈ [2560, 2660] falls "behind the bezel" on no display.
        #expect(displays[1].zeroedOrigin == CGPoint(x: 2660, y: 0))
        #expect(displays[1].layerFrame == CGRect(x: -2660, y: 0, width: 5220, height: 1440))
        #expect(displays[0].visibleSlice == CGRect(x: 0, y: 0, width: 2560, height: 1440))
        #expect(displays[1].visibleSlice == CGRect(x: 0, y: 0, width: 2560, height: 1440))
    }

    // MARK: - Active-screen subsets

    @Test("inactive screens keep their layer but the canvas folds actives only")
    func activeSubset() {
        let frames = [
            CGRect(x: 0, y: 0, width: 2560, height: 1440),
            CGRect(x: 2560, y: 0, width: 2560, height: 1440),
        ]
        // Only the right display active (e.g. secondaryOnly). The
        // zero-seeded fold still anchors the canvas at x=0 (see
        // boundingRectSeedQuirk) — pinned as-is.
        let (canvas, displays) = SpannedGeometry.spannedLayout(frames: frames, activeIndices: [1])

        #expect(canvas == CGRect(x: 0, y: 0, width: 5120, height: 1440))
        #expect(displays[1].visibleSlice == CGRect(x: 0, y: 0, width: 2560, height: 1440))
    }
}

@Suite("Advanced Per-Display Margins")
struct AdvancedMarginTests {

    @Test("AdvancedMargin JSON round-trips")
    func roundTrip() throws {
        // Origins from the tester's 4-display layout — negative
        // coordinates and fractional offsets must survive.
        let margin = AdvancedMargin(displays: [
            DisplayAdvancedMargin(zleft: -1440, ztop: -712, offsetleft: 2.5, offsettop: -1),
            DisplayAdvancedMargin(zleft: 0, ztop: 0, offsetleft: 0, offsettop: 0),
        ])
        let data = try JSONEncoder().encode(margin)
        let decoded = try JSONDecoder().decode(AdvancedMargin.self, from: data)
        #expect(decoded == margin)
    }

    @Test("legacy raw-string formats fail to decode (gate falls back to empty)")
    func legacyStringsRejected() {
        // The pre-4.1 UI let users type these; the engine's gate
        // (`displayMarginsAdvanced && !displays.isEmpty`) relies on them
        // decoding to nothing rather than garbage.
        for legacy in ["0,0,0,0;1,2,3,4", "top,left,bottom,right", ""] {
            let decoded = legacy.data(using: .utf8).flatMap {
                try? JSONDecoder().decode(AdvancedMargin.self, from: $0)
            }
            #expect(decoded == nil, "'\(legacy)' should not decode")
        }
    }
}

// MARK: - Appex CoreGraphics enumeration helpers

@Suite("Display topology (appex CoreGraphics enumeration)")
struct DisplayTopologyTests {

    @Test("CG bounds flip to Cocoa frames about the main display height")
    func cgToCocoaFlip() {
        // The 2026-08-22 four-display bundle: CG bounds from the window
        // dump, Cocoa frames from system-info.txt (main = 2560×1440).
        let mainH: CGFloat = 1440
        #expect(DisplayDetection.cocoaFrame(fromCGBounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), mainHeight: mainH)
                == CGRect(x: 0, y: 0, width: 2560, height: 1440))
        // MacBook below-right of main
        #expect(DisplayDetection.cocoaFrame(fromCGBounds: CGRect(x: 2560, y: 1440, width: 1512, height: 982), mainHeight: mainH)
                == CGRect(x: 2560, y: -982, width: 1512, height: 982))
        // Portrait DisplayLink DELL left of main, top edge above main
        #expect(DisplayDetection.cocoaFrame(fromCGBounds: CGRect(x: -1440, y: -408, width: 1440, height: 2560), mainHeight: mainH)
                == CGRect(x: -1440, y: -712, width: 1440, height: 2560))
        // Second 1440p to the right, same height: unchanged
        #expect(DisplayDetection.cocoaFrame(fromCGBounds: CGRect(x: 2560, y: 0, width: 2560, height: 1440), mainHeight: mainH)
                == CGRect(x: 2560, y: 0, width: 2560, height: 1440))
    }

    @Test("topology signature is order-independent and changes with the set")
    func topologySignature() {
        let a = Screen(id: 1, width: 2560, height: 1440,
                       bottomLeftFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                       isMain: true, backingScaleFactor: 2)
        let b = Screen(id: 4, width: 1440, height: 2560,
                       bottomLeftFrame: CGRect(x: -1440, y: -712, width: 1440, height: 2560),
                       isMain: false, backingScaleFactor: 1)
        #expect(DisplayDetection.topologySignature(of: [a, b]) == DisplayDetection.topologySignature(of: [b, a]))
        #expect(DisplayDetection.topologySignature(of: [a]) != DisplayDetection.topologySignature(of: [a, b]))
        #expect(DisplayDetection.topologySignature(of: []) == "")
        // The same monitor re-numbered after wake (DisplayLink 4 → 5) is a change
        let b2 = Screen(id: 5, width: 1440, height: 2560,
                        bottomLeftFrame: b.bottomLeftFrame,
                        isMain: false, backingScaleFactor: 1)
        #expect(DisplayDetection.topologySignature(of: [a, b]) != DisplayDetection.topologySignature(of: [a, b2]))
        // A rearrangement (same ids, moved frame) is a change too
        let bMoved = Screen(id: 4, width: 1440, height: 2560,
                            bottomLeftFrame: CGRect(x: 2560, y: -712, width: 1440, height: 2560),
                            isMain: false, backingScaleFactor: 1)
        #expect(DisplayDetection.topologySignature(of: [a, b]) != DisplayDetection.topologySignature(of: [a, bMoved]))
    }
}

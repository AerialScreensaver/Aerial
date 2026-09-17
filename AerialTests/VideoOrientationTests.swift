//
//  VideoOrientationTests.swift
//  AerialTests
//
//  Display-space portrait detection: coded size + preferredTransform.
//  The old angle-bucket logic declared every ±90° clip vertical without
//  looking at its size (DJI Mavic landscape clips stored rotated).
//

import CoreGraphics
import Testing
@testable import Aerial

@Suite("Video orientation")
struct VideoOrientationTests {

    private let landscape = CGSize(width: 1920, height: 1080)
    private let portrait = CGSize(width: 1080, height: 1920)
    private let djiCoded = CGSize(width: 3384, height: 6016)   // displays as 6016×3384
    private let quarterTurn = CGAffineTransform(rotationAngle: .pi / 2)
    private let minusQuarterTurn = CGAffineTransform(rotationAngle: -.pi / 2)

    @Test("identity transform: landscape is horizontal, baked-in portrait is vertical")
    func identity() {
        #expect(VideoOrientationMath.isVertical(naturalSize: landscape, preferredTransform: .identity) == false)
        #expect(VideoOrientationMath.isVertical(naturalSize: portrait, preferredTransform: .identity) == true)
    }

    @Test("DJI Mavic: coded portrait with a ±90° matrix displays landscape → horizontal")
    func rotatedDroneClipIsHorizontal() {
        #expect(VideoOrientationMath.isVertical(naturalSize: djiCoded, preferredTransform: quarterTurn) == false)
        #expect(VideoOrientationMath.isVertical(naturalSize: djiCoded, preferredTransform: minusQuarterTurn) == false)
    }

    @Test("iPhone: coded landscape with a ±90° matrix displays portrait → vertical")
    func rotatedPhoneClipIsVertical() {
        #expect(VideoOrientationMath.isVertical(naturalSize: landscape, preferredTransform: quarterTurn) == true)
        #expect(VideoOrientationMath.isVertical(naturalSize: landscape, preferredTransform: minusQuarterTurn) == true)
    }

    @Test("180° and flips keep the aspect: negative components never flip the answer")
    func halfTurnAndFlips() {
        let halfTurn = CGAffineTransform(rotationAngle: .pi)
        let horizontalFlip = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1920, ty: 0)
        let verticalFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1080)
        #expect(VideoOrientationMath.isVertical(naturalSize: landscape, preferredTransform: halfTurn) == false)
        #expect(VideoOrientationMath.isVertical(naturalSize: landscape, preferredTransform: horizontalFlip) == false)
        #expect(VideoOrientationMath.isVertical(naturalSize: landscape, preferredTransform: verticalFlip) == false)
        #expect(VideoOrientationMath.isVertical(naturalSize: portrait, preferredTransform: halfTurn) == true)
    }

    @Test("negative zero components behave like identity")
    func negativeZero() {
        let wobbly = CGAffineTransform(a: 1, b: -0.0, c: -0.0, d: 1, tx: 0, ty: 0)
        #expect(VideoOrientationMath.isVertical(naturalSize: landscape, preferredTransform: wobbly) == false)
        #expect(VideoOrientationMath.isVertical(naturalSize: portrait, preferredTransform: wobbly) == true)
    }

    @Test("degenerate sizes read as horizontal")
    func degenerate() {
        #expect(VideoOrientationMath.isVertical(naturalSize: .zero, preferredTransform: .identity) == false)
        #expect(VideoOrientationMath.isVertical(naturalSize: CGSize(width: 0, height: 1080), preferredTransform: quarterTurn) == false)
        #expect(VideoOrientationMath.isVertical(naturalSize: CGSize(width: CGFloat.nan, height: 1080), preferredTransform: .identity) == false)
    }
}

@Suite("Video display geometry")
struct VideoDisplayGeometryTests {

    private let landscape = CGSize(width: 1920, height: 1080)
    private let djiCoded = CGSize(width: 3384, height: 6016)
    /// What an iPhone writes for a landscape clip held the other way.
    private let halfTurn = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)
    /// What an iPhone writes for a portrait clip (coded landscape).
    private let quarterTurn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)

    @Test("identity stays on the raw track path")
    func identity() {
        let g = VideoOrientationMath.displayGeometry(naturalSize: landscape, preferredTransform: .identity)
        #expect(g.isIdentity)
        #expect(g.renderSize == landscape)
        #expect(g.transform == .identity)
    }

    @Test("180° iPhone clip: same canvas, opposite corners swap")
    func halfTurnClip() {
        let g = VideoOrientationMath.displayGeometry(naturalSize: landscape, preferredTransform: halfTurn)
        #expect(!g.isIdentity)
        #expect(g.renderSize == landscape)
        #expect(CGPoint.zero.applying(g.transform) == CGPoint(x: 1920, y: 1080))
        #expect(CGPoint(x: 1920, y: 1080).applying(g.transform) == .zero)
    }

    @Test("90° coded-landscape phone clip renders portrait, left edge on top")
    func quarterTurnClip() {
        let g = VideoOrientationMath.displayGeometry(naturalSize: landscape, preferredTransform: quarterTurn)
        #expect(g.renderSize == CGSize(width: 1080, height: 1920))
        #expect(CGPoint(x: 0, y: 1080).applying(g.transform) == .zero)
        #expect(CGPoint.zero.applying(g.transform) == CGPoint(x: 1080, y: 0))
    }

    @Test("DJI coded-portrait + 90° renders landscape")
    func droneClip() {
        let g = VideoOrientationMath.displayGeometry(naturalSize: djiCoded, preferredTransform: quarterTurn)
        #expect(g.renderSize == CGSize(width: 6016, height: 3384))
        #expect(!g.isIdentity)
    }

    @Test("extra rotation composes with the file's matrix")
    func extraRotation() {
        let viaMetadata = VideoOrientationMath.displayGeometry(naturalSize: landscape, preferredTransform: halfTurn)
        let viaOverride = VideoOrientationMath.displayGeometry(naturalSize: landscape, preferredTransform: .identity, extraRotation: 180)
        #expect(viaOverride == viaMetadata)
        let cancelled = VideoOrientationMath.displayGeometry(naturalSize: landscape, preferredTransform: quarterTurn, extraRotation: 270)
        #expect(cancelled.isIdentity)
        #expect(cancelled.renderSize == landscape)
        #expect(VideoOrientationMath.rotation(degrees: -90) == VideoOrientationMath.rotation(degrees: 270))
        #expect(VideoOrientationMath.rotation(degrees: 360) == .identity)
        // Same matrix as the trig version, minus its rounding noise.
        let trig = CGAffineTransform(rotationAngle: .pi / 2)
        let exact = VideoOrientationMath.rotation(degrees: 90)
        #expect(abs(exact.a - trig.a) < 1e-9 && abs(exact.b - trig.b) < 1e-9
            && abs(exact.c - trig.c) < 1e-9 && abs(exact.d - trig.d) < 1e-9)
    }

    @Test("extra 90° flips the portrait verdict, 180° never does")
    func extraRotationAndVertical() {
        #expect(VideoOrientationMath.isVertical(naturalSize: landscape, preferredTransform: .identity, extraRotation: 90) == true)
        #expect(VideoOrientationMath.isVertical(naturalSize: landscape, preferredTransform: quarterTurn, extraRotation: 270) == false)
        #expect(VideoOrientationMath.isVertical(naturalSize: landscape, preferredTransform: .identity, extraRotation: 180) == false)
    }

    @Test("degenerate sizes give a finite canvas, never NaN")
    func degenerate() {
        let g = VideoOrientationMath.displayGeometry(naturalSize: CGSize(width: CGFloat.nan, height: 1080), preferredTransform: quarterTurn)
        #expect(g.renderSize.width.isFinite && g.renderSize.height.isFinite)
        #expect(g.transform.tx.isFinite && g.transform.ty.isFinite)
    }
}

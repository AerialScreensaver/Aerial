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

//
//  GeometrySanitizerTests.swift
//  AerialTests
//
//  The NaN/inf choke point the wallpaper extension routes every Core
//  Animation geometry setter and float→integer conversion through.
//  A regression here is a black desktop, so the contract is pinned:
//  finite values pass through untouched, everything else collapses to
//  the fallback without trapping, and rejections are counted per context.
//

import Testing
import CoreGraphics
import CoreMedia
import Foundation
@testable import Aerial

@Suite("GeometrySanitizer")
struct GeometrySanitizerTests {
    private static let nonFinite: [CGFloat] = [.nan, .infinity, -.infinity]
    private static let fallbackRect = CGRect(x: 1, y: 2, width: 3, height: 4)

    @Test("finite geometry passes through untouched, negatives and zero included")
    func finitePassthrough() {
        let ctx = "finite-\(UUID().uuidString)"   // unique: suites run in parallel
        let rect = CGRect(x: -10, y: 2.5, width: 0, height: 1e6)
        #expect(rect.sanitized(ctx) == rect)
        let point = CGPoint(x: -0.0, y: CGFloat.greatestFiniteMagnitude)
        #expect(point.sanitized(ctx) == point)
        let size = CGSize(width: 0, height: -1)
        #expect(size.sanitized(ctx) == size)
        #expect(CGFloat(2.0).sanitized(ctx) == 2.0)
        #expect(GeometrySanitizer.hitCount(ctx) == 0)
    }

    @Test("a non-finite rect component collapses the whole rect to the fallback", arguments: nonFinite)
    func nonFiniteRect(bad: CGFloat) {
        let fb = Self.fallbackRect
        #expect(CGRect(x: bad, y: 0, width: 1, height: 1).sanitized("rect-x", fallback: fb) == fb)
        #expect(CGRect(x: 0, y: bad, width: 1, height: 1).sanitized("rect-y", fallback: fb) == fb)
        #expect(CGRect(x: 0, y: 0, width: bad, height: 1).sanitized("rect-w", fallback: fb) == fb)
        #expect(CGRect(x: 0, y: 0, width: 1, height: bad).sanitized("rect-h", fallback: fb) == fb)
    }

    @Test("non-finite point, size and scalar collapse to their fallback", arguments: nonFinite)
    func nonFinitePointSizeScalar(bad: CGFloat) {
        #expect(CGPoint(x: bad, y: 0).sanitized("pt", fallback: CGPoint(x: 9, y: 9)) == CGPoint(x: 9, y: 9))
        #expect(CGSize(width: 0, height: bad).sanitized("sz", fallback: CGSize(width: 9, height: 9)) == CGSize(width: 9, height: 9))
        #expect(bad.sanitized("scalar", fallback: 1) == 1)
        #expect(Double(bad).sanitized("scalar") == 0)
    }

    @Test("default fallbacks are .zero")
    func defaultFallbacks() {
        #expect(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1).sanitized("d") == .zero)
        #expect(CGPoint(x: CGFloat.infinity, y: 0).sanitized("d") == .zero)
        #expect(CGSize(width: CGFloat.nan, height: 0).sanitized("d") == .zero)
    }

    @Test("Int(sanitizing:) never traps", arguments: [Double.nan, .infinity, -.infinity, 1e300, -1e300])
    func intSanitizingNeverTraps(bad: Double) {
        #expect(Int(sanitizing: bad, "int", fallback: 7) == 7)
        #expect(Int32(sanitizing: bad, "int32", fallback: -1) == -1)
        #expect(Int(sanitizing: bad, "int-default") == 0)
    }

    @Test("Int(sanitizing:) truncates finite values toward zero like Int(_:)")
    func intSanitizingTruncates() {
        #expect(Int(sanitizing: 3.9, "t") == 3)
        #expect(Int(sanitizing: -3.9, "t") == -3)
        #expect(Int(sanitizing: 0.0, "t") == 0)
        #expect(Int(sanitizing: Float(59.94).rounded(), "t") == 60)
        #expect(CMTimeScale(sanitizing: 30.0, "t") == 30)
    }

    @Test("Int32(sanitizing:) rejects values that fit Int but not Int32")
    func int32OutOfRange() {
        #expect(Int(sanitizing: 1e10, "t") == 10_000_000_000)
        #expect(Int32(sanitizing: 1e10, "t", fallback: 600) == 600)
    }

    @Test("CMTime(sanitizedSeconds:) builds a valid time or the fallback, never an invalid one")
    func cmTimeSanitized() {
        let good = CMTime(sanitizedSeconds: 1.5, "t")
        #expect(good.isValid)
        #expect(good.seconds == 1.5)
        #expect(good.timescale == 600)

        let bad = CMTime(sanitizedSeconds: .nan, "t")
        #expect(bad.isValid)
        #expect(bad == .zero)

        let custom = CMTime(sanitizedSeconds: .infinity, "t", fallback: CMTime(value: 5, timescale: 1))
        #expect(custom.seconds == 5)

        // What we're replacing: the plain initializer never rejects bad
        // input — NaN silently becomes a "valid" zero and ±inf an infinite
        // time that poisons every later CMTimeAdd (observed on macOS 26).
        #expect(CMTime(seconds: .infinity, preferredTimescale: 600).isPositiveInfinity)
        #expect(CMTime(seconds: .nan, preferredTimescale: 600).isValid)
    }

    @Test("rejections are counted per context; finite values never count")
    func hitCounting() {
        let ctx = "count-\(UUID().uuidString)"
        #expect(GeometrySanitizer.hitCount(ctx) == 0)
        _ = CGRect(x: CGFloat.nan, y: 0, width: 0, height: 0).sanitized(ctx)
        _ = CGRect(x: 1, y: 1, width: 1, height: 1).sanitized(ctx)
        _ = Int(sanitizing: Double.infinity, ctx)
        _ = CMTime(sanitizedSeconds: -.infinity, ctx)
        #expect(GeometrySanitizer.hitCount(ctx) == 3)
    }

    @Test("context is an autoclosure — never evaluated for finite input")
    func contextIsLazy() {
        var evaluated = false
        func ctx() -> String { evaluated = true; return "lazy" }
        _ = CGRect(x: 0, y: 0, width: 1, height: 1).sanitized(ctx())
        _ = Int(sanitizing: 1.0, ctx())
        #expect(!evaluated)
        _ = CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1).sanitized(ctx())
        #expect(evaluated)
    }

    // The Companion's saver window dump converted `kCGWindowBounds`
    // doubles with a bare `Int(_:)`; the window server reports NaN / ±inf
    // / 1.8e308 bounds for lock-screen transition windows and the second
    // saver start of 2026-09-15 trapped on one (user crash bundle).
    @Test("window dump bounds never trap and keep bogus values readable")
    func windowDumpBoundsAreTrapFree() {
        #expect(WallpaperWindowDump.describeBounds(["X": 0, "Y": 1329, "Width": 0, "Height": 0]) == "(0,1329 0x0)")
        #expect(WallpaperWindowDump.describeBounds(["X": 578.6, "Y": -459.4, "Width": 900, "Height": 450]) == "(578,-459 900x450)")
        #expect(WallpaperWindowDump.describeBounds([:]) == "(0,0 0x0)")
        let bogus = WallpaperWindowDump.describeBounds([
            "X": .nan, "Y": .infinity, "Width": -.infinity, "Height": .greatestFiniteMagnitude,
        ])
        #expect(bogus == "(nan,inf -infx1.7976931348623157e+308)")
        // Out of Int range but finite: printed raw, not truncated to 0.
        #expect(WallpaperWindowDump.describeBounds(["X": 1e12, "Y": 0, "Width": 1, "Height": 1]) == "(1000000000000.0,0 1x1)")
    }
}

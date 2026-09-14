//
//  GeometrySanitizer.swift
//  Aerial4WallpaperExtension
//
//  NaN/inf choke point for everything the extension hands to Core
//  Animation or converts to an integer.
//
//  CALayer's position/bounds setters raise an ObjC exception on a
//  non-finite value, and that abort takes the whole extension with it
//  (black desktop) — the 2026-08-28 field crash. Swift's Int(Double)
//  traps the same way on NaN/inf/out-of-range. Neither is catchable
//  from Swift, so the only defence is to never hand them the value.
//
//  Rules, enforced by the `appex_raw_geometry_setter` SwiftLint rule:
//   • every `.frame / .position / .bounds / .contentsRect / .anchorPoint =`
//     in this target goes through `.sanitized("context")`, unless it
//     copies another layer's already-accepted geometry;
//   • float→integer conversions fed by time or geometry math use
//     `Int(sanitizing:)` / `CMTimeScale(sanitizing:)`;
//   • seconds→CMTime uses `CMTime(sanitizedSeconds:)`.
//
//  A rejected value is replaced by the fallback and logged once per
//  context (then every 1000th hit), so a poisoned pipeline shows up in
//  wallpaper.txt as `🧭 NaN guard [context]` without flooding it.
//

import CoreGraphics
import CoreMedia
import Foundation
import os

enum GeometrySanitizer {
    private static let hits = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    /// Count a rejection for `context` and log the first one (and every
    /// 1000th after that).
    static func report(_ context: String, offending: String, fallback: String) {
        let count = hits.withLock { state -> Int in
            let next = (state[context] ?? 0) + 1
            state[context] = next
            return next
        }
        guard count == 1 || count % 1000 == 0 else { return }
        debugLog("  🧭 NaN guard [\(context)] #\(count): \(offending) → \(fallback)")
    }

    /// How many values have been rejected under `context` so far.
    static func hitCount(_ context: String) -> Int {
        hits.withLock { $0[context] ?? 0 }
    }
}

// MARK: - Core Graphics geometry

extension CGRect {
    /// `true` when every component is finite — what CALayer accepts.
    var isFiniteRect: Bool {
        origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite
    }

    /// The rect itself when finite, otherwise `fallback` (logged once).
    func sanitized(_ context: @autoclosure () -> String, fallback: CGRect = .zero) -> CGRect {
        guard !isFiniteRect else { return self }
        GeometrySanitizer.report(context(), offending: "\(self)", fallback: "\(fallback)")
        return fallback
    }
}

extension CGPoint {
    var isFinitePoint: Bool { x.isFinite && y.isFinite }

    func sanitized(_ context: @autoclosure () -> String, fallback: CGPoint = .zero) -> CGPoint {
        guard !isFinitePoint else { return self }
        GeometrySanitizer.report(context(), offending: "\(self)", fallback: "\(fallback)")
        return fallback
    }
}

extension CGSize {
    var isFiniteSize: Bool { width.isFinite && height.isFinite }

    func sanitized(_ context: @autoclosure () -> String, fallback: CGSize = .zero) -> CGSize {
        guard !isFiniteSize else { return self }
        GeometrySanitizer.report(context(), offending: "\(self)", fallback: "\(fallback)")
        return fallback
    }
}

// MARK: - Scalars

extension BinaryFloatingPoint {
    /// The value itself when finite, otherwise `fallback` (logged once).
    /// For scalar CA/CM inputs — contentsScale, rates, opacities.
    func sanitized(_ context: @autoclosure () -> String, fallback: Self = 0) -> Self {
        guard !isFinite else { return self }
        GeometrySanitizer.report(context(), offending: "\(self)", fallback: "\(fallback)")
        return fallback
    }
}

extension FixedWidthInteger {
    /// Trap-free float→integer conversion: truncates toward zero like
    /// `Int(_:)`, but NaN, ±inf and out-of-range values collapse to
    /// `fallback` instead of aborting the process.
    init<F: BinaryFloatingPoint>(
        sanitizing value: F,
        _ context: @autoclosure () -> String,
        fallback: Self = 0
    ) {
        if let exact = Self(exactly: value.rounded(.towardZero)) {
            self = exact
            return
        }
        GeometrySanitizer.report(context(), offending: "\(value)", fallback: "\(fallback)")
        self = fallback
    }
}

// MARK: - Core Media

extension CMTime {
    /// `CMTime(seconds:preferredTimescale:)` never rejects bad input: NaN
    /// silently becomes a "valid" zero (rounded flag set) and ±inf becomes
    /// an infinite time that propagates into every later CMTime sum.
    /// Collapse to `fallback` up front and log it instead.
    init(
        sanitizedSeconds seconds: Double,
        preferredTimescale: CMTimeScale = 600,
        _ context: @autoclosure () -> String,
        fallback: CMTime = .zero
    ) {
        guard seconds.isFinite else {
            GeometrySanitizer.report(context(), offending: "\(seconds)s", fallback: "\(fallback.seconds)s")
            self = fallback
            return
        }
        self = CMTime(seconds: seconds, preferredTimescale: preferredTimescale)
    }
}

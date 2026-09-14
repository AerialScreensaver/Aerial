//
//  PropertyTesting.swift
//  AerialTests
//
//  A deliberately small property-testing kit for Swift Testing: a seeded
//  generator so every failure is reproducible, edge-value tables for the
//  inputs that have crashed us in the field (NaN, ±inf, zero, negatives,
//  empty collections, invalid CMTime), and `forAll` to run a property
//  over N random cases while recording the seed and case number on
//  failure. There is no shrinker — the seed plus the case index is the
//  reproduction.
//
//  Usage:
//      forAll(iterations: 500, seed: 42) { rng, index in
//          let rect = rng.finiteRect()
//          #expect(rect.sanitized("t") == rect, "\(rng.trail)")
//      }
//

import CoreGraphics
import CoreMedia
import Foundation
import Testing

/// SplitMix64: tiny, fast, and identical on every run for a given seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    let seed: UInt64
    /// Case index the runner is on — part of every failure message.
    var caseIndex: Int = 0

    init(seed: UInt64) {
        self.seed = seed
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// "seed=… case=…" — put it in every `#expect` comment.
    var trail: String { "seed=\(seed) case=\(caseIndex)" }
}

// MARK: - Edge-value tables

enum EdgeValues {
    /// Every CGFloat the field has taught us to fear, plus the boring ones.
    static let cgFloats: [CGFloat] = [
        .nan, .infinity, -.infinity, 0, -0.0, 1, -1, 0.5, -0.5,
        .leastNonzeroMagnitude, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
        1e-300, 1e300, 2560, 1440, -2560, 5120.0001,
    ]
    static let doubles: [Double] = cgFloats.map(Double.init)
    static let cmTimes: [CMTime] = [
        .invalid, .indefinite, .positiveInfinity, .negativeInfinity, .zero,
        CMTime(value: 0, timescale: 0),          // zero timescale
        CMTime(value: 1, timescale: 600),
        CMTime(value: -1, timescale: 600),
        CMTime(value: .max, timescale: 1),
        CMTime(value: .min, timescale: 1),
        CMTime(seconds: 1.5, preferredTimescale: 1),   // rounded flag
        CMTime(value: 30, timescale: 90_000),
    ]
}

// MARK: - Generators

extension SeededGenerator {
    mutating func bool(probability: Double = 0.5) -> Bool {
        Double.random(in: 0..<1, using: &self) < probability
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    /// Uniform in range, with a 10 % chance of one of the range's edges.
    mutating func double(_ range: ClosedRange<Double>) -> Double {
        if bool(probability: 0.1) { return bool() ? range.lowerBound : range.upperBound }
        return Double.random(in: range, using: &self)
    }

    /// Finite CGFloat, mostly screen-sized, sometimes tiny or huge.
    mutating func finiteCGFloat(_ range: ClosedRange<CGFloat> = -8192...8192) -> CGFloat {
        switch int(0...9) {
        case 0: return 0
        case 1: return bool() ? 1e-6 : 1e6
        default: return CGFloat.random(in: range, using: &self)
        }
    }

    /// Any CGFloat: 25 % of the time an edge value (NaN, ±inf, extremes).
    mutating func anyCGFloat() -> CGFloat {
        bool(probability: 0.25) ? EdgeValues.cgFloats.randomElement(using: &self)! : finiteCGFloat()
    }

    mutating func finiteRect() -> CGRect {
        CGRect(x: finiteCGFloat(), y: finiteCGFloat(),
               width: finiteCGFloat(0...8192), height: finiteCGFloat(0...8192))
    }

    /// A rect a display might report: positive size, any origin.
    mutating func displayFrame() -> CGRect {
        CGRect(x: finiteCGFloat(-10_000...10_000), y: finiteCGFloat(-10_000...10_000),
               width: CGFloat(int(1...8192)), height: CGFloat(int(1...8192)))
    }

    mutating func anyRect() -> CGRect {
        CGRect(x: anyCGFloat(), y: anyCGFloat(), width: anyCGFloat(), height: anyCGFloat())
    }

    /// Valid CMTime with a random timescale — comparisons must cope with mixed scales.
    mutating func validCMTime(seconds: ClosedRange<Double> = -10...600) -> CMTime {
        let timescale = [1, 24, 30, 600, 1000, 90_000].randomElement(using: &self)!
        return CMTime(seconds: double(seconds), preferredTimescale: CMTimeScale(timescale))
    }

    /// Any CMTime: 20 % of the time an edge value (invalid, indefinite, ±inf, zero timescale).
    mutating func anyCMTime() -> CMTime {
        bool(probability: 0.2) ? EdgeValues.cmTimes.randomElement(using: &self)! : validCMTime()
    }

    mutating func element<C: Collection>(of collection: C) -> C.Element? {
        collection.randomElement(using: &self)
    }

    mutating func identifier() -> String {
        let pool = ["A", "B", "C", "D", "E", "F", "G", "H", "", "🌊", "very-long-id-\(int(0...9))"]
        return element(of: pool)!
    }
}

// MARK: - Runner

/// Run `property` for `iterations` seeded cases. Failures inside carry
/// `rng.trail` so a red run names the exact case; rerun with the same seed
/// to reproduce. Any Swift trap inside ends the whole test process — that
/// is the finding, not a harness bug.
func forAll(
    iterations: Int = 300,
    seed: UInt64 = 0xAE71A1,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ property: (inout SeededGenerator, Int) throws -> Void
) rethrows {
    var rng = SeededGenerator(seed: seed)
    for index in 0..<iterations {
        rng.caseIndex = index
        try property(&rng, index)
    }
}

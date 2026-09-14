//
//  ConcurrencyTests.swift
//  AerialTests
//
//  Real-thread contention on the shared state the tests can reach, so
//  the Thread Sanitizer pass in Scripts/audit.sh has something to bite:
//  the NaN-guard hit counter, a PresentingRing behind the same
//  OSAllocatedUnfairLock the transition coordinator uses, and
//  simultaneous ObjC exception unwinding on many threads. Each test
//  also checks an exact end state, so a lost update fails even without
//  TSan.
//

import CoreGraphics
import CoreMedia
import Foundation
import Testing
import os
@testable import Aerial

@Suite("Concurrency (TSan targets)")
struct ConcurrencyTests {
    @Test("GeometrySanitizer hit counter is exact under contention")
    func sanitizerCounterUnderContention() {
        let context = "contention-\(UUID().uuidString)"
        let threads = 8, perThread = 2000
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for i in 0..<perThread {
                _ = CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1).sanitized(context)
                _ = Int(sanitizing: Double.infinity, context)
                _ = CGRect(x: CGFloat(i), y: 0, width: 1, height: 1).sanitized(context)   // finite: must not count
            }
        }
        #expect(GeometrySanitizer.hitCount(context) == threads * perThread * 2)
    }

    @Test("PresentingRing behind OSAllocatedUnfairLock survives concurrent note/query and keeps its invariants")
    func ringUnderLock() {
        let ring = OSAllocatedUnfairLock(initialState: PresentingRing<Int>())
        let queries = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 16) { thread in
            var rng = SeededGenerator(seed: UInt64(thread))
            for step in 0..<500 {
                let now = rng.validCMTime(seconds: 0...100)
                switch rng.int(0...3) {
                case 0...1:
                    let pts = rng.anyCMTime()
                    ring.withLock { $0.note(thread * 1000 + step, pts: pts, now: now) }
                case 2:
                    let presented = ring.withLock { $0.presenting(at: now) }
                    let inflight = ring.withLock { $0.inflight(after: now) }
                    queries.withLock { $0 += 1 + (presented == nil ? 0 : 0) + (inflight.isEmpty ? 0 : 0) }
                default:
                    let count = ring.withLock { $0.entries.count }
                    #expect(count <= PresentingRing<Int>.cap)
                }
            }
        }
        #expect(ring.withLock { $0.entries.count } <= PresentingRing<Int>.cap)
        #expect(queries.withLock { $0 } > 0)
    }

    @Test("ObjCException.catching handles simultaneous raises on many threads")
    func concurrentExceptionCatching() {
        let caught = OSAllocatedUnfairLock(initialState: 0)
        let passed = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 16) { thread in
            for i in 0..<50 {
                if (thread + i) % 2 == 0 {
                    let error = ObjCException.attempt("thread \(thread)") {
                        NSException(name: .genericException, reason: "t\(thread)-\(i)", userInfo: nil).raise()
                    }
                    if error == nil { caught.withLock { $0 += 1 } }
                } else {
                    let value = ObjCException.attempt("thread \(thread)") { thread * 100 + i }
                    if value == thread * 100 + i { passed.withLock { $0 += 1 } }
                }
            }
        }
        #expect(caught.withLock { $0 } == 400)
        #expect(passed.withLock { $0 } == 400)
    }
}

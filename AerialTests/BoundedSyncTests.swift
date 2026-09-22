//
//  BoundedSyncTests.swift
//  AerialTests
//
//  WallpaperExtension/Support/BoundedSync.swift: the bounded hop the
//  extension uses instead of `queue.sync` wherever a wedged renderer
//  queue must not take the caller down with it. Also a TSan target for
//  Scripts/audit.sh (real threads, shared box).
//

import Foundation
import Testing
import os
@testable import Aerial

@Suite("BoundedSync")
struct BoundedSyncTests {
    @Test("a fast block returns its value")
    func fastPath() {
        let queue = DispatchQueue(label: "bounded-sync-fast")
        let value: Int? = BoundedSync.run(on: queue, timeout: .seconds(2)) { 42 }
        #expect(value == 42)
        let text: String? = BoundedSync.run(on: queue, timeout: .seconds(2)) { "ok" }
        #expect(text == "ok")
    }

    @Test("a wedged queue times out with nil; the late block still runs exactly once and its result is dropped")
    func timesOutThenRunsLate() {
        let queue = DispatchQueue(label: "bounded-sync-wedged")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }          // wedge the queue
        let runs = OSAllocatedUnfairLock(initialState: 0)

        let started = Date()
        let value: Int? = BoundedSync.run(on: queue, timeout: .milliseconds(200)) {
            runs.withLock { $0 += 1 }
            return 7
        }
        let waited = Date().timeIntervalSince(started)
        #expect(value == nil)
        #expect(waited >= 0.19 && waited < 1.5)
        #expect(runs.withLock { $0 } == 0)

        gate.signal()                        // free the queue → the late block runs
        let drained = DispatchSemaphore(value: 0)
        queue.async { drained.signal() }
        #expect(drained.wait(timeout: .now() + 2) == .success)
        #expect(runs.withLock { $0 } == 1)
    }

    @Test("many callers with mixed timeouts never deadlock and every block runs once")
    func contention() {
        let queue = DispatchQueue(label: "bounded-sync-contention")
        let hits = OSAllocatedUnfairLock(initialState: 0)
        let threads = 16, perThread = 50
        DispatchQueue.concurrentPerform(iterations: threads) { i in
            for j in 0..<perThread {
                let slow = (i + j) % 7 == 0
                let value: Int? = BoundedSync.run(on: queue, timeout: slow ? .milliseconds(1) : .seconds(20)) {
                    if slow { Thread.sleep(forTimeInterval: 0.002) }
                    hits.withLock { $0 += 1 }
                    return j
                }
                if !slow { #expect(value == j) }
            }
        }
        let drained = DispatchSemaphore(value: 0)
        queue.async { drained.signal() }
        #expect(drained.wait(timeout: .now() + 20) == .success)
        #expect(hits.withLock { $0 } == threads * perThread)
    }
}

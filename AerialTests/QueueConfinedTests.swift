//
//  QueueConfinedTests.swift
//  AerialTests
//
//  The primitive behind `ActiveWallpaper`'s window state: writes confined
//  to one serial queue, reads from anywhere through a lock-backed mirror.
//  Real-thread contention so the Thread Sanitizer pass in Scripts/audit.sh
//  has something to bite, plus an exact end state and an invariant that a
//  torn read would break even without TSan.
//

import Foundation
import Testing
import os
@testable import Aerial

@Suite("QueueConfined (TSan targets)")
struct QueueConfinedTests {

    /// The two fields that must agree in the real window state: a window
    /// is either attached to its CURRENT key or to nothing — a reader must
    /// never see `attached` naming a key the window was re-keyed away
    /// from.
    private struct WindowLike {
        var key = "k0"
        var attached: String?
        var rekeys = 0
        var attaches = 0
    }

    @Test("writers on the owner queue vs readers on other threads: exact end state, never a torn mirror")
    func writersVersusReaders() {
        let owner = DispatchQueue(label: "queueconfined-test-owner")
        let box = QueueConfined(owner: owner, initialState: WindowLike())
        let rounds = 3_000
        let group = DispatchGroup()
        for i in 0..<rounds {
            owner.async(group: group) {
                // The rekey sequence: detach, move the key, attach — three
                // separate edits, so a reader can land between any two.
                box.mutate { $0.attached = nil }
                box.mutate { $0.key = "k\(i + 1)"; $0.rekeys += 1 }
                box.mutate { $0.attached = $0.key; $0.attaches += 1 }
            }
        }
        let torn = OSAllocatedUnfairLock(initialState: 0)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<2_000 {
                let m = box.mirror
                if let attached = m.attached, attached != m.key {
                    torn.withLock { $0 += 1 }
                }
                reads.withLock { $0 += 1 }
            }
        }
        group.wait()
        let final = box.mirror
        #expect(final.rekeys == rounds)
        #expect(final.attaches == rounds)
        #expect(final.key == "k\(rounds)")
        #expect(final.attached == final.key)
        #expect(torn.withLock { $0 } == 0)
        #expect(reads.withLock { $0 } == 16_000)
    }

    @Test("mutate inside an owner.sync block from another thread passes the owner check and hands back the body's result")
    func mutateFromSyncHop() {
        final class Token {}
        struct Holder { var token: Token? }
        let owner = DispatchQueue(label: "queueconfined-test-owner-sync")
        let token = Token()
        let box = QueueConfined(owner: owner, initialState: Holder(token: token))
        // The XPC handler shape: a foreign thread `sync`s onto the owner
        // and takes a reference out of the state to act on it afterwards.
        let taken: Token? = owner.sync {
            box.mutate { state -> Token? in
                defer { state.token = nil }
                return state.token
            }
        }
        #expect(taken === token)
        #expect(box.mirror.token == nil)
    }

    @Test("a reader on the owner queue sees its own writes immediately")
    func readAfterWriteOnOwner() {
        let owner = DispatchQueue(label: "queueconfined-test-owner-raw")
        let box = QueueConfined(owner: owner, initialState: 0)
        let seen: [Int] = owner.sync {
            var out: [Int] = []
            for i in 1...5 {
                box.mutate { $0 = i }
                out.append(box.mirror)
            }
            return out
        }
        #expect(seen == [1, 2, 3, 4, 5])
    }
}

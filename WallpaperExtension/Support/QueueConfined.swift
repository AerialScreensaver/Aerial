// Queue-confined state with a lock-backed mirror.
//
// The shape behind `ActiveWallpaper` (X4, 2026-10-13): a value that only
// ONE serial queue may change, published through a lock so any other
// thread can read a consistent copy without ever waiting on that queue.
// The lock is the storage — there is no separate publish step, so a
// reader never sees a torn or stale-by-one value, and a writer never
// blocks behind a reader for longer than a copy.
//
// Why both: a queue alone makes writes atomic but forces every reader to
// hop onto it (the 0xDEAD10CC history — a snapshot XPC that waits behind
// a busy queue gets the process killed); a lock alone makes each field
// safe but leaves check-then-act sequences racy. Confining the writes
// and mirroring the reads gives both properties.
//
// Rules for `mutate` bodies: pure value edits, no callbacks, no calls
// into other locks (take a reference OUT via the return value and act on
// it after the lock is released), no `mirror` reads (the lock is not
// recursive). The owner-queue check is Debug-only and traps.

import Foundation
import os

final class QueueConfined<State>: @unchecked Sendable {
    /// The one queue allowed to call `mutate`.
    let owner: DispatchQueue
    private let storage: OSAllocatedUnfairLock<State>

    init(owner: DispatchQueue, initialState: State) {
        self.owner = owner
        self.storage = OSAllocatedUnfairLock(uncheckedState: initialState)
    }

    /// Lock-protected copy of the state. Any thread; never blocks on
    /// `owner`. Read it ONCE per observation and compare fields from the
    /// same copy.
    var mirror: State {
        storage.withLockUnchecked { $0 }
    }

    /// The only writer. Must run on `owner` — directly, through
    /// `owner.async`, or inside an `owner.sync` block from another thread
    /// (dispatch counts all three as "on the queue"). Returns the body's
    /// result.
    @discardableResult
    func mutate<T>(_ body: (inout State) throws -> T) rethrows -> T {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(owner))
        #endif
        return try storage.withLockUnchecked(body)
    }
}

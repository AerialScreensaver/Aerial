// Bounded synchronous hop onto a serial dispatch queue.
//
// Every cross-queue read in the wallpaper extension used to be a bare
// `queue.sync` onto the renderer queue. When that queue wedges inside
// AVFoundation (a `copyNextSampleBuffer` that never returned after a
// wake — the 2026-09-20 four-display DisplayLink field bundle), every
// caller piled up behind it: the main thread, the XPC handler tasks
// WallpaperAgent was waiting on, the diagnostics queue. The agent then
// killed the process ~30 s later (RunningBoard 0xDEAD10CC) — the "black
// flash + video swap after wake" the reporter saw.
//
// `BoundedSync.run` waits at most `timeout`; on expiry it returns nil and
// the caller serves a degraded answer instead of blocking. The block
// STILL RUNS LATER when the queue frees up (dispatch has no cancel) —
// its result is discarded. Callers therefore pass pure reads, or work
// whose late execution is intended (a teardown body).

import Foundation
import os

enum BoundedSync {
    /// Run `work` on `queue` and wait up to `timeout` for its result.
    /// nil = timed out; the block will still execute later.
    static func run<T>(on queue: DispatchQueue, timeout: DispatchTimeInterval,
                       _ work: @escaping () -> T) -> T? {
        let box = OSAllocatedUnfairLock<T?>(uncheckedState: nil)
        let done = DispatchSemaphore(value: 0)
        queue.async {
            let value = work()
            box.withLock { $0 = value }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.withLock { $0 }
    }
}

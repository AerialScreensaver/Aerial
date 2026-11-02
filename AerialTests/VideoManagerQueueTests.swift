//
//  VideoManagerQueueTests.swift
//  AerialTests
//
//  The download queue's bookkeeping, on a suspended OperationQueue so
//  nothing ever touches the network: one live operation per video, and a
//  format change cancels what is queued without stranding the serial
//  queue on an operation that was cancelled before it started.
//

import Foundation
import Testing
@testable import Aerial

@Suite("VideoManager — queue dedupe and cancellation")
struct VideoManagerQueueTests {

    private func suspendedQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "videodownload-test"
        queue.maxConcurrentOperationCount = 1
        queue.isSuspended = true
        return queue
    }

    private func video(_ id: String) -> AerialVideo {
        let source = Source(name: "queuetest", description: "", manifestUrl: "https://example.invalid/entries.json",
                            type: .tvOS12, scenes: [.nature], isCachable: true, license: "", more: "")
        return AerialVideo(id: id, name: "Test", secondaryName: id, type: "video", timeOfDay: "day",
                           scene: "nature", urls: [.v1080pH264: "https://example.invalid/\(id).mov"],
                           source: source, poi: [:])
    }

    @Test("queueing the same video twice hands back the live operation")
    func dedupe() {
        let queue = suspendedQueue()
        let manager = VideoManager(queue: queue)
        let first = manager.queueDownload(video("a"))
        let second = manager.queueDownload(video("a"))
        #expect(first === second)
        #expect(manager.queuedVideoIds == ["a"])
        #expect(queue.operationCount == 1)

        let other = manager.queueDownload(video("b"))
        #expect(other !== first)
        #expect(manager.queuedVideoIds == ["a", "b"])
        #expect(queue.operationCount == 2)
    }

    @Test("a format change cancels everything queued, and the queue drains the cancelled operations")
    func formatChangeCancels() async throws {
        let queue = suspendedQueue()
        let manager = VideoManager(queue: queue)
        let a = manager.queueDownload(video("a"))
        let b = manager.queueDownload(video("b"))

        manager.cancelDownloadsForFormatChange()
        #expect(a.isCancelled && b.isCancelled)
        #expect(manager.queuedVideoIds.isEmpty)

        // Cancelled-before-start operations must still reach `isFinished`
        // once the queue gets to them, or a serial queue would wedge on
        // the first one forever.
        queue.isSuspended = false
        for _ in 0..<40 where !(a.isFinished && b.isFinished) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(a.isFinished && b.isFinished)
        #expect(queue.operationCount == 0)

        // Re-queueing after cancellation starts a fresh operation. Park the
        // queue again first: on a live queue the fresh operation starts at
        // once, hops to main to open a real download, and outlives this
        // function — it finished on a queue and manager the test had
        // already released (2026-10-14 crash in __NSOQSchedule).
        queue.isSuspended = true
        let again = manager.queueDownload(video("a"))
        #expect(again !== a)
        #expect(!again.isExecuting && !again.isFinished)
        #expect(manager.queuedVideoIds == ["a"])
    }

    @Test("cancelling one download leaves the others queued")
    func cancelOne() {
        let queue = suspendedQueue()
        let manager = VideoManager(queue: queue)
        let a = manager.queueDownload(video("a"))
        let b = manager.queueDownload(video("b"))

        manager.cancelDownload(id: "a")
        #expect(a.isCancelled)
        #expect(!b.isCancelled)
        #expect(manager.queuedVideoIds == ["b"])

        // Unknown ids are a no-op.
        manager.cancelDownload(id: "zzz")
        #expect(manager.queuedVideoIds == ["b"])
    }
}

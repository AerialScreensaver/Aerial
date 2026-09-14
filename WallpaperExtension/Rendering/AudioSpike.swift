// TEMPORARY feasibility spike — safe to delete once audio ships.
//
// Answers one question: can a WallpaperAgent-hosted appex actually
// reach the audio output on current macOS? (Precedent says yes — the
// early extension AVPlayer played audio — but that was several macOS
// releases ago.)
//
// Trigger: `touch /Users/Shared/Aerial/audio-spike`, then re-select the
// wallpaper so a fresh renderer is created. Runs ONCE per process:
//   Phase A (0–6 s):  headless unmuted AVPlayer on the current video —
//                     does ANY audio route work at all?
//   Phase B (6–14 s): the real stack — AVSampleBufferRenderSynchronizer
//                     + AVSampleBufferAudioRenderer + audio-only
//                     AVAssetReader (LPCM) — does the shipping pipeline
//                     work in this process?
// Watch wallpaper.txt for the 🔊 [AudioSpike] lines (and listen).

import AVFoundation
import CoreMedia

enum AudioSpike {
    private static let flagPath = "/Users/Shared/Aerial/audio-spike"
    private static let queue = DispatchQueue(label: "aerial-audio-spike")
    // Every static below is touched only from `queue` (serial) — confined, not shared.
    nonisolated(unsafe) private static var started = false

    // Kept alive for the duration of the spike.
    nonisolated(unsafe) private static var player: AVPlayer?
    nonisolated(unsafe) private static var synchronizer: AVSampleBufferRenderSynchronizer?
    nonisolated(unsafe) private static var audioRenderer: AVSampleBufferAudioRenderer?
    nonisolated(unsafe) private static var reader: AVAssetReader?
    nonisolated(unsafe) private static var samplesEnqueued = 0

    static func runIfRequested(videoURL: URL) {
        queue.async {
            guard !started, FileManager.default.fileExists(atPath: flagPath) else { return }
            started = true
            debugLog("🔊 [AudioSpike] flag present — phase A (AVPlayer) on \(videoURL.lastPathComponent)")
            runPhaseA(videoURL: videoURL)
            queue.asyncAfter(deadline: .now() + 6) {
                stopPhaseA()
                runPhaseB(videoURL: videoURL)
            }
            queue.asyncAfter(deadline: .now() + 14) {
                stopPhaseB()
                debugLog("🔊 [AudioSpike] done")
            }
        }
    }

    private static func runPhaseA(videoURL: URL) {
        let p = AVPlayer(url: videoURL)
        p.isMuted = false
        p.volume = 0.3
        p.preventsDisplaySleepDuringVideoPlayback = false
        p.play()
        player = p
        queue.asyncAfter(deadline: .now() + 3) {
            let status: String
            switch p.timeControlStatus {
            case .playing: status = "playing"
            case .paused: status = "paused"
            case .waitingToPlayAtSpecifiedRate: status = "waiting(\(p.reasonForWaitingToPlay?.rawValue ?? "?"))"
            @unknown default: status = "unknown"
            }
            debugLog("🔊 [AudioSpike] phase=A status=\(status) muted=\(p.isMuted) itemStatus=\(p.currentItem?.status.rawValue ?? -1) error=\(String(describing: p.error ?? p.currentItem?.error))")
        }
    }

    private static func stopPhaseA() {
        player?.pause()
        player = nil
    }

    private static func runPhaseB(videoURL: URL) {
        debugLog("🔊 [AudioSpike] phase B (AVSampleBufferAudioRenderer)")
        let asset = AVURLAsset(url: videoURL)
        let spikeAsset = asset
        Task.detached { @Sendable in
            guard let track = try? await spikeAsset.loadTracks(withMediaType: .audio).first else {
                debugLog("🔊 [AudioSpike] phase=B no audio track in \(spikeAsset.url.lastPathComponent) — pick a video with audio to test")
                return
            }
            nonisolated(unsafe) let audioTrack = track
            queue.async {
                guard let newReader = try? AVAssetReader(asset: spikeAsset) else {
                    debugLog("🔊 [AudioSpike] phase=B reader create failed")
                    return
                }
                let output = AVAssetReaderTrackOutput(
                    track: audioTrack,
                    outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
                )
                output.alwaysCopiesSampleData = false
                newReader.add(output)
                newReader.startReading()

                let sync = AVSampleBufferRenderSynchronizer()
                let renderer = AVSampleBufferAudioRenderer()
                renderer.volume = 0.3
                sync.addRenderer(renderer)
                reader = newReader
                synchronizer = sync
                audioRenderer = renderer
                samplesEnqueued = 0

                renderer.requestMediaDataWhenReady(on: queue) {
                    while renderer.isReadyForMoreMediaData {
                        guard let sample = output.copyNextSampleBuffer() else {
                            renderer.stopRequestingMediaData()
                            return
                        }
                        renderer.enqueue(sample)
                        samplesEnqueued += 1
                    }
                }
                sync.setRate(1.0, time: .zero)

                queue.asyncAfter(deadline: .now() + 4) {
                    debugLog("🔊 [AudioSpike] phase=B enqueued=\(samplesEnqueued) rendererStatus=\(renderer.status.rawValue) error=\(String(describing: renderer.error)) syncTime=\(String(format: "%.1f", CMTimebaseGetTime(sync.timebase).seconds))s")
                }
            }
        }
    }

    private static func stopPhaseB() {
        synchronizer?.setRate(0, time: .zero)
        audioRenderer?.stopRequestingMediaData()
        audioRenderer?.flush()
        reader?.cancelReading()
        reader = nil
        synchronizer = nil
        audioRenderer = nil
    }
}

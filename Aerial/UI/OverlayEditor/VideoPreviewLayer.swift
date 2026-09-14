//
//  VideoPreviewLayer.swift
//  Aerial
//
//  NSViewRepresentable wrapping AVPlayerLayer for the overlay editor preview.
//

import SwiftUI
import AVFoundation
import CoreImage

struct VideoPreviewLayer: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> VideoPreviewNSView {
        let view = VideoPreviewNSView()
        if let url = url {
            view.loadVideo(url: url)
        }
        return view
    }

    func updateNSView(_ nsView: VideoPreviewNSView, context: Context) {
        // URL changes are rare; only reload if needed
    }
}

class VideoPreviewNSView: NSView {
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    func loadVideo(url: URL) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        // Apply color invert filter if enabled (accessibility).
        // Mirrors PlayerCoordinator: invert in sRGB so wide-gamut sources look right.
        if AerialSaverView.readInvertColorsFromCompanionJSON() {
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            item.videoComposition = AVMutableVideoComposition(
                asset: asset,
                applyingCIFiltersWithHandler: { request in
                    let inSRGB = request.sourceImage.matchedFromWorkingSpace(to: srgb)!
                    let inverted = inSRGB.applyingFilter("CIColorInvert")
                    let backToWorking = inverted.matchedToWorkingSpace(from: srgb)!
                    request.finish(with: backToWorking, context: nil)
                })
        }

        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        self.player = player

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = NSColor.black.cgColor
        self.layer?.addSublayer(layer)
        playerLayer = layer

        // Seek to ~30% for a representative frame
        Task {
            do {
                let duration = try await asset.load(.duration)
                if duration.seconds > 0 {
                    let seekTime = CMTime(seconds: duration.seconds * 0.3, preferredTimescale: 600)
                    await player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    await MainActor.run { player.pause() }
                }
            } catch {
                // Duration not available — just pause on first frame
                await MainActor.run { player.pause() }
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }

    deinit {
        player?.pause()
        player = nil
    }
}

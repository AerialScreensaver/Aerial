// Per-display snapshot cache on disk.
//
// ExtensionKit kills the wallpaper-extension process every ~30–45s. On
// every fresh process, the slow path of `acquire` builds the renderer
// asynchronously and replies before the first frame has decoded — the
// rootLayer's `aerialBlue` background shows for ~100ms ("blue flash").
//
// We dodge this by keeping the last known frame per display on disk.
// On a cold-start acquire we set `rootLayer.contents` to the cached
// PNG before reply; AVSampleBufferDisplayLayer (added as a sublayer)
// is transparent until its first frame is enqueued, so the cached
// image shows through until live playback takes over.
//
// Storage root: `/Users/Shared/Aerial/wallpaper-snapshots/`. The
// agent-provided `cacheDirectory` lives in WallpaperAgent's sandbox
// container, which our extension can't write to (entitlements only
// cover `/Users/Shared/`). Granting access to the agent's container
// would need a per-user temporary-exception path, not worth it.

import Accelerate
import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

private let snapshotDir = URL(fileURLWithPath: "/Users/Shared/Aerial/wallpaper-snapshots", isDirectory: true)

private func snapshotURL(displayID: UInt32) -> URL {
    snapshotDir.appendingPathComponent("did-\(displayID).heic")
}

/// Pre-HEIC snapshots (≤ 2026-09) — still readable, retired on the next
/// successful HEIC write.
private func legacySnapshotURL(displayID: UInt32) -> URL {
    snapshotDir.appendingPathComponent("did-\(displayID).png")
}

/// Write a CGImage to disk as PNG. Atomic write so we never read a
/// half-written file. Errors are logged loudly — silent `try?` here
/// previously masked a sandbox failure that broke the snapshot cache
/// entirely (regression from the cacheDirectory adoption).
func writeSnapshot(_ image: CGImage, for displayID: UInt32) {
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
    } catch {
        debugLog("  [SnapshotCache] mkdir failed for \(snapshotDir.path): \(error)")
        return
    }
    let url = snapshotURL(displayID: displayID)
    // HEIC first (hardware HEVC): a photographic 4K frame lands ~0.4 MB
    // vs ~4 MB as lossless PNG — the PNG volume is what tripped macOS's
    // daily disk-write budget in the 2026-08-29 field bundle (PNG also
    // ignores `.compressionFactor`, so there was no smaller PNG to ask
    // for). PNG remains only as the encode-failure fallback.
    let heic = NSMutableData()
    var encoded = false
    if let dest = CGImageDestinationCreateWithData(heic as CFMutableData, "public.heic" as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        encoded = CGImageDestinationFinalize(dest)
    }
    do {
        if encoded {
            try (heic as Data).write(to: url, options: .atomic)
            // Retire the pre-HEIC file so the loader can't resurrect a
            // stale frame from it.
            try? fm.removeItem(at: legacySnapshotURL(displayID: displayID))
        } else {
            debugLog("  [SnapshotCache] HEIC encode failed for did=\(displayID) — writing PNG fallback")
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                debugLog("  [SnapshotCache] failed to encode PNG for did=\(displayID)")
                return
            }
            try png.write(to: legacySnapshotURL(displayID: displayID), options: .atomic)
        }
    } catch {
        debugLog("  [SnapshotCache] write failed for did=\(displayID) at \(url.path): \(error)")
    }
}

// MARK: - Cheap pixel-buffer → BGRA (the CIContext-render replacement)

/// Convert a decoded video pixel buffer (BGRA or 8-bit biplanar YCbCr —
/// the formats VideoToolbox hands us for SDR content) into BGRA bytes
/// at `destination` (rowBytes-strided). Returns false for formats we
/// don't handle (10-bit HDR etc.) — callers fall back to the CIContext
/// path. A 4K vImage convert runs ~10-20 ms vs ~250 ms for the
/// CIContext render it replaces (which fired 2-3× inside the first
/// second of every saver engage — 2026-07-27 analysis).
func blitBGRA(from buffer: CVPixelBuffer, to destination: UnsafeMutableRawPointer, rowBytes: Int) -> Bool {
    let format = CVPixelBufferGetPixelFormatType(buffer)
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    guard width > 0, height > 0 else { return false }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

    var dst = vImage_Buffer(
        data: destination,
        height: vImagePixelCount(height),
        width: vImagePixelCount(width),
        rowBytes: rowBytes
    )

    switch format {
    case kCVPixelFormatType_32BGRA:
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        var src = vImage_Buffer(
            data: base,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(buffer)
        )
        return vImageCopyBuffer(&src, &dst, 4, vImage_Flags(kvImageNoFlags)) == kvImageNoError

    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return false }
        var srcY = vImage_Buffer(
            data: yBase,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        )
        var srcCbCr = vImage_Buffer(
            data: cbcrBase,
            height: vImagePixelCount(height / 2),
            width: vImagePixelCount(width / 2),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        )
        var info = vImage_YpCbCrToARGB()
        var pixelRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ? vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255,
                                      CbCrRangeMax: 255, YpMax: 255, YpMin: 0,
                                      CbCrMax: 255, CbCrMin: 0)
            : vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235,
                                      CbCrRangeMax: 240, YpMax: 235, YpMin: 16,
                                      CbCrMax: 240, CbCrMin: 16)
        guard vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &pixelRange, &info,
            kvImage420Yp8_CbCr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags)
        ) == kvImageNoError else { return false }
        // Output memory order BGRA — matching the 'BGRA' reply
        // IOSurfaces and the premultipliedFirst|byteOrder32Little
        // CGImages used across the snapshot path. permuteMap indexes
        // into semantic ARGB.
        var permuteMap: [UInt8] = [3, 2, 1, 0]
        return vImageConvert_420Yp8_CbCr8ToARGB8888(
            &srcY, &srcCbCr, &dst, &info, &permuteMap, 255, vImage_Flags(kvImageNoFlags)
        ) == kvImageNoError

    default:
        return false
    }
}

/// BGRA CGImage from a decoded pixel buffer via the vImage blit — the
/// cheap replacement for a CIContext render when a CGImage is actually
/// needed (the PNG cache write). nil for unhandled formats.
func bgraCGImage(from buffer: CVPixelBuffer) -> CGImage? {
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    guard width > 0, height > 0,
          let ctx = CGContext(
              data: nil, width: width, height: height, bitsPerComponent: 8,
              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
          ),
          let data = ctx.data,
          blitBGRA(from: buffer, to: data, rowBytes: ctx.bytesPerRow) else { return nil }
    return ctx.makeImage()
}

/// Load the last cached frame for this display. Returns nil if no
/// snapshot has been written yet (first cold start ever) or if the
/// file is unreadable. Caller falls back to `aerialBlue`.
func loadCachedSnapshotImage(displayID: UInt32) -> CGImage? {
    // HEIC first, then the pre-2026-09 PNG (kept readable so an upgrade
    // doesn't cold-boot to aerial blue).
    for url in [snapshotURL(displayID: displayID), legacySnapshotURL(displayID: displayID)] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data) else { continue }
        return rep.cgImage
    }
    return nil
}

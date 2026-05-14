//
//  MD5Verifier.swift
//  Aerial
//
//  Streaming MD5 of a file on disk via CryptoKit. Used by the
//  download path to verify cached files against per-format MD5s
//  carried in the manifest. "Insecure.MD5" is the documented Apple
//  spelling — we are not defending against an adversary, we're
//  catching truncated downloads / bit-rot.
//

import Foundation
import CryptoKit

enum MD5Verifier {
    /// Streams the file at `url` through `Insecure.MD5` in 64 KiB
    /// chunks and returns the digest as lowercase hex. Returns nil if
    /// the file can't be opened or the read fails partway through.
    static func md5Hex(of url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }

        var hasher = Insecure.MD5()
        let bufSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufSize)

        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufSize)
            if read < 0 { return nil }
            if read == 0 { break }
            buffer.withUnsafeBufferPointer { ptr in
                let raw = UnsafeRawBufferPointer(start: ptr.baseAddress, count: read)
                hasher.update(bufferPointer: raw)
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

//
//  LiveFeedsTooling.swift
//  Aerial
//
//  Detects whether the command-line tools Live Feeds depends on
//  (`yt-dlp`, `ffmpeg`) are installed, and if so remembers where.
//  Companion-only.
//

import Foundation

final class LiveFeedsTooling {

    // MARK: - Singleton

    static let shared = LiveFeedsTooling()

    // MARK: - State

    private(set) var ytDlpPath: String?
    private(set) var ffmpegPath: String?

    static let didChangeNotification = Notification.Name("com.glouel.aerial.liveFeedsToolingDidChange")

    /// Search locations we expect Homebrew / MacPorts / manual installs to use.
    private static let candidatePrefixes = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
    ]

    private init() {
        refreshPaths()
    }

    /// Re-run the discovery pass. Called after the user dismisses the install
    /// sheet so the app picks up newly-installed tools without a restart.
    func refreshPaths() {
        ytDlpPath = locate("yt-dlp")
        ffmpegPath = locate("ffmpeg")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    // MARK: - Private

    private func locate(_ tool: String) -> String? {
        // Check static candidate paths first — avoids a Process launch for
        // the common case.
        for prefix in Self.candidatePrefixes {
            let path = "\(prefix)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fall back to `/usr/bin/env <tool>` so we respect the user's PATH
        // (e.g. asdf, mise, nix, non-standard install locations).
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", tool]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : output
    }
}

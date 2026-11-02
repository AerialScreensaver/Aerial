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
    /// Ships alongside ffmpeg in every install method we probe. Used by
    /// the My Videos importer to check codecs before an mkv/webm remux.
    private(set) var ffprobePath: String?

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

    // MARK: - Install guidance

    /// FAQ answer covering Homebrew, MacPorts and manual installs.
    static let faqURL = URL(string: "https://aerialscreensaver.github.io/faq/#youtube-and-live-streams")!

    /// Homebrew dropped Intel Macs on macOS 27; MacPorts still covers them.
    /// Checks the hardware rather than `#if arch(x86_64)` so an Apple Silicon
    /// Mac running us under Rosetta still gets Homebrew.
    static let prefersMacPorts: Bool = {
        var isArm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let hasArm = sysctlbyname("hw.optional.arm64", &isArm, &size, nil, 0) == 0 && isArm == 1
        return !hasArm && ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }()

    static var packageManagerName: String {
        prefersMacPorts ? "MacPorts" : "Homebrew"
    }

    static func installCommand(_ tool: String) -> String {
        prefersMacPorts ? "sudo port install \(tool)" : "brew install \(tool)"
    }

    /// Re-run the discovery pass. Called after the user dismisses the install
    /// sheet so the app picks up newly-installed tools without a restart.
    func refreshPaths() {
        ytDlpPath = locate("yt-dlp")
        ffmpegPath = locate("ffmpeg")
        ffprobePath = locate("ffprobe")
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

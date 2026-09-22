//
//  WallpaperExtensionHealth.swift
//  Aerial Companion
//
//  "Is WallpaperAgent hosting the extension we shipped?"
//
//  After an app update the agent keeps running the OLD appex process
//  until it is restarted — beta users were asked to `killall
//  WallpaperAgent` by hand. The extension echoes its launch-time
//  identity (version / build / executable mtime) in every
//  wallpaper-status.json write; at startup Companion compares that with
//  the appex bundled inside itself and, on a mismatch, restarts the
//  agent — once per installed build, so a restart that doesn't fix it
//  (the agent hosting ANOTHER copy of Aerial, e.g. one in the Trash)
//  can't loop. Settings → Wallpaper carries the manual button for those
//  cases, and the diagnostics bundle prints the same verdict.
//

import Darwin
import Foundation

enum WallpaperExtensionHealth {

    static let appexExecutableName = "Aerial4WallpaperExtension"

    /// Identity of the appex bundled inside THIS app — what the running
    /// extension reports once the agent has reloaded it. ExtensionKit
    /// extensions live in Contents/Extensions (not PlugIns).
    static let bundledIdentity: WallpaperExtensionIdentity = {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Extensions/\(appexExecutableName).appex")
        guard let bundle = Bundle(url: url) else { return WallpaperExtensionIdentity() }
        return WallpaperExtensionIdentity.of(bundle: bundle)
    }()

    // MARK: - Process forensics

    static func isAlive(pid: Int) -> Bool {
        pid > 0 && kill(pid_t(pid), 0) == 0
    }

    /// Executable path of a running process (same uid — no entitlement
    /// needed). Reveals WHICH copy of the appex the agent is hosting.
    static func hostedExecutablePath(pid: Int) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func isOurAppex(path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent == appexExecutableName
    }

    /// True when `path` is inside this app's bundle. False means the
    /// agent is hosting a different copy of Aerial (Trash, DerivedData,
    /// a second install) — a restart alone won't change that.
    static func isInsideThisApp(path: String) -> Bool {
        isInside(path: path, bundlePath: Bundle.main.bundleURL.path)
    }

    static func isInside(path: String, bundlePath: String) -> Bool {
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let resolvedBundle = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path
        return resolvedPath.hasPrefix(resolvedBundle + "/")
    }

    // MARK: - Verdict (Settings / diagnostics)

    enum Verdict {
        case notRunning
        /// Running, but its status predates the identity fields — an
        /// older build for sure.
        case unknownOlder
        case upToDate
        case mismatch
    }

    static func verdict(status: WallpaperStatusState?, isRunning: Bool) -> Verdict {
        guard isRunning, let status else { return .notRunning }
        let running = status.identity
        guard running.isKnown else { return .unknownOlder }
        return running.matches(bundledIdentity) ? .upToDate : .mismatch
    }

    // MARK: - Restart

    /// `killall WallpaperAgent` — the agent respawns, re-reads the
    /// wallpaper store and spawns a FRESH appex from the bundle on disk;
    /// the desktop shows the agent's cached snapshot for the gap. Same
    /// call PaperSaverKit makes after rewriting Index.plist, here without
    /// the plist rewrite. Companion is not sandboxed, so this is a plain
    /// same-uid signal. `completion` runs on the main queue once killall
    /// has exited (the respawn itself takes a further ~1-3 s).
    static func restartAgent(reason: String, completion: (() -> Void)? = nil) {
        debugLog("🔁 [ExtensionVersion] restarting WallpaperAgent (\(reason))")
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            task.arguments = ["WallpaperAgent"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            var summary: String
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                summary = "exit=\(task.terminationStatus)" + (output.isEmpty ? "" : " output=\(output)")
            } catch {
                summary = "failed to launch killall: \(error)"
            }
            debugLog("🔁 [ExtensionVersion] killall WallpaperAgent → \(summary)")
            if let completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }

    /// UI-button variant of `restartAgent`: kill the agent, wait for the
    /// respawned appex to write its identity (~1 s; 3 s covers a slow
    /// disk), then re-read the status file so "running version" lines
    /// refresh. Callers gate their button on a local flag around the
    /// await. Shared by Settings → Wallpaper, the menu bar popover and
    /// the Home dashboard.
    @MainActor
    static func restartAgentAndReload(reason: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            restartAgent(reason: reason) { continuation.resume() }
        }
        try? await Task.sleep(for: .seconds(3))
        WallpaperStatusMonitor.shared.reload()
    }

    // MARK: - Startup check

    /// Armed for ONE evaluation per app launch. Stays armed until a live
    /// extension is observed (fresh status, pid alive, pid is our appex)
    /// outside a saver/lock session — so a login-order race (extension
    /// spawning after the app) or a stale status file from the previous
    /// boot can't produce a verdict.
    private static var startupCheckPending = true

    /// Set by a startup restart; the first matching status afterwards
    /// logs `resolved` so a field log shows the fix took.
    private static var awaitingResolution = false

    /// Called from `WallpaperStatusMonitor.reload()` on every status
    /// read (init, Darwin notification, 30 s tick).
    @MainActor
    static func evaluate(status: WallpaperStatusState, isRunning: Bool) {
        let running = status.identity

        if awaitingResolution, isRunning, running.matches(bundledIdentity) {
            awaitingResolution = false
            debugLog("🔁 [ExtensionVersion] resolved — running \(running) after restart (pid \(status.pid))")
            // The extension now runs a build that reads `Sources/macOS`;
            // the pre-rename folder is no longer read by anyone.
            SourceList.removeLegacyAppleMacFoldersIfNeeded()
        }

        guard startupCheckPending else { return }
        guard isRunning, isAlive(pid: status.pid),
              let hosted = hostedExecutablePath(pid: status.pid),
              isOurAppex(path: hosted)
        else { return }  // no live extension yet — keep the check armed
        guard !status.saverActive, !status.lockedActive else { return }
        startupCheckPending = false

        let expected = bundledIdentity
        guard expected.isKnown else {
            warnLog("🔁 [ExtensionVersion] cannot read the bundled appex identity — skipping the stale-extension check")
            return
        }
        if running.matches(expected) {
            debugLog("🔁 [ExtensionVersion] running \(running) matches bundled — no restart needed (pid \(status.pid))")
            SourceList.removeLegacyAppleMacFoldersIfNeeded()
            return
        }

        let runningDesc = running.isKnown ? "\(running)" : "unknown (pre-identity build)"
        let outside = isInsideThisApp(path: hosted) ? "" : " (OUTSIDE this app bundle)"
        if Preferences.agentRestartedForIdentity == expected.description {
            warnLog("🔁 [ExtensionVersion] mismatch persists after restart — running \(runningDesc) hosted at \(hosted)\(outside), bundled \(expected) — not restarting again; use Settings → Wallpaper → Restart Wallpaper Agent")
            return
        }
        Preferences.agentRestartedForIdentity = expected.description
        awaitingResolution = true
        debugLog("🔁 [ExtensionVersion] running \(runningDesc) hosted at \(hosted)\(outside) ≠ bundled \(expected) — restarting WallpaperAgent once for this build")
        restartAgent(reason: "stale extension after update")
    }
}

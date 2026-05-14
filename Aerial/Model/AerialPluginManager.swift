//
//  ScreensaverManager.swift
//  Aerial Companion
//

import Foundation
import PaperSaverKit

enum AppLocation {
    case systemApplications   // /Applications/
    case userApplications     // ~/Applications/
    case other(String)        // somewhere else
}

/// Central plugin manager for the appex screensaver extension
class AerialPluginManager: ObservableObject {
    static let shared = AerialPluginManager()

    // MARK: - Constants

    let bundleIdentifier = "com.glouel.Aerial-App.AerialScreenSaverExtension"
    let screensaverDisplayName = "AerialScreenSaverExtension"

    // MARK: - Published State

    @Published var appLocation: AppLocation = .other("")
    @Published var isPluginRegistered: Bool = false
    @Published var isScreensaverEnabled: Bool = false

    // MARK: - Private

    private let paperSaver = PaperSaver()

    private init() {
        refreshAll()
    }

    // MARK: - Checks

    func checkAppLocation() {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasPrefix("/Applications/") {
            appLocation = .systemApplications
        } else {
            let userAppsPath = NSHomeDirectory() + "/Applications/"
            if bundlePath.hasPrefix(userAppsPath) {
                appLocation = .userApplications
            } else {
                appLocation = .other(bundlePath)
            }
        }
    }

    func checkPluginRegistered() {
        do {
            let output = try runProcess("/usr/bin/pluginkit", arguments: ["-m", "-v", "-p", "com.apple.screensaver"])
            let lines = output.components(separatedBy: "\n")
            isPluginRegistered = lines.contains { $0.contains(bundleIdentifier) }
        } catch {
            errorLog("Failed to query pluginkit: \(error.localizedDescription)")
            isPluginRegistered = false
        }
    }

    func checkScreensaverEnabled() {
        // Use the per-Space API rather than `getActiveScreensavers()`.
        // The latter returns the UNION of screensavers across every
        // Space on every monitor, so changing the current Space's
        // screensaver to something else still leaves Aerial in the
        // set as long as it's active on any other Space — the popover
        // banner then misses the change. `getActiveScreensaver(for: nil)`
        // walks the space tree and returns the screensaver attached to
        // the `is_current` Space, which is what the user means by
        // "my active screensaver right now".
        if let info = paperSaver.getActiveScreensaver(for: nil) {
            isScreensaverEnabled = info.identifier == screensaverDisplayName
                || info.name == screensaverDisplayName
        } else {
            isScreensaverEnabled = false
        }
    }

    // MARK: - Actions

    func registerPlugin() {
        guard let extensionURL = Bundle.main.builtInPlugInsURL?.appendingPathComponent("AerialScreenSaverExtension.appex") else {
            errorLog("Cannot find built-in plugins URL")
            return
        }

        let extensionPath = extensionURL.path
        guard FileManager.default.fileExists(atPath: extensionPath) else {
            errorLog("Extension not found at: \(extensionPath)")
            return
        }

        debugLog("Registering plugin from: \(extensionPath)")
        do {
            _ = try runProcess("/usr/bin/pluginkit", arguments: ["-a", extensionPath])
            debugLog("Plugin registered successfully")
            checkPluginRegistered()
        } catch {
            errorLog("Failed to register plugin: \(error.localizedDescription)")
        }
    }

    func enableScreensaver() async {
        debugLog("Enabling \(screensaverDisplayName) screensaver via PaperSaver...")
        do {
            try await paperSaver.setScreensaverEverywhere(module: screensaverDisplayName)
            debugLog("Screensaver enabled successfully")
            checkScreensaverEnabled()
        } catch {
            errorLog("Failed to enable screensaver: \(error.localizedDescription)")
        }
    }

    func refreshAll() {
        checkAppLocation()
        checkPluginRegistered()
        checkScreensaverEnabled()
    }

    // MARK: - Private Helpers

    private func runProcess(_ path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

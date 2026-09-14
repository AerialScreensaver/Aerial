//
//  LogBridge.swift
//  Aerial
//
//  Single logging bridge for both processes. Each one calls
//  LogBridge.configure() first thing at startup — the app with app.txt,
//  the wallpaper extension with wallpaper.txt.
//

import Foundation

enum LogBridge {
    /// Guards `logger`: configure() runs on the launching thread while the
    /// first static initializer to log may already be on another one.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var logger: AerialLogger?   // guarded by `lock`
    /// Main-thread only (installed and invalidated inside main.async).
    nonisolated(unsafe) private static var rollTimer: Timer?

    /// Configure the logger for the current process (call once at startup)
    static func configure(_ logger: AerialLogger) {
        lock.lock()
        self.logger = logger
        lock.unlock()
        logger.rollLogIfNeeded()

        // Long-running processes (Companion menu-bar app, the extension
        // between respawns) need a periodic re-check — the startup-only
        // roll lets the file grow forever for users who never quit.
        // Installed on main: Timer needs a running runloop, and
        // configure() can be called from a non-runloop thread.
        DispatchQueue.main.async {
            rollTimer?.invalidate()
            rollTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak logger] _ in
                logger?.rollLogIfNeeded()
            }
        }
    }

    /// Returns the configured logger. The fallback only exists for the
    /// window between process start and configure() (e.g. a static
    /// initializer that logs) — it picks the correct file for the
    /// current process so a third log file never appears.
    static var shared: AerialLogger {
        lock.lock(); defer { lock.unlock() }
        if let logger { return logger }
        let isExtension = Bundle.main.bundleIdentifier?.contains("WallpaperExtension") ?? false
        let fallback = AerialLogger(config: LoggerConfiguration(
            logFileName: isExtension ? "wallpaper.txt" : "app.txt",
            supportPath: { "/Users/Shared/Aerial/Logs" },
            category: isExtension ? "Extension" : "Companion",
            mirrorToOSLog: isExtension,
            maxLogSize: isExtension ? 10_000_000 : 1_000_000
        ))
        self.logger = fallback
        return fallback
    }
}

// MARK: - Global Convenience Functions

func debugLog(_ message: String) { LogBridge.shared.debug(message) }
func errorLog(_ message: String) { LogBridge.shared.error(message) }
func warnLog(_ message: String)  { LogBridge.shared.warn(message) }
func infoLog(_ message: String)  { LogBridge.shared.info(message) }

/// Log to Console.app only (OSLog), no file write.
func logToConsole(_ message: String) {
    LogBridge.shared.logToConsole(message)
}

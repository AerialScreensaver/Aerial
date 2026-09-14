//
//  AerialLogger.swift
//  Aerial
//
//  THE logging system — one implementation shared by the Companion app
//  and the wallpaper extension. Each process configures LogBridge with
//  its own file at startup (app.txt for the app, wallpaper.txt for the
//  extension) and everything logs through debugLog/infoLog/warnLog/
//  errorLog. Two live files under /Users/Shared/Aerial/Logs/, each
//  keeping two rolled generations (.1, .2) — a roll used to DELETE the
//  log, which destroyed the pre-restart history in the 2026-07 Tahoe
//  churn investigation right when it mattered most.
//
//  All file I/O runs on a private serial queue with a persistent
//  FileHandle — never on the caller's thread (verbose diagnostics used
//  to put hundreds of open/seek/write/close cycles on the extension's
//  XPC thread per acquire, serializing multi-display setup). Timestamps
//  are captured at call time so file ordering matches reality.
//

import Cocoa
import os.log

enum ErrorLevel: Int {
    case info, debug, warning, error
}

// MARK: - Logger Configuration

struct LoggerConfiguration {
    /// The log file name ("app.txt", "wallpaper.txt")
    let logFileName: String

    /// Closure that returns the directory where logs are stored
    let supportPath: () -> String

    /// Category name for OSLog ("Companion", "Extension")
    let category: String

    /// Mirror EVERY line to os_log, not just errors. The extension
    /// turns this on so its log can be streamed live in Console.app
    /// without file access; errors are mirrored regardless.
    let mirrorToOSLog: Bool

    /// Roll the log once it exceeds this size (shifted to .1/.2
    /// generations, oldest dropped), checked at configure time and
    /// periodically by LogBridge. The extension uses a larger budget
    /// than the app — its diagnostics are the primary investigation
    /// tool and must survive a few days of uptime.
    let maxLogSize: Int

    init(
        logFileName: String,
        supportPath: @escaping () -> String,
        category: String,
        mirrorToOSLog: Bool = false,
        maxLogSize: Int = 1_000_000
    ) {
        self.logFileName = logFileName
        self.supportPath = supportPath
        self.category = category
        self.mirrorToOSLog = mirrorToOSLog
        self.maxLogSize = maxLogSize
    }
}

// MARK: - Aerial Logger Core

final class AerialLogger {
    let config: LoggerConfiguration

    /// Serial queue for all disk work (writes + rolling). Also the only
    /// place `fileHandle` and `dateFormatter` are touched.
    private let writeQueue = DispatchQueue(label: "com.glouel.aerial.log-writer", qos: .utility)

    /// Persistent handle, opened lazily, reopened if the file vanishes.
    private var fileHandle: FileHandle?

    /// DateFormatter is not thread-safe — writeQueue only. The Date is
    /// captured on the caller's thread at log time.
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Stamped on every line: the extension respawns every few seconds
    /// of idle churn and the app enforces newest-instance-wins — pid is
    /// how log archaeology tells instances apart.
    private let pid = ProcessInfo.processInfo.processIdentifier

    private let osLog: OSLog

    init(config: LoggerConfiguration) {
        self.config = config
        self.osLog = OSLog(
            subsystem: Bundle.main.bundleIdentifier ?? "com.glouel.aerial",
            category: config.category
        )
    }

    // MARK: - Core Logging

    func log(level: ErrorLevel, message: String) {
        #if DEBUG
        print("\(message)\n")
        #endif

        // Console.app: errors always, everything when mirroring is on.
        if level == .error {
            os_log("AerialError: %{public}@", log: osLog, type: .error, message)
        } else if config.mirrorToOSLog {
            os_log("%{public}@", log: osLog, type: .default, message)
        }

        appendToDisk(message: message, date: Date())
    }

    func debug(_ message: String) { log(level: .debug, message: message) }
    func info(_ message: String)  { log(level: .info, message: message) }
    func warn(_ message: String)  { log(level: .warning, message: message) }
    func error(_ message: String) { log(level: .error, message: message) }

    /// Console.app only — no file write.
    func logToConsole(_ message: String) {
        os_log("Aerial: %{public}@", log: osLog, type: .default, message)
    }

    // MARK: - Log Rolling

    /// Roll the log once it exceeds `maxLogSize`: shift generations
    /// (.1 → .2, current → .1) instead of deleting — a spam storm used
    /// to wipe exactly the history a bug report needs (the rolled file
    /// is what the pre-restart Tahoe-churn evidence lived in). Runs on
    /// the write queue so it can safely drop the persistent handle —
    /// rolling from another thread would leave writes going to the
    /// renamed inode.
    func rollLogIfNeeded() {
        writeQueue.async {
            let fm = FileManager.default
            let url = self.logFileURL()
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int64,
                  size > Int64(self.config.maxLogSize)
            else { return }
            try? self.fileHandle?.close()
            self.fileHandle = nil
            let gen1 = url.appendingPathExtension("1")
            let gen2 = url.appendingPathExtension("2")
            try? fm.removeItem(at: gen2)
            try? fm.moveItem(at: gen1, to: gen2)
            do {
                try fm.moveItem(at: url, to: gen1)
            } catch {
                // Rename failed (permissions, races) — fall back to the
                // old delete so the log can't grow unbounded.
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Crash path

    /// Synchronous append that bypasses `writeQueue`, for an
    /// uncaught-exception handler: the process aborts the moment the
    /// handler returns, so a queued write would never land. Opens its own
    /// descriptor with POSIX calls, writes, closes; also mirrors to os_log
    /// at fault level so Console.app shows it without file access. Uses a
    /// throwaway formatter — `dateFormatter` belongs to writeQueue.
    func writeSynchronously(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = "\(formatter.string(from: Date())) pid=\(pid) : \(message)\n"
        os_log("%{public}@", log: osLog, type: .fault, message)
        let fd = Darwin.open(logFileURL().path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        line.withCString { ptr in
            _ = Darwin.write(fd, ptr, strlen(ptr))
        }
    }

    // MARK: - Disk I/O (writeQueue only)

    private func logFileURL() -> URL {
        URL(fileURLWithPath: config.supportPath())
            .appendingPathComponent(config.logFileName)
    }

    private func appendToDisk(message: String, date: Date) {
        writeQueue.async {
            let line = "\(self.dateFormatter.string(from: date)) pid=\(self.pid) : \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            if self.fileHandle == nil {
                self.openHandle()
            }
            do {
                try self.fileHandle?.write(contentsOf: data)
            } catch {
                // Stale handle (file rotated/deleted underneath us) —
                // drop it and retry once through a fresh one.
                self.fileHandle = nil
                self.openHandle()
                try? self.fileHandle?.write(contentsOf: data)
            }
        }
    }

    private func openHandle() {
        let url = logFileURL()
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            let directory = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: directory.path) {
                try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            fm.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        _ = try? fileHandle?.seekToEnd()
        if fileHandle == nil {
            NSLog("AerialError: Can't open handle for \(config.logFileName)")
        }
    }
}

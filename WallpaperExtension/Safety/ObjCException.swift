//
//  ObjCException.swift
//  Aerial4WallpaperExtension
//
//  Swift face of ObjCExceptionCatcher.m, plus the process-wide
//  uncaught-exception logger.
//
//  Two layers:
//   • `ObjCException.catching(...)` / `.attempt(...)` wrap a single
//     private-API call (CAContext, KVC on private properties, the
//     WallpaperSnapshotXPC swizzle). An NSException raised inside
//     becomes a logged Swift error and the caller falls back instead
//     of the extension aborting.
//   • `installUncaughtExceptionLogger()` catches nothing — it writes
//     name, reason and backtrace of an exception nobody caught to the
//     log SYNCHRONOUSLY before the abort, so the next unexplained
//     appex crash is a one-line triage instead of a symbolication
//     hunt (the 4.0.14 "auxiliary host protocol" crash took days).
//
//  Keep a wrapped body to the risky call itself: an exception that
//  unwinds through Swift frames skips their cleanups (no deinit, no
//  defer), which is a leak at worst but only if there is state to leak.
//

import Foundation

/// An NSException caught at a private-API boundary.
struct ObjCExceptionError: Error, CustomStringConvertible {
    let context: String
    let name: String
    let reason: String
    let callStack: [String]

    init(_ error: NSError, context: String) {
        self.context = context
        name = error.userInfo[AerialObjCExceptionNameKey] as? String ?? "NSException"
        reason = error.userInfo[AerialObjCExceptionReasonKey] as? String ?? error.localizedDescription
        callStack = error.userInfo[AerialObjCExceptionCallStackKey] as? [String] ?? []
    }

    var description: String { "\(name) in \(context): \(reason)" }
}

enum ObjCException {
    /// Run `body`, converting an NSException raised inside it into a
    /// thrown `ObjCExceptionError` (logged with its backtrace). Swift
    /// errors thrown by `body` propagate untouched.
    @discardableResult
    static func catching<T>(_ context: @autoclosure () -> String, _ body: () throws -> T) throws -> T {
        var outcome: Result<T, Error>?
        let nsError = AerialCatchObjCException {
            outcome = Result { try body() }
        }
        if let nsError {
            let error = ObjCExceptionError(nsError as NSError, context: context())
            let frames = error.callStack.prefix(12).joined(separator: "\n    ")
            errorLog("💥 [ObjCException] caught \(error)\n    \(frames)")
            throw error
        }
        guard let outcome else {
            // Unreachable: the block either completed (outcome set) or
            // raised (nsError set). Kept as a throw, never a trap.
            throw ObjCExceptionError(
                NSError(domain: AerialObjCExceptionErrorDomain, code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "catcher returned without an outcome"]),
                context: context()
            )
        }
        return try outcome.get()
    }

    /// `catching` for call sites with their own nil fallback: nil when
    /// `body` raised an NSException or threw.
    @discardableResult
    static func attempt<T>(_ context: @autoclosure () -> String, _ body: () throws -> T) -> T? {
        try? catching(context(), body)
    }

    // MARK: - Uncaught exception logger

    /// Written once by `installUncaughtExceptionLogger()` during appex init,
    /// before any other thread exists; read only from the crash handler.
    nonisolated(unsafe) private static var previousHandler: NSUncaughtExceptionHandler?

    /// Install once at process start. The handler runs on the raising
    /// thread and the process aborts the moment it returns, so the log
    /// line goes through `AerialLogger.writeSynchronously` (no queue),
    /// then chains to whatever handler was installed before us.
    static func installUncaughtExceptionLogger() {
        previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n    ")
            let userInfo = exception.userInfo.map { " userInfo=\($0)" } ?? ""
            LogBridge.shared.writeSynchronously(
                "💥 UNCAUGHT ObjC exception \(exception.name.rawValue): \(exception.reason ?? "(no reason)")\(userInfo)\n    \(stack)"
            )
            ObjCException.previousHandler?(exception)
        }
    }
}

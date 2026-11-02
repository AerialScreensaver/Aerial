//
//  MediaRemoteAdapterProcess.swift
//  Aerial
//
//  Runs the vendored mediaremote-adapter through the system Perl:
//
//      /usr/bin/perl <Resources/mediaremote-adapter.pl>
//                    <Frameworks/MediaRemoteAdapter.framework> get|stream …
//
//  `mediaremoted` only answers Apple-signed callers (the reason the
//  direct MediaRemote path died with the move to an .appex — see
//  mediaremote.md). /usr/bin/perl is Apple-signed as `com.apple.perl` and
//  has no library validation, so it may dl_load our framework and ask on
//  our behalf. Companion only: the extension is sandboxed and cannot
//  spawn, and the now-playing feed was Companion-only already.
//

import Foundation

final class MediaRemoteAdapterProcess {
    enum AdapterError: Error, CustomStringConvertible {
        case notBundled(String)
        case perlMissing
        case launchFailed(String)
        case exit(status: Int32, stderr: String)
        case timeout
        case badOutput(String)

        var description: String {
            switch self {
            case .notBundled(let what): return "\(what) missing from the app bundle"
            case .perlMissing: return "/usr/bin/perl is missing"
            case .launchFailed(let why): return "could not launch perl: \(why)"
            case .exit(let status, let stderr):
                return "adapter exited with status \(status)\(stderr.isEmpty ? "" : ": \(stderr)")"
            case .timeout: return "adapter did not answer within the timeout"
            case .badOutput(let line): return "unexpected adapter output: \(line.prefix(120))"
            }
        }
    }

    static let perlPath = "/usr/bin/perl"
    private static let streamOptions = ["--debounce=250", "--micros"]

    static var scriptURL: URL? {
        Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")
    }

    static var frameworkURL: URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework", isDirectory: true)
    }

    /// The two bundle pieces and the interpreter, checked once per call.
    static func bundleCheck() -> Result<(script: URL, framework: URL), AdapterError> {
        guard FileManager.default.isExecutableFile(atPath: perlPath) else { return .failure(.perlMissing) }
        guard let script = scriptURL, FileManager.default.fileExists(atPath: script.path) else {
            return .failure(.notBundled("mediaremote-adapter.pl"))
        }
        guard let framework = frameworkURL,
              FileManager.default.fileExists(atPath: framework.appendingPathComponent("MediaRemoteAdapter").path) else {
            return .failure(.notBundled("MediaRemoteAdapter.framework"))
        }
        return .success((script, framework))
    }

    // MARK: - One-shot `get`

    /// `get --micros`: `.success(nil)` = nothing playing. Synchronous; the
    /// caller picks the queue. Same bounded shape as `ExternalCacheImage.run`:
    /// both pipes drained concurrently, SIGTERM on timeout, SIGKILL if that
    /// is ignored.
    static func get(timeout: TimeInterval = 5) -> Result<[String: Any]?, AdapterError> {
        let paths: (script: URL, framework: URL)
        switch bundleCheck() {
        case .failure(let error): return .failure(error)
        case .success(let found): paths = found
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: perlPath)
        proc.arguments = [paths.script.path, paths.framework.path, "get", "--micros"]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do {
            try proc.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        let readers = DispatchGroup()
        var outData = Data()
        var errData = Data()
        DispatchQueue.global(qos: .utility).async(group: readers) {
            outData = out.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .utility).async(group: readers) {
            errData = err.fileHandleForReading.readDataToEndOfFile()
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            proc.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut, proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
        }
        _ = readers.wait(timeout: .now() + 2)
        let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if timedOut { return .failure(.timeout) }
        let status: Int32 = proc.isRunning ? -1 : proc.terminationStatus
        guard status == 0 else { return .failure(.exit(status: status, stderr: stderr)) }
        let text = String(data: outData, encoding: .utf8) ?? ""
        // Last non-empty line: the adapter prints exactly one, but stay
        // tolerant of stray output.
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return .failure(.badOutput(text))
        }
        switch MediaRemoteAdapterLine.parse(String(line)) {
        case .some(.null): return .success(nil)
        case .some(.data(_, let payload)): return .success(payload)
        default: return .failure(.badOutput(String(line)))
        }
    }

    // MARK: - Resident `stream`

    private var process: Process?
    private var stdoutBuffer = Data()
    private let bufferLock = NSLock()
    private let exited = DispatchSemaphore(value: 0)
    private var stopping = false
    private let stateLock = NSLock()

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return process?.isRunning ?? false
    }

    /// Spawns `stream`. `onLine` gets each complete stdout line (any
    /// thread, the pipe's reader); `onExit` fires once when the child
    /// ends for any reason other than `stop()`.
    func start(onLine: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) throws {
        let paths: (script: URL, framework: URL)
        switch Self.bundleCheck() {
        case .failure(let error): throw error
        case .success(let found): paths = found
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.perlPath)
        proc.arguments = [paths.script.path, paths.framework.path, "stream"] + Self.streamOptions
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil   // EOF
                return
            }
            guard let self else { return }
            // An artwork line is hundreds of KB and arrives in several
            // reads: keep the partial tail, hand out whole lines only.
            var lines: [String] = []
            self.bufferLock.lock()
            self.stdoutBuffer.append(chunk)
            while let newline = self.stdoutBuffer.firstIndex(of: 0x0A) {
                let lineData = self.stdoutBuffer.subdata(in: self.stdoutBuffer.startIndex..<newline)
                self.stdoutBuffer.removeSubrange(self.stdoutBuffer.startIndex...newline)
                lines.append(String(decoding: lineData, as: UTF8.self))
            }
            self.bufferLock.unlock()
            for line in lines where !line.isEmpty { onLine(line) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: chunk, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { debugLog("🎧 [MediaRemote] stderr: \(text.prefix(300))") }
        }
        proc.terminationHandler = { [weak self] finished in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.stateLock.lock()
            let intentional = self.stopping
            self.stateLock.unlock()
            self.exited.signal()
            if !intentional { onExit(finished.terminationStatus) }
        }

        stateLock.lock()
        stopping = false
        process = proc
        stateLock.unlock()
        do {
            try proc.run()
        } catch {
            stateLock.lock(); process = nil; stateLock.unlock()
            throw AdapterError.launchFailed(error.localizedDescription)
        }
        debugLog("🎧 [MediaRemote] stream started (pid \(proc.processIdentifier))")
    }

    /// SIGTERM (the adapter stops its run loop and exits), SIGKILL if it is
    /// still there after `grace`. Idempotent; blocks the caller for at most
    /// grace + 2 s.
    func stop(grace: TimeInterval = 1) {
        stateLock.lock()
        guard let proc = process else { stateLock.unlock(); return }
        stopping = true
        process = nil
        stateLock.unlock()
        guard proc.isRunning else { return }
        proc.terminate()
        if exited.wait(timeout: .now() + grace) == .timedOut, proc.isRunning {
            debugLog("🎧 [MediaRemote] stream ignored SIGTERM — killing pid \(proc.processIdentifier)")
            kill(proc.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
        }
        debugLog("🎧 [MediaRemote] stream stopped")
    }
}

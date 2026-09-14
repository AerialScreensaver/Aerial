//
//  LiveFeedsGateway.swift
//  Aerial
//
//  Minimal HTTP/1.1 server on 127.0.0.1 that serves the HLS segments
//  `LiveFeedTransmuxer` writes under /private/tmp/aerial-livefeeds/. Only
//  GET is supported; only paths matching `<uuid>/index.m3u8` or
//  `<uuid>/seg_<N>.ts` are served. Anything else 404s. Bound to
//  127.0.0.1 only — the listener never accepts off-host traffic.
//
//  Companion-only.
//

import Foundation
import Network

final class LiveFeedsGateway {

    static let shared = LiveFeedsGateway()

    /// Root directory served by the gateway. Each live feed gets a
    /// subdirectory named after its UUID containing the HLS playlist and
    /// segments ffmpeg writes.
    static let rootDirectory: URL = URL(fileURLWithPath: "/private/tmp/aerial-livefeeds", isDirectory: true)

    private let queue = DispatchQueue(label: "com.glouel.aerial.livefeeds.gateway")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private(set) var port: UInt16 = 0

    /// Last time any HTTP request was served for a given feed UUID.
    /// Consumed by `LiveFeedTransmuxerManager` to reap idle transmuxers.
    private let accessLock = NSLock()
    private var lastAccessTimes: [UUID: Date] = [:]

    private init() {
        ensureRoot()
    }

    // MARK: - Public

    /// URL prefix to hand to AVPlayer / the source manifest, e.g.
    /// `http://127.0.0.1:54231`. Returns nil until the listener is running.
    var baseURL: URL? {
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    /// Ensure the listener is running and return the directory that
    /// should be fed to ffmpeg for a given feed id. Idempotent; safe to
    /// call repeatedly from the UI / resolver.
    @discardableResult
    func ensureRunning() throws -> UInt16 {
        if let port = listener.flatMap({ _ in Optional(self.port) }), port > 0 {
            return port
        }
        return try start()
    }

    /// Directory to hand to ffmpeg for a given feed id. Creates it if
    /// needed.
    func outputDirectory(for feedID: UUID) -> URL {
        let dir = Self.rootDirectory.appendingPathComponent(feedID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns the loopback URL the extension should play for a feed id.
    /// `nil` when the gateway isn't running yet.
    func playbackURL(for feedID: UUID) -> URL? {
        guard let base = baseURL else { return nil }
        return base.appendingPathComponent(feedID.uuidString)
                   .appendingPathComponent("index.m3u8")
    }

    /// Remove the serving directory for a feed (e.g. when it's deleted).
    func removeOutputDirectory(for feedID: UUID) {
        let dir = Self.rootDirectory.appendingPathComponent(feedID.uuidString)
        try? FileManager.default.removeItem(at: dir)
        accessLock.lock()
        lastAccessTimes.removeValue(forKey: feedID)
        accessLock.unlock()
    }

    /// Most recent time we served any file for `feedID`, or `nil` if we
    /// haven't served one yet. Lets the transmuxer manager decide when
    /// a feed has gone idle (no consumer connected) and can be stopped
    /// to save bandwidth.
    func lastAccess(for feedID: UUID) -> Date? {
        accessLock.lock()
        defer { accessLock.unlock() }
        return lastAccessTimes[feedID]
    }

    /// Record a successful request for `feedID`. Thread-safe. Called by
    /// the request handler on every served file, and also by the
    /// transmuxer manager right after spawning ffmpeg to give the
    /// reaper a sensible "first access" baseline for pre-warmed feeds
    /// that haven't been consumed yet.
    func recordAccess(for feedID: UUID) {
        accessLock.lock()
        lastAccessTimes[feedID] = Date()
        accessLock.unlock()
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.port = 0
            for (_, conn) in self.connections {
                conn.cancel()
            }
            self.connections.removeAll()
        }
    }

    // MARK: - Private

    private func ensureRoot() {
        try? FileManager.default.createDirectory(at: Self.rootDirectory, withIntermediateDirectories: true)
    }

    private func start() throws -> UInt16 {
        ensureRoot()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if let p = listener.port?.rawValue {
                    self.port = p
                    debugLog("🎥 LiveFeedsGateway ready on 127.0.0.1:\(p)")
                }
            case .failed(let err):
                errorLog("🎥 LiveFeedsGateway failed: \(err.localizedDescription)")
                self.port = 0
            case .cancelled:
                self.port = 0
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        self.listener = listener

        // Wait briefly for the listener to become ready so callers that
        // query `port` immediately after `start` get a sensible value.
        let deadline = Date().addingTimeInterval(1.0)
        while port == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard port > 0 else {
            throw NSError(domain: "com.glouel.aerial.gateway", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "gateway didn't bind within 1 s"])
        }
        return port
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn else { return }
            if case .cancelled = state {
                self.connections.removeValue(forKey: ObjectIdentifier(conn))
            } else if case .failed = state {
                self.connections.removeValue(forKey: ObjectIdentifier(conn))
                conn.cancel()
            }
        }
        conn.start(queue: queue)
        readRequest(conn)
    }

    private func readRequest(_ conn: NWConnection, accumulated: Data = Data()) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                debugLog("🎥 gateway recv error: \(error.localizedDescription)")
                conn.cancel()
                return
            }
            var buffer = accumulated
            if let data = data {
                buffer.append(data)
            }
            // Keep reading until we see the header terminator.
            if let headerEnd = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
                self.handle(request: headerData, on: conn)
            } else if isComplete {
                conn.cancel()
            } else if buffer.count > 16_384 {
                // Header too big — bail rather than accumulate forever.
                self.respond(status: "413 Payload Too Large", on: conn, close: true)
            } else {
                self.readRequest(conn, accumulated: buffer)
            }
        }
    }

    private func handle(request: Data, on conn: NWConnection) {
        guard let text = String(data: request, encoding: .utf8) else {
            respond(status: "400 Bad Request", on: conn, close: true)
            return
        }
        let firstLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(status: "400 Bad Request", on: conn, close: true)
            return
        }
        let method = String(parts[0])
        let rawPath = String(parts[1])

        guard method == "GET" else {
            respond(status: "405 Method Not Allowed", on: conn, close: true)
            return
        }
        serveFile(at: rawPath, on: conn)
    }

    private func serveFile(at rawPath: String, on conn: NWConnection) {
        // Strip the leading slash and split into components.
        let trimmed = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
        let components = trimmed.split(separator: "/").map(String.init)
        // Only `<uuid>/<file>.{m3u8,ts}` is served; everything else is
        // blocked (no directory traversal, no arbitrary reads).
        guard components.count == 2,
              let feedID = UUID(uuidString: components[0]),
              !components[1].isEmpty,
              !components[1].contains(".."),
              (components[1].hasSuffix(".m3u8") || components[1].hasSuffix(".ts")) else {
            respond(status: "404 Not Found", on: conn, close: true)
            return
        }
        let fileURL = Self.rootDirectory
            .appendingPathComponent(components[0], isDirectory: true)
            .appendingPathComponent(components[1])

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            respond(status: "404 Not Found", on: conn, close: true)
            return
        }
        recordAccess(for: feedID)
        let contentType = components[1].hasSuffix(".m3u8")
            ? "application/vnd.apple.mpegurl"
            : "video/mp2t"
        respond(status: "200 OK", on: conn, body: data, contentType: contentType, close: true)
    }

    private func respond(status: String,
                         on conn: NWConnection,
                         body: Data = Data(),
                         contentType: String = "text/plain; charset=utf-8",
                         close: Bool) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        conn.send(content: data, completion: .contentProcessed({ _ in
            if close { conn.cancel() }
        }))
    }
}

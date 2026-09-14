//
//  MessageContentProvider.swift
//  Aerial
//
//  Companion-side engine behind the Message overlay's "Shell Script"
//  and "Text File" modes. The wallpaper extension is sandboxed (only
//  /Users/Shared/ is readable) so it can neither run user scripts nor
//  read arbitrary files — the Companion does both here and publishes
//  the resulting text to message-content.json, which the shared overlay
//  code re-reads on its tick (same relay pattern as now-playing.json).
//

import Foundation

final class MessageContentProvider {
    static let shared = MessageContentProvider()

    static let filePath = AerialPaths.baseDirectory + "/message-content.json"

    /// One published entry per dynamic message instance, keyed by the
    /// instance UUID string. Written as a plain [String: Entry] JSON.
    struct Entry: Codable, Equatable {
        var text: String
        var updatedAt: Date
    }

    private struct DynamicMessage {
        let id: String
        let mode: String            // "shell" | "textfile"
        let path: String
        let refreshInterval: Int    // seconds; 0 = run once
        var lastRun: Date?
    }

    private let queue = DispatchQueue(label: "com.glouel.aerial.message-content", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var messages: [DynamicMessage] = []
    private var published: [String: Entry] = [:]
    private var started = false

    private init() {}

    /// Idempotent — scan the overlay config, run everything once, and
    /// keep refreshing per-instance intervals. Re-scans whenever the
    /// overlay editor saves.
    func startIfNeeded() {
        guard !started else { return }
        started = true

        NotificationCenter.default.addObserver(
            forName: OverlayConfigManager.configDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.rescan() }
        }

        queue.async { self.rescan() }
    }

    // MARK: - Config scan (on queue)

    private func rescan() {
        let config = OverlayConfigManager.shared.config
        var layouts = [config.sharedLayout] + Array(config.screenLayouts.values)
        if let desktop = config.desktopSharedLayout { layouts.append(desktop) }
        layouts.append(contentsOf: (config.desktopScreenLayouts ?? [:]).values)

        var found: [DynamicMessage] = []
        for instance in layouts.flatMap(\.allInstances) where instance.kind == .message {
            let mode = instance.typeSettings["messageType"]?.asString ?? "text"
            let path: String?
            switch mode {
            case "shell": path = instance.typeSettings["shellScript"]?.asString
            case "textfile": path = instance.typeSettings["textFile"]?.asString
            default: path = nil
            }
            guard let path, !path.isEmpty else { continue }
            let interval = instance.typeSettings["refreshInterval"]?.asInt ?? 0
            // Same instance can appear in several layouts (shared +
            // desktop) — one runner per UUID is enough.
            guard !found.contains(where: { $0.id == instance.id.uuidString }) else { continue }
            found.append(DynamicMessage(
                id: instance.id.uuidString,
                mode: mode,
                path: (path as NSString).expandingTildeInPath,
                refreshInterval: interval
            ))
        }
        messages = found

        // Drop published content for instances that no longer exist so
        // the extension doesn't render ghosts.
        let ids = Set(found.map(\.id))
        let before = published.count
        published = published.filter { ids.contains($0.key) }
        if published.count != before || found.isEmpty {
            writePublished()
        }

        refreshDue(force: true)
        ensureTimer()
        debugLog("💬 MessageContentProvider: \(found.count) dynamic message(s)")
    }

    /// A single coarse scheduler is plenty — the finest refresh option
    /// is 10 s and script output landing a few seconds late is invisible
    /// on a wallpaper.
    private func ensureTimer() {
        if messages.isEmpty || !messages.contains(where: { $0.refreshInterval > 0 }) {
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        source.setEventHandler { [weak self] in
            self?.refreshDue(force: false)
        }
        source.resume()
        timer = source
    }

    // MARK: - Content refresh (on queue)

    private func refreshDue(force: Bool) {
        let now = Date()
        var changed = false
        for index in messages.indices {
            let message = messages[index]
            if !force {
                guard message.refreshInterval > 0 else { continue }
                if let last = message.lastRun,
                   now.timeIntervalSince(last) < Double(message.refreshInterval) {
                    continue
                }
            }
            messages[index].lastRun = now
            let text = produceText(for: message)
            if published[message.id]?.text != text {
                published[message.id] = Entry(text: text, updatedAt: now)
                changed = true
            }
        }
        if changed { writePublished() }
    }

    private func produceText(for message: DynamicMessage) -> String {
        guard FileManager.default.fileExists(atPath: message.path) else {
            return ""
        }
        switch message.mode {
        case "shell":
            // Process.launch() raises (uncatchably from Swift) on a
            // non-executable file — run it through /bin/sh instead so a
            // script saved without +x still works.
            let output = Helpers.shell(launchPath: "/bin/sh", arguments: [message.path]) ?? ""
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        case "textfile":
            let content = (try? String(contentsOfFile: message.path, encoding: .utf8)) ?? ""
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return ""
        }
    }

    private func writePublished() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(published) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.filePath), options: .atomic)
    }
}

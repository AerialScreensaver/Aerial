//
//  JSONPreferencesStore.swift
//  Aerial Companion
//

import Foundation

/// Thread-safe JSON preferences storage using dispatch queue for concurrency control
/// Provides atomic reads and writes for Codable types to JSON files
class JSONPreferencesStore {

    // MARK: - Singleton

    static let shared = JSONPreferencesStore()

    // Serial queue for thread-safe file access
    private let fileQueue = DispatchQueue(label: "com.glouel.aerial.jsonstore", attributes: [])

    private init() {}

    // MARK: - Public API

    /// Read a Codable value from a JSON file
    /// - Parameters:
    ///   - type: The Codable type to decode
    ///   - fileURL: The file URL to read from
    /// - Returns: The decoded value, or nil if file doesn't exist or can't be decoded
    func read<T: Codable>(_ type: T.Type, from fileURL: URL) -> T? {
        if case .value(let value) = readChecked(type, from: fileURL) {
            return value
        }
        return nil
    }

    /// What `readChecked` found. Callers that fall back to defaults must
    /// tell the last two apart: `absent` may be replaced by defaults,
    /// `undecodable` is a file the user's settings are still IN — writing
    /// defaults over it would destroy them. See `quarantine`.
    enum ReadOutcome<T> {
        case absent
        case value(T)
        case undecodable(Error)
    }

    /// `read`, but distinguishing "no file" from "a file we can't parse".
    func readChecked<T: Codable>(_ type: T.Type, from fileURL: URL) -> ReadOutcome<T> {
        return fileQueue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return .absent
            }
            do {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder()
                return .value(try decoder.decode(T.self, from: data))
            } catch {
                errorLog("[JSONPreferencesStore] ⚠️ Undecodable \(fileURL.lastPathComponent): \(error.localizedDescription)")
                return .undecodable(error)
            }
        }
    }

    /// Move an undecodable file aside as `<name>.corrupt-<timestamp>.<ext>`
    /// next to it, so the user's bytes survive for recovery and the next
    /// write starts from a clean slate. Returns where it went, nil when
    /// the move failed (the caller should then keep refusing to write).
    @discardableResult
    func quarantine(_ fileURL: URL, now: Date = Date()) -> URL? {
        return fileQueue.sync {
            let stamp = Self.quarantineStamp.string(from: now)
            let ext = fileURL.pathExtension
            let base = fileURL.deletingPathExtension().lastPathComponent
            var name = "\(base).corrupt-\(stamp)"
            if FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent()
                    .appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)").path) {
                name += "-" + UUID().uuidString.prefix(8)
            }
            if !ext.isEmpty { name += ".\(ext)" }
            let target = fileURL.deletingLastPathComponent().appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: fileURL, to: target)
                errorLog("[JSONPreferencesStore] ⚠️ Quarantined \(fileURL.lastPathComponent) → \(name)")
                return target
            } catch {
                errorLog("[JSONPreferencesStore] Failed to quarantine \(fileURL.path): \(error.localizedDescription)")
                return nil
            }
        }
    }

    private static let quarantineStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// Write a Codable value to a JSON file atomically
    /// - Parameters:
    ///   - value: The Codable value to encode
    ///   - fileURL: The file URL to write to
    /// - Returns: True if write succeeded, false otherwise
    @discardableResult
    func write<T: Codable>(_ value: T, to fileURL: URL) -> Bool {
        return fileQueue.sync {
            do {
                // Encode to JSON
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(value)

                // Ensure parent directory exists
                let parentDir = fileURL.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: parentDir.path) {
                    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }

                // Write atomically (write to temp file, then move)
                // This ensures the file is never in a partially-written state
                try data.write(to: fileURL, options: .atomic)

                return true
            } catch {
                errorLog("[JSONPreferencesStore] Failed to write to \(fileURL.path): \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Delete a preferences file
    /// - Parameter fileURL: The file URL to delete
    /// - Returns: True if deletion succeeded or file didn't exist
    @discardableResult
    func delete(at fileURL: URL) -> Bool {
        return fileQueue.sync {
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                return true
            } catch {
                errorLog("[JSONPreferencesStore] Failed to delete \(fileURL.path): \(error.localizedDescription)")
                return false
            }
        }
    }
}

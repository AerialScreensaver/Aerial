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
        return fileQueue.sync {
            do {
                // Check if file exists
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    print("[JSONPreferencesStore] File does not exist at \(fileURL.path)")
                    return nil
                }

                // Read file data
                let data = try Data(contentsOf: fileURL)

                // Decode JSON
                let decoder = JSONDecoder()
                let result = try decoder.decode(T.self, from: data)

                print("[JSONPreferencesStore] Successfully read from \(fileURL.lastPathComponent)")
                return result
            } catch {
                print("[JSONPreferencesStore] Failed to read from \(fileURL.path): \(error.localizedDescription)")
                return nil
            }
        }
    }

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

                print("[JSONPreferencesStore] Successfully wrote to \(fileURL.lastPathComponent) (\(data.count) bytes)")
                return true
            } catch {
                print("[JSONPreferencesStore] Failed to write to \(fileURL.path): \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Check if a preferences file exists
    /// - Parameter fileURL: The file URL to check
    /// - Returns: True if file exists and is readable
    func fileExists(at fileURL: URL) -> Bool {
        return fileQueue.sync {
            return FileManager.default.fileExists(atPath: fileURL.path)
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
                    print("[JSONPreferencesStore] Successfully deleted \(fileURL.lastPathComponent)")
                }
                return true
            } catch {
                print("[JSONPreferencesStore] Failed to delete \(fileURL.path): \(error.localizedDescription)")
                return false
            }
        }
    }
}

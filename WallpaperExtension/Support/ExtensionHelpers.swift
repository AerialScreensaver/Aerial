//
//  ExtensionHelpers.swift
//  Aerial
//
//  Helper functions and extensions for the extension target
//

import Foundation

// MARK: - JSON Helpers

/// Creates a JSONDecoder with ISO8601 date decoding strategy
func newJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

// MARK: - String Extensions

extension String {
    /// Capitalizes the first letter of the string
    func capitalizeFirstLetter() -> String {
        return self.prefix(1).capitalized + dropFirst()
    }
}

// MARK: - Double Extensions

extension Double {
    /// Rounds to specified decimal places
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

// MARK: - URL Extensions

extension URL {
    /// Returns subdirectories of this URL
    var subDirectories: [URL] {
        // No hasDirectoryPath guard: it depends on a stat that the
        // sandboxed extension can't always perform on /Volumes paths
        // (URL(fileURLWithPath:) without isDirectory:), which silently
        // returned []. contentsOfDirectory fails cleanly on non-dirs.
        return (try? FileManager.default.contentsOfDirectory(at: self, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.filter(\.hasDirectoryPath) ?? []
    }
}

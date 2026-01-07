//
//  AerialPaths.swift
//  Aerial
//
//  Shared path constants for both Companion and Screensaver
//  All Aerial data lives in /Users/Shared/Aerial/
//

import Foundation

/// Centralized path constants for all Aerial data
/// Used by both Companion app and Screensaver
enum AerialPaths {
    // MARK: - Path Constants

    /// The base directory for all Aerial data
    static let baseDirectory = "/Users/Shared/Aerial"

    /// Marker file that indicates this directory is managed by Companion
    static let companionMarker = "companion.json"

    /// Subdirectories
    static let logsDirectory = "Logs"
    static let cacheDirectory = "Cache"
    static let thumbnailsDirectory = "Thumbnails"
    static let sourcesDirectory = "Sources"
    static let myVideosDirectory = "My Videos"

    // MARK: - Helper Methods

    /// Get the full path for the Logs directory
    static func logsPath() -> String {
        return baseDirectory + "/" + logsDirectory
    }

    /// Get the full path for the Cache directory
    static func cachePath() -> String {
        return baseDirectory + "/" + cacheDirectory
    }

    /// Get the full path for the Thumbnails directory
    static func thumbnailsPath() -> String {
        return baseDirectory + "/" + thumbnailsDirectory
    }

    /// Get the full path for the Sources directory
    static func sourcesPath() -> String {
        return baseDirectory + "/" + sourcesDirectory
    }

    /// Get the full path for the My Videos directory
    static func myVideosPath() -> String {
        return baseDirectory + "/" + myVideosDirectory
    }

    /// Check if the base directory is already initialized
    /// (by checking for the companion.json marker file)
    static func isInitialized() -> Bool {
        let markerPath = baseDirectory + "/" + companionMarker
        return FileManager.default.fileExists(atPath: markerPath)
    }
}

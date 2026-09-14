//
//  FileHelpers.swift
//  Aerial
//
//  Created by Guillaume Louel on 08/07/2020.
//  Copyright © 2020 Guillaume Louel. All rights reserved.
//

import Foundation

struct FileHelpers {
    static func createDirectory(atPath: String) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: atPath) == false {
            do {
                try fileManager.createDirectory(atPath: atPath,
                                                withIntermediateDirectories: true, attributes: nil)
            } catch let error {
                errorLog("Couldn't create directory at \(atPath) : \(error)")
                errorLog("FATAL : There's nothing more we can do at this point, please report")
            }
        }
    }

    /// Runs `/usr/bin/tar -xf file` inside `atPath`. Returns false when
    /// tar can't be launched or exits non-zero (truncated download, HTML
    /// error page saved as a .tar, disk full…) so callers can keep what
    /// they had instead of trusting a half-extracted folder.
    @discardableResult
    static func unTar(file: String, atPath: String) -> Bool {
        let process = Process()

        debugLog("untaring \(file) at \(atPath)")
        process.currentDirectoryPath = atPath
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", file]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            errorLog("Couldn't launch tar for \(file): \(error.localizedDescription)")
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            errorLog("tar exited with status \(process.terminationStatus) for \(file)")
            return false
        }
        return true
    }

    // MARK: - Feed archives (Apple's resources-*.tar)

    static let feedEntriesFileName = "entries.json"
    static let feedStringsBundleName = "TVIdleScreenStrings.bundle"

    /// Installs a downloaded feed tar into a source folder without ever
    /// leaving that folder in a broken state:
    ///
    /// 1. extract into `<folder>/.staging/`,
    /// 2. require a decodable, non-empty `entries.json` in there,
    /// 3. swap the payload into place — the old `TVIdleScreenStrings.bundle`
    ///    is removed first (macOS 27 moved its strings from flat
    ///    `<lang>.lproj/*.strings` to `Contents/Resources/*.loctable`;
    ///    extracting over the old layout would keep both, stale one
    ///    winning), `entries.json` goes last via an atomic replace,
    /// 4. drop the staging dir and every OTHER `resources-*.tar`, so the
    ///    tar that stays is the installed-feed marker `Source.feedMarkerPath`
    ///    reads.
    ///
    /// On any failure the current `entries.json` is untouched and the bad
    /// tar is deleted, so `Source.needsFeedUpgrade()` retries next launch.
    @discardableResult
    static func installFeedArchive(tar tarPath: String, into folder: String) -> Bool {
        let fm = FileManager.default
        let tarName = (tarPath as NSString).lastPathComponent
        let staging = folder + "/.staging"
        try? fm.removeItem(atPath: staging)
        defer { try? fm.removeItem(atPath: staging) }

        func fail(_ why: String) -> Bool {
            errorLog("🍎 [AppleFeed] \(why) — keeping the current \(feedEntriesFileName) in \(folder)")
            try? fm.removeItem(atPath: tarPath)
            return false
        }

        do {
            try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
        } catch {
            return fail("can't create staging dir: \(error.localizedDescription)")
        }

        guard unTar(file: tarPath, atPath: staging) else {
            return fail("staged untar failed for \(tarName)")
        }

        let stagedEntries = staging + "/" + feedEntriesFileName
        guard let data = fm.contents(atPath: stagedEntries), feedEntriesLookValid(data) else {
            return fail("\(tarName) has no usable \(feedEntriesFileName)")
        }

        do {
            // Everything but entries.json first (strings bundle, *.mat…):
            // remove the old copy, move the new one in.
            let items = try fm.contentsOfDirectory(atPath: staging).filter { $0 != feedEntriesFileName }
            for item in items {
                let dst = folder + "/" + item
                if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
                try fm.moveItem(atPath: staging + "/" + item, toPath: dst)
            }
            // entries.json last, atomically — a crash between the two
            // steps above costs strings until the next retry, never the
            // catalog.
            let dstEntries = URL(fileURLWithPath: folder + "/" + feedEntriesFileName)
            if fm.fileExists(atPath: dstEntries.path) {
                _ = try fm.replaceItemAt(dstEntries, withItemAt: URL(fileURLWithPath: stagedEntries))
            } else {
                try fm.moveItem(atPath: stagedEntries, toPath: dstEntries.path)
            }
        } catch {
            return fail("couldn't move the staged feed into place: \(error.localizedDescription)")
        }

        // Only the freshly installed tar stays behind (feed marker).
        if let items = try? fm.contentsOfDirectory(atPath: folder) {
            for item in items where item.hasPrefix("resources") && item.hasSuffix(".tar") && item != tarName {
                try? fm.removeItem(atPath: folder + "/" + item)
            }
        }
        debugLog("🍎 [AppleFeed] installed \(tarName) into \(folder)")
        return true
    }

    /// A feed `entries.json` is usable when either Apple manifest shape
    /// decodes with at least one asset.
    static func feedEntriesLookValid(_ data: Data) -> Bool {
        let decoder = JSONDecoder()
        if let mac = try? decoder.decode(MacManifest.self, from: data) { return !mac.assets.isEmpty }
        if let tv = try? decoder.decode(VideoManifest.self, from: data) { return !tv.assets.isEmpty }
        return false
    }
}

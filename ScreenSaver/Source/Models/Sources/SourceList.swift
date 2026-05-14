//
//  SourceList.swift
//  Aerial
//
//  Created by Guillaume Louel on 01/07/2020.
//  Copyright © 2020 Guillaume Louel. All rights reserved.
//

import Foundation

struct SourceHeader {
    let name: String
    let sources: [Source]
}

// swiftlint:disable:next type_body_length
struct SourceList {
    // This is the current one until next fall (those are easy-ish to find)
    static let macOS26 = Source(name: "macOS 26",
                        description: "High framerate videos from macOS 26",
                        manifestUrl: "https://sylvan.apple.com/itunes-assets/Aerials126/v4/82/2e/34/822e344c-f5d2-878c-3d56-508d5b09ed61/resources-26-0-1.tar",
                        type: .macOS,
                        scenes: [.nature, .city, .space, .sea],
                        isCachable: true,
                        license: "",
                        more: "")
    

    // This is the current one until next fall (but we have a hard time finding those)
    static let tvOS26 = Source(name: "tvOS 26",
                        description: "Apple TV screensavers from tvOS 26",
                        manifestUrl: "https://sylvan.apple.com/itunes-assets/Aerials126/v4/c0/45/d9/c045d9d0-9606-1535-62fe-189edb4f79eb/resources-atv-23J-2.tar",
                        type: .macOS,
                        scenes: [.nature, .city, .space, .sea],
                        isCachable: true,
                        license: "",
                        more: "")

    // Legacy sources - TODO we really need to remove that one now.
    static let tvOS13 = Source(name: "tvOS 13",
                        description: "Apple TV screensavers from tvOS 13",
                        manifestUrl: "https://sylvan.apple.com/Aerials/resources-13.tar",
                        type: .tvOS12,
                        scenes: [.nature, .city, .space, .sea],
                        isCachable: true,
                        license: "",
                        more: "")


    static var list: [Source] = [macOS26, tvOS26, tvOS13] + foundSources
    // static var list: [Source] = foundSources

    // MARK: - Legacy community removal (one-shot)
    //
    // Older builds auto-installed a community pack from
    //   https://aerialscreensaver.github.io/community/
    // which created the source folder "From Joshua Michaels & Hal Bergman"
    // under `Sources/`. We've dropped the auto-install — users now add
    // community packs through the Expansions UI in the Video Library —
    // and we delete the legacy folder (manifest, entries, and any cached
    // videos inside) so the listing stays clean. Reinstall is via
    // Expansions if the user still wants it.
    //
    // Detection is an exact folder-name match — won't false-positive on
    // user-renamed folders or on user-installed expansions. After
    // deletion the folder is gone, so the function is naturally a no-op
    // on subsequent launches.

    private static let legacyCommunityFolderName = "From Joshua Michaels & Hal Bergman"

    // This is where the magic happens
    static var foundSources: [Source] {
        // Run cleanup first so the legacy folder is gone before enumeration —
        // it never makes it into `list`, and nothing downstream sees it.
        removeLegacyCommunityIfNeeded()

        var sources: [Source] = []

        // Look in the Sources subdirectory
        let sourcesPath = Cache.supportPath.appending("/Sources")
        if FileManager.default.fileExists(atPath: sourcesPath) {
            for folder in URL(fileURLWithPath: sourcesPath).subDirectories {
                if !folder.lastPathComponent.starts(with: "tvOS")
                    && !folder.lastPathComponent.starts(with: "macOS")
                    && !folder.lastPathComponent.starts(with: "backups") {

                    // If it's valid, let's add !
                    if let source = loadManifest(url: folder) {
                        sources.append(source)
                    } else if let newsources = loadMetaManifest(url: folder) {
                        sources.append(contentsOf: newsources)
                    }
                }
            }
        }

        return sources
    }

    /// Sync, destructive removal of the legacy auto-installed community
    /// pack. Detection: a `Sources/<legacyCommunityFolderName>/` folder
    /// exists. The whole folder (manifest, entries, and any cached video
    /// files inside) is removed via `FileManager.removeItem`. Idempotent:
    /// once the folder is gone the existence check skips it.
    static func removeLegacyCommunityIfNeeded() {
        let folderPath = Cache.supportPath.appending("/Sources/\(legacyCommunityFolderName)")
        guard FileManager.default.fileExists(atPath: folderPath) else { return }

        do {
            try FileManager.default.removeItem(atPath: folderPath)
            debugLog("🧹 Removed legacy community source: \(legacyCommunityFolderName)")
        } catch {
            errorLog("Couldn't remove legacy community folder \(legacyCommunityFolderName): \(error.localizedDescription)")
        }
    }

    /// Ensures the default "My Videos" source exists and is enabled
    /// This is called on every launch to auto-discover user videos
    static func ensureDefaultLocalSource() {
        let folderName = "My Videos"
        let folderPath = "/Users/Shared/Aerial/\(folderName)"

        // Check if the folder exists (should always exist after UnifiedPaths init)
        guard FileManager.default.fileExists(atPath: folderPath) else {
            debugLog("My Videos folder doesn't exist yet")
            return
        }

        // Check if the source already exists in the list
        if let existingSource = list.first(where: { $0.name == folderName && $0.type == .local }) {
            // Source exists - refresh it to pick up any new videos
            debugLog("Refreshing My Videos source")
            updateLocalSource(source: existingSource, reload: true)
        } else {
            // Source doesn't exist - create it and scan for videos
            debugLog("Creating My Videos source")

            let source = Source(name: folderName,
                               description: "Videos from /Users/Shared/Aerial/My Videos/",
                               manifestUrl: folderPath,
                               type: .local,
                               scenes: [.nature],
                               isCachable: false,
                               license: "",
                               more: "")

            // Scan the folder for videos
            let url = URL(fileURLWithPath: folderPath)
            var assets = [VideoAsset]()

            do {
                let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

                for lurl in urls {
                    if lurl.path.lowercased().hasSuffix(".mp4") || lurl.path.lowercased().hasSuffix(".mov") {
                        let fileManager = FileManager.default
                        let attributes = try? fileManager.attributesOfItem(atPath: lurl.path)
                        let fileType = attributes?[.type] as? FileAttributeType
                        let resourceValues = try lurl.resourceValues(forKeys: [.fileSizeKey])
                        let fileSize = resourceValues.fileSize ?? 0

                        if fileSize > 500000 || fileType == .typeSymbolicLink {
                            assets.append(VideoAsset(accessibilityLabel: folderName,
                                                     id: NSUUID().uuidString,
                                                     title: lurl.lastPathComponent,
                                                     timeOfDay: "day",
                                                     scene: "",
                                                     pointsOfInterest: [:],
                                                     url4KHDR: "",
                                                     url4KSDR: lurl.path,
                                                     url1080H264: "",
                                                     url1080HDR: "",
                                                     url4KSDR120FPS: "",
                                                     url4KSDR240FPS: "",
                                                     url1080SDR: "",
                                                     url: "",
                                                     type: "nature"))
                        }
                    }
                }
            } catch {
                errorLog("Could not scan My Videos directory: \(error.localizedDescription)")
            }

            // Save the source manifest
            saveSource(source)

            // Save entries.json with found videos (even if empty)
            let videoManifest = VideoManifest(assets: assets, initialAssetCount: 1, version: 1)
            saveEntries(source: source, manifest: videoManifest)

            // Add to list and enable
            list.append(source)
            source.setEnabled(true)

            debugLog("My Videos source created with \(assets.count) videos")
        }
    }

    static func categorizedSourceList() -> [SourceHeader] {
        var communities: [Source] = []
        var online: [Source] = []
        var local: [Source] = []
        var apple: [Source] = []

        for source in list { // where !source.name.starts(with: "tvOS") {
            if source.type == .local {
                local.append(source)
            } else {
                // This may need to be changed in the future
                if !source.isCachable {
                    online.append(source)
                } else if source.name.starts(with: "tvOS") || source.name.starts(with: "macOS") {
                    apple.append(source)
                } else {
                    communities.append(source)
                }
            }
        }

        // Then we build our list
        var output: [SourceHeader] = []

        if !communities.isEmpty {
            output.append(SourceHeader(name: "Community Videos", sources: communities))
        }

        if !online.isEmpty {
            output.append(SourceHeader(name: "Online Sources", sources: online))
        }

        if !apple.isEmpty {
            output.append(SourceHeader(name: "Apple", sources: apple))
        }

        if !local.isEmpty {
            output.append(SourceHeader(name: "Local Sources", sources: local))
        }

        return output
    }

    static func fetchOnlineManifest(url: URL) {
        if let source = loadManifest(url: url) {
            debugLog("Source loaded")
            // Dedup guard: refuse to add a second entry with the same
            // name. Without this, pasting the same install URL twice
            // would duplicate `name` in `list`, which crashes
            // `CacheOrphanReaper.maybeReap()` when it builds its
            // per-source dict with `Dictionary(uniqueKeysWithValues:)`.
            // The pre-flight in `InstallFromLinkView` already
            // short-circuits the all-dupes case; this is the durable
            // belt-and-braces fix for any other caller.
            guard !list.contains(where: { $0.name == source.name }) else {
                debugLog("fetchOnlineManifest: source '\(source.name)' already in list — skipping append.")
                return
            }
            saveSource(source)

            let downloadManager = DownloadManager()
            downloadManager.queueDownload(url.appendingPathComponent("manifest.json"), folder: source.name)

            downloadManager.queueDownload(URL(string: source.manifestUrl)!, folder: source.name)
            list.append(source)

            source.setEnabled(true) // This will reload the main video list
        } else if let sources = loadMetaManifest(url: url) {
            debugLog("Sources loaded")

            for source in sources {
                // Same dedup as the single-manifest branch — meta-
                // manifests with partial overlap (some new, some
                // already installed) need this per-source check so
                // only the genuinely new ones get appended.
                guard !list.contains(where: { $0.name == source.name }) else {
                    debugLog("fetchOnlineManifest: source '\(source.name)' already in list — skipping append.")
                    continue
                }
                // Then save !
                saveSource(source)

                let downloadManager = DownloadManager()
                downloadManager.queueDownload(URL(string: source.manifestUrl)!, folder: source.name)
                list.append(source)

                source.setEnabled(true) // This will reload the main video list
            }
        } else {
            debugLog("Something went wrong here")
            let task = URLSession.shared.dataTask(with: url) { _, response, error in

                if let error = error {
                    debugLog("Can't load file, possible firewall issue")
                    DispatchQueue.main.async {
                        Aerial.helper.showErrorAlert(question: "An error occured loading the file",
                            text: "Please check your network connection, firewall, and try again. \n\nError : \(error.localizedDescription)")
                    }
                    return
                }
                guard let response = response as? HTTPURLResponse else {
                    debugLog("No HTTP response")

                    DispatchQueue.main.async {
                        Aerial.helper.showErrorAlert(question: "No HTTP Response",
                                              text: "Please check your network connection, firewall, and try again.")
                    }
                    return
                }

                if response.statusCode != 200 {
                    DispatchQueue.main.async {
                        debugLog("HTTP error")

                        Aerial.helper.showErrorAlert(question: "HTTP Error",
                            text: "Please verify the URL (and check your network connexion and firewall). HTTP error: \(response.statusCode)")
                    }
                    return
                } else {
                    DispatchQueue.main.async {
                        debugLog("Incorect JSON format")

                        Aerial.helper.showErrorAlert(question: "Incorrect JSON Format",
                                              text: "Your URL was valid, but the file is not in the correct format. Please check the URL.")
                    }
                    return
                }
            }
            task.resume()
        }
    }
    //#endif

    static func updateLocalSource(source: Source, reload: Bool) {
        // We need the raw manifest to find the path inside
        let videos = source.getUnprocessedVideos()
        let originalAssets = source.getUnprocessedAssets()

        var updatedAssets = [VideoAsset]()

        // Determine the folder URL - either from existing videos or from known paths
        let url: URL
        if videos.count >= 1 {
            url = videos.first!.url.deletingLastPathComponent()
        } else if source.name == "My Videos" {
            // Special case for built-in My Videos source - we know the exact location
            let myVideosPath = "/Users/Shared/Aerial/My Videos"
            if FileManager.default.fileExists(atPath: myVideosPath) {
                url = URL(fileURLWithPath: myVideosPath)
            } else {
                debugLog("My Videos folder doesn't exist at \(myVideosPath)")
                return
            }
        } else if source.type == .local && FileManager.default.fileExists(atPath: source.manifestUrl) {
            // For other local sources, use manifestUrl (which should be the folder path)
            url = URL(fileURLWithPath: source.manifestUrl)
        } else {
            debugLog("Cannot determine folder path for source: \(source.name)")
            return
        }

        let folderName = url.lastPathComponent
        debugLog("processing url for videos : \(url)")

        do {
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

            for lurl in urls {
                if lurl.path.lowercased().hasSuffix(".mp4") || lurl.path.lowercased().hasSuffix(".mov") {
                    let fileManager = FileManager.default
                    let attributes = try? fileManager.attributesOfItem(atPath: lurl.path)
                    let fileType = attributes?[.type] as? FileAttributeType
                    let resourceValues = try lurl.resourceValues(forKeys: [.fileSizeKey])
                    let fileSize = resourceValues.fileSize ?? 0

                    if fileSize > 500000 || fileType == .typeSymbolicLink {
                        // Check if the asset was there previously
                        let foundAssets = originalAssets.filter { $0.url4KSDR == lurl.path }

                        if let foundAsset = foundAssets.first {
                            // Just add the asset to the new array
                            updatedAssets.append(foundAsset)
                        } else {
                            // Create a new entry
                            updatedAssets.append(VideoAsset(accessibilityLabel: folderName,
                                                     id: NSUUID().uuidString,
                                                     title: lurl.lastPathComponent,
                                                     timeOfDay: "day",
                                                     scene: "",
                                                     pointsOfInterest: [:],
                                                     url4KHDR: "",
                                                     url4KSDR: lurl.path,
                                                     url1080H264: "",
                                                     url1080HDR: "",
                                                     url4KSDR120FPS: "",
                                                     url4KSDR240FPS: "",
                                                     url1080SDR: "",
                                                     url: "",
                                                     type: "nature"))
                        }
                    }
                }
            }

            debugLog("Updating manifest \(url.lastPathComponent) with \(updatedAssets.count) videos")

            let videoManifest = VideoManifest(assets: updatedAssets, initialAssetCount: 1, version: 1)

            SourceList.saveEntries(source: source, manifest: videoManifest)

            // Fix corrupt manifests: if manifestUrl doesn't point to the actual folder, update it
            if source.name == "My Videos" && source.manifestUrl != url.path {
                // Create a corrected source and re-save the manifest
                let correctedSource = Source(name: source.name,
                                            description: source.description,
                                            manifestUrl: url.path,
                                            type: source.type,
                                            scenes: source.scenes,
                                            isCachable: source.isCachable,
                                            license: source.license,
                                            more: source.more)
                SourceList.saveSource(correctedSource)
                debugLog("Fixed My Videos manifest with correct path: \(url.path)")
            }

            if reload {
                VideoList.instance.reloadSources()
            }
        } catch {
            errorLog("Could not process directory: \(error.localizedDescription)")
        }
    }

    static func saveSource(_ source: Source) {
        let manifest = Manifest.init(name: source.name,
                                     manifestDescription: source.description,
                                     scenes: source.scenes.map({ $0.rawValue }),
                                     local: source.type == .local,
                                     cacheable: source.isCachable,
                                     manifestUrl: source.manifestUrl,
                                     license: source.license,
                                     more: source.more)

        // First make the folder
        try? FileManager.default.createDirectory(atPath: Cache.supportPath.appending("/Sources/"+source.name), withIntermediateDirectories: true, attributes: nil)

        guard let json = try? JSONEncoder().encode(manifest) else {
            errorLog("Can't encode local source manifest")
            return
        }

        do {
            try json.write(to: URL(fileURLWithPath:
                                    Cache.supportPath.appending("/Sources/"+source.name+"/manifest.json")))
        } catch {
            errorLog("Can't save local source : \(error.localizedDescription)")
        }
    }

    static func saveEntries(source: Source, manifest: VideoManifest) {
        guard let json = try? JSONEncoder().encode(manifest) else {
            errorLog("Can't encode local entries")
            return
        }

        do {
            try json.write(to: URL(fileURLWithPath:
                                    Cache.supportPath.appending("/Sources/"+source.name+"/entries.json")))
        } catch {
            errorLog("Can't save local entries : \(error.localizedDescription)")
        }
    }
    static func loadMetaManifest(url: URL) -> [Source]? {
        // Let's make sure we have the required files
        if !areManifestPresent(url: url) && !url.absoluteString.starts(with: "http") {
            return nil
        }

        do {
            let jsonData = try Data(contentsOf: url.appendingPathComponent("manifest.json"))

            if let metamanifest = try? newJSONDecoder().decode(MetaManifest.self, from: jsonData) {
                var sources: [Source] = []

                for manifest in metamanifest.sources {
                    sources.append(parseSourceFromManifest(manifest, url: url))
                }

                return sources
            }
        } catch {
            errorLog("Could not open manifest for source at \(url)")
            return nil
        }

        return nil
    }

    static func loadManifest(url: URL) -> Source? {
        // Let's make sure we have the required files
        if !areManifestPresent(url: url) && !url.absoluteString.starts(with: "http") {
            return nil
        }

        do {
            let jsonData = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
            if let manifest = try? newJSONDecoder().decode(Manifest.self, from: jsonData) {
                debugLog("Manifest opened, going to parsing")
                return parseSourceFromManifest(manifest, url: nil)
            }
        } catch {
            errorLog("Could not open manifest for source at \(url)")
            return nil
        }

        return nil
    }

    static private func parseSourceFromManifest(_ manifest: Manifest, url: URL?) -> Source {
        var local = true
        var mURL: String
        if let isLocal = manifest.local {
            local = isLocal
        }

        if local {
            mURL = (url != nil) ? url!.absoluteString : manifest.manifestUrl ?? ""
        } else {
            mURL = manifest.manifestUrl ?? ""
        }

        let cacheable: Bool = manifest.cacheable ?? !local

        debugLog("Parsed \(manifest.name)")

        return Source(name: manifest.name,
                      description: manifest.manifestDescription,
                      manifestUrl: mURL,
                      type: local ? .local : .tvOS12,
                      scenes: jsonToSceneArray(array: manifest.scenes ?? []),
                      isCachable: cacheable,
                      license: manifest.license ?? "",
                      more: manifest.more ?? "")
    }

    /// Helper to convert an array of strings to an array of sources
    ///
    /// ["landscape"] -> [.landscape]
    static func jsonToSceneArray(array: [String]) -> [SourceScene] {
        var output: [SourceScene] = []
        for scene in array {
            switch scene {
            case "sea":
                output.append(.sea)
            case "space":
                output.append(.space)
            case "city":
                output.append(.city)
            case "beach":
                output.append(.beach)
            case "countryside":
                output.append(.countryside)
            default:
                output.append(.nature)
            }
        }

        return output
    }

    static func areManifestPresent(url: URL) -> Bool {
        // For a source to be valid we at the very least need two things
        // manifest.json    <- a description of the source
        // entries.json     <- the classic video manifest
        return FileManager.default.fileExists(atPath: url.path.appending("/entries.json")) ||
           FileManager.default.fileExists(atPath: url.path.appending("/manifest.json"))
    }

}

// MARK: - MetaManifest
struct MetaManifest: Codable {
    let sources: [Manifest]
}

// MARK: - Manifest
struct Manifest: Codable {
    let name, manifestDescription: String
    let scenes: [String]?
    let local: Bool?
    let cacheable: Bool?
    let manifestUrl: String?
    let license: String?
    let more: String?

    enum CodingKeys: String, CodingKey {
        case name
        case manifestDescription = "description"
        case scenes
        case local
        case cacheable
        case manifestUrl
        case license
        case more
    }
}

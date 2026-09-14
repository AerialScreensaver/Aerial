//
//  Source.swift
//  Aerial
//
//  Created by Guillaume Louel on 01/07/2020.
//  Copyright © 2020 Guillaume Louel. All rights reserved.
//

import Foundation

private extension Optional where Wrapped == String {
    /// Coalesces a nil-or-empty optional string to `nil`. Apple's
    /// macOS manifests inconsistently use the empty string `""` to
    /// mean "field absent" (e.g. `previewImage-900x580` is published
    /// as `""` when no 900×580 variant exists), which breaks the
    /// `??` operator since `??` only falls through on `nil`.
    var nilIfEmpty: String? {
        guard let s = self, !s.isEmpty else { return nil }
        return s
    }
}

// 10 has a different format
// 11 is similar to 12+, but does not include pointsOfInterests
// 12/13 share a same format, and we use that format for local videos too
enum SourceType: Int, Codable {
    case local, tvOS10, tvOS11, tvOS12, macOS, live
}

enum SourceScene: String, Codable, CaseIterable {
    case nature = "Nature", city = "City", space = "Space", sea = "Sea", beach = "Beach", countryside = "Countryside"
}

// swiftlint:disable:next type_body_length
struct Source: Codable {
    var name: String
    var description: String
    var manifestUrl: String
    var type: SourceType
    var scenes: [SourceScene]
    var isCachable: Bool
    var license: String
    var more: String
    
    func isEnabled() -> Bool {
        if PrefsVideos.enabledSources.keys.contains(name) {
            return PrefsVideos.enabledSources[name]!
        }

        // Unknown sources are enabled by default
        return true
    }

    func setEnabled(_ enabled: Bool) {
        PrefsVideos.enabledSources[name] = enabled
        VideoList.instance.reloadSources()
    }

    // Is the source already cached or not ?
    func isCached() -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: Cache.supportPath.appending("/Sources/" + name + "/entries.json"))
    }

    // Read local entries.json and return the video assets as an array
    // This is used to update in place the entries.json at startup when updating local sources
    func getUnprocessedAssets() -> [VideoAsset] {
        if isCached() {
            do {
                let cacheFileUrl = URL(fileURLWithPath: Cache.supportPath.appending("/Sources/" + name + "/entries.json"))
                let jsondata = try Data(contentsOf: cacheFileUrl)

                if let videoManifest = try? newJSONDecoder().decode(VideoManifest.self, from: jsondata) {
                    return videoManifest.assets
                }

                errorLog("### Could not parse manifest data")
                return []
            } catch {
                errorLog("\(name) could not be opened")
                return []
            }
        } else {
            debugLog("\(name) is not cached")
            return []
        }
    }
    
    func getUnprocessedVideos() -> [AerialVideo] {
        if isCached() {
            do {
                let cacheFileUrl = URL(fileURLWithPath: Cache.supportPath.appending("/Sources/" + name + "/entries.json"))
                let jsondata = try Data(contentsOf: cacheFileUrl)

                return readVideoManifest(jsondata)
            } catch {
                errorLog("\(name) could not be opened")
                return []
            }
        } else {
            debugLog("\(name) is not cached")
            return []
        }
    }

    func getVideos() -> [AerialVideo] {
        if isCached() {
            do {
                let cacheFileUrl = URL(fileURLWithPath: Cache.supportPath.appending("/Sources/" + name + "/entries.json"))
                let jsondata = try Data(contentsOf: cacheFileUrl)

                if name.starts(with: "tvOS 13") {
                    return parseVideoManifest(jsondata)
                } else if name.starts(with: "macOS") {
                    return parseMacManifest(jsondata)
                } else {
                    return parseVideoManifest(jsondata)
                }
            } catch {
                errorLog("\(name) could not be opened")
                return []
            }
        } else {
            debugLog("\(name) is not cached")
            return []
        }
    }

    func localizePath(_ path: String?) -> String {
        if let tpath = path {
            if manifestUrl.starts(with: "file://") {
                return manifestUrl + tpath
            }

            return tpath
        } else {
            return ""
        }
    }

    func getSubcategoryFor(_ asset: MacAsset, manifest: MacManifest) -> String {
        for category in manifest.categories {
            if category.subcategories != nil {
                for subcategory in category.subcategories! {
                    if subcategory.id == asset.subcategories.first {
                        return PoiStringProvider.sharedInstance.getLocalizedNameKey(key:subcategory.localizedNameKey)
                    }
                }
            }
        }
        
        return "Not found"
    }

    func getSecondaryNameFor(_ asset: VideoAsset) -> String {
        return asset.title ?? "Unknown"
    }

    func getSecondaryNameFor(_ asset: MacAsset) -> String {
        let poiStringProvider = PoiStringProvider.sharedInstance

        return poiStringProvider.getLocalizedNameKey(key: asset.localizedNameKey)
    }

    
    func getSceneFor(_ asset: VideoAsset) -> String {
        if let updatedScene = SourceInfo.getSceneForVideo(id: asset.id) {
            return updatedScene.rawValue.lowercased()
        } else {
            return asset.scene ?? "landscape"
        }
    }

    func getSceneFor(_ asset: MacAsset) -> String {
        if let updatedScene = SourceInfo.getSceneForVideo(id: asset.id) {
            return updatedScene.rawValue.lowercased()
        } else {
            return "landscape"
        }
    }

    
    // Generate URLs
    func urlsFor(_ asset: VideoAsset) -> [VideoFormat: String] {
        return [.v1080pH264: localizePath(asset.url1080H264),
                .v1080pHEVC: localizePath(asset.url1080SDR),
                .v1080pHDR: localizePath(asset.url1080HDR),
                .v4KHEVC: localizePath(asset.url4KSDR),
                .v4KHDR: localizePath(asset.url4KHDR),
                .v4KSDR240: localizePath(asset.url4KSDR240FPS) ]
    }

    /// Per-format MD5s for a `VideoAsset`. Only formats whose checksum
    /// is published get an entry; missing/empty MD5s are dropped so
    /// callers can use `[VideoFormat: String]` as the source of truth
    /// for "do I need to verify this format". Stored lowercase to
    /// avoid casing fights at compare time.
    func md5sFor(_ asset: VideoAsset) -> [VideoFormat: String] {
        var out: [VideoFormat: String] = [:]
        if let v = asset.url1080H264_md5, !v.isEmpty { out[.v1080pH264] = v.lowercased() }
        if let v = asset.url1080SDR_md5, !v.isEmpty { out[.v1080pHEVC] = v.lowercased() }
        if let v = asset.url1080HDR_md5, !v.isEmpty { out[.v1080pHDR] = v.lowercased() }
        if let v = asset.url4KSDR_md5, !v.isEmpty { out[.v4KHEVC] = v.lowercased() }
        if let v = asset.url4KHDR_md5, !v.isEmpty { out[.v4KHDR] = v.lowercased() }
        if let v = asset.url4KSDR240FPS_md5, !v.isEmpty { out[.v4KSDR240] = v.lowercased() }
        return out
    }

    // Mac manifest only has 240 fps
    func urlsFor(_ asset: MacAsset) -> [VideoFormat: String] {
        return [.v1080pH264: "",
                .v1080pHEVC: "",
                .v1080pHDR: "",
                .v4KHEVC: "",
                .v4KHDR: "",
                .v4KSDR240: localizePath(asset.url4KSDR240FPS) ]
    }
    
    func readVideoManifest(_ data: Data) -> [AerialVideo] {
        if let videoManifest = try? newJSONDecoder().decode(VideoManifest.self, from: data) {
            var processedVideos: [AerialVideo] = []

            for asset in videoManifest.assets {
                let video = AerialVideo(id: asset.id,
                    name: asset.accessibilityLabel,
                    secondaryName: getSecondaryNameFor(asset),
                    type: "video",
                    timeOfDay: asset.timeOfDay ?? "day",
                    scene: getSceneFor(asset),
                    urls: urlsFor(asset),
                    sources: [self],
                    poi: asset.pointsOfInterest ?? [:],
                    md5s: md5sFor(asset),
                    isLive: asset.isLive ?? false,
                    livePlaybackSeconds: asset.livePlaybackSeconds ?? 300,
                    previewImage: asset.previewImage.nilIfEmpty)

                processedVideos.append(video)
            }

            return processedVideos
        }

        errorLog("### Could not parse manifest data")
        return []
    }

    func parseVideoManifest(_ data: Data) -> [AerialVideo] {
        if let videoManifest = try? newJSONDecoder().decode(VideoManifest.self, from: data) {
            var processedVideos: [AerialVideo] = []

            for asset in videoManifest.assets {
                let (isDupe, foundVideo) = SourceInfo.findDuplicate(id: asset.id, url1080pH264: asset.url1080H264 ?? "")

                if !isDupe {
                    let video = AerialVideo(id: asset.id,
                        name: asset.accessibilityLabel,
                        secondaryName: getSecondaryNameFor(asset),
                        type: "video",
                        timeOfDay: asset.timeOfDay ?? "day",
                        scene: getSceneFor(asset),
                        urls: urlsFor(asset),
                        sources: [self],
                        poi: asset.pointsOfInterest ?? [:],
                        md5s: md5sFor(asset),
                        isLive: asset.isLive ?? false,
                        livePlaybackSeconds: asset.livePlaybackSeconds ?? 300,
                        previewImage: asset.previewImage.nilIfEmpty)

                    processedVideos.append(video)
                } else {
                    // Record that this manifest also ships the video.
                    // Filter-by-source uses `sources` membership so the
                    // entry shows up under every source that lists it.
                    if let found = foundVideo,
                       !found.sources.contains(where: { $0.name == self.name }) {
                        found.sources.append(self)
                    }
                    // Merge urls with macOS manifest. Whenever we patch
                    // a URL in, also record that it came from *this*
                    // source so the UI can attribute it correctly.
                    // The MD5 is patched in lockstep so a later source's
                    // checksum applies to the URL it just provided.
                    let assetURLs = urlsFor(asset)
                    let assetMD5s = md5sFor(asset)
                    let formats: [VideoFormat] = [.v4KHDR, .v4KHEVC, .v1080pHDR, .v1080pHEVC, .v1080pH264, .v4KSDR240]
                    for format in formats {
                        if foundVideo?.urls[format] == "",
                           let newURL = assetURLs[format], newURL != "" {
                            foundVideo?.urls[format] = newURL
                            foundVideo?.urlSources[format] = self
                            foundVideo?.urlMD5s[format] = assetMD5s[format]
                        }
                    }
                    // Patch in a previewImage URL if the existing entry
                    // (created by an earlier source) didn't carry one.
                    // First-write-wins semantics; macOS's previewImage
                    // already on the entry stays put.
                    if foundVideo?.previewImage == nil,
                       let newPreview = asset.previewImage, !newPreview.isEmpty {
                        foundVideo?.previewImage = newPreview
                    }
                }
            }

            return processedVideos
        }

        errorLog("### Could not parse manifest data")
        return []
    }
    
    func parseMacManifest(_ data: Data) -> [AerialVideo] {
        if let videoManifest = try? newJSONDecoder().decode(MacManifest.self, from: data) {
            var processedVideos: [AerialVideo] = []

            for asset in videoManifest.assets {
                let (isDupe, _) = SourceInfo.findDuplicate(id: asset.id, url1080pH264: "")

                if !isDupe {
                    let video = AerialVideo(id: asset.id,
                        name: getSubcategoryFor(asset, manifest: videoManifest),
                        secondaryName: getSecondaryNameFor(asset),
                        type: "video",
                        timeOfDay: "day",
                        scene: getSceneFor(asset),
                        urls: urlsFor(asset),
                        sources: [self],
                        poi: asset.pointsOfInterest, // ?? [:],
                        previewImage: asset.previewImage.nilIfEmpty)

                    processedVideos.append(video)
                }
            }

            return processedVideos
        }

        errorLog("### Could not parse manifest data")
        return []
    }
    
}

// MARK: - VideoManifest
/// The newer format used by all our other JSONs
struct VideoManifest: Codable {
    let assets: [VideoAsset]
    let initialAssetCount, version: Int?
}

// MARK: - VideoAsset
/// Common Asset structure for all our JSONs
///
/// I've added multiple extra fields that aren't in Apple's JSONs, including:
/// - title: as in Los Angeles (accesibilityLabel) / Santa Monica Beach (title)
/// - timeOfDay: only on tvOS 10, resurected for custom sources, can also be sunset or sunrise
/// - scene: landscape, city, space, sea
struct VideoAsset: Codable {
    let accessibilityLabel, id: String
    let title: String?
    let timeOfDay: String?
    let scene: String?
    let pointsOfInterest: [String: String]?
    let url4KHDR, url4KSDR, url1080H264, url1080HDR, url4KSDR120FPS, url4KSDR240FPS: String?
    let url1080SDR, url: String?
    let type: String?
    /// Set by Live Feeds source entries. Omitted from regular manifests.
    let isLive: Bool?
    /// How long (seconds) to play a live stream before rotating.
    let livePlaybackSeconds: Double?

    /// Manifest-provided still image URL (typically ~900×580 PNG).
    /// Currently published by macOS sources via `MacAsset`; future
    /// tvOS / community manifests are expected to publish it here too.
    let previewImage: String?

    /// Optional per-format MD5 digests, expected as lowercase hex.
    /// Sibling keys to the URL fields (e.g. `url-4K-SDR-md5` next to
    /// `url-4K-SDR`). Manifests that don't carry checksums simply
    /// decode these as nil and verification is skipped.
    let url4KHDR_md5, url4KSDR_md5: String?
    let url1080H264_md5, url1080HDR_md5, url1080SDR_md5: String?
    let url4KSDR120FPS_md5, url4KSDR240FPS_md5: String?

    enum CodingKeys: String, CodingKey {
        case accessibilityLabel, id, pointsOfInterest
        case title, timeOfDay, scene
        case url4KHDR = "url-4K-HDR"
        case url4KSDR = "url-4K-SDR"
        case url1080H264 = "url-1080-H264"
        case url1080HDR = "url-1080-HDR"
        case url1080SDR = "url-1080-SDR"
        case url4KSDR240FPS = "url-4K-SDR-240FPS"
        case url4KSDR120FPS = "url-4K-SDR-120FPS"
        case url
        case type
        case isLive
        case livePlaybackSeconds
        case previewImage
        case url4KHDR_md5       = "url-4K-HDR-md5"
        case url4KSDR_md5       = "url-4K-SDR-md5"
        case url1080H264_md5    = "url-1080-H264-md5"
        case url1080HDR_md5     = "url-1080-HDR-md5"
        case url1080SDR_md5     = "url-1080-SDR-md5"
        case url4KSDR240FPS_md5 = "url-4K-SDR-240FPS-md5"
        case url4KSDR120FPS_md5 = "url-4K-SDR-120FPS-md5"
    }

    /// Convenience memberwise init with defaulted `isLive` / `livePlaybackSeconds`
    /// and MD5 fields so existing call sites that predate those compile unchanged.
    init(accessibilityLabel: String, id: String, title: String?, timeOfDay: String?,
         scene: String?, pointsOfInterest: [String: String]?,
         url4KHDR: String?, url4KSDR: String?, url1080H264: String?, url1080HDR: String?,
         url4KSDR120FPS: String?, url4KSDR240FPS: String?, url1080SDR: String?,
         url: String?, type: String?,
         isLive: Bool? = nil, livePlaybackSeconds: Double? = nil,
         previewImage: String? = nil,
         url4KHDR_md5: String? = nil, url4KSDR_md5: String? = nil,
         url1080H264_md5: String? = nil, url1080HDR_md5: String? = nil,
         url1080SDR_md5: String? = nil,
         url4KSDR120FPS_md5: String? = nil, url4KSDR240FPS_md5: String? = nil) {
        self.accessibilityLabel = accessibilityLabel
        self.id = id
        self.title = title
        self.timeOfDay = timeOfDay
        self.scene = scene
        self.pointsOfInterest = pointsOfInterest
        self.url4KHDR = url4KHDR
        self.url4KSDR = url4KSDR
        self.url1080H264 = url1080H264
        self.url1080HDR = url1080HDR
        self.url4KSDR120FPS = url4KSDR120FPS
        self.url4KSDR240FPS = url4KSDR240FPS
        self.url1080SDR = url1080SDR
        self.url = url
        self.type = type
        self.isLive = isLive
        self.livePlaybackSeconds = livePlaybackSeconds
        self.previewImage = previewImage
        self.url4KHDR_md5 = url4KHDR_md5
        self.url4KSDR_md5 = url4KSDR_md5
        self.url1080H264_md5 = url1080H264_md5
        self.url1080HDR_md5 = url1080HDR_md5
        self.url1080SDR_md5 = url1080SDR_md5
        self.url4KSDR120FPS_md5 = url4KSDR120FPS_md5
        self.url4KSDR240FPS_md5 = url4KSDR240FPS_md5
    }
}

// MARK: - MACManifest
struct MacManifest: Codable {
    let localizationVersion: LocalizationVersion
    let categories: [SubcategoryElement]
    let initialAssetCount: Int
    let assets: [MacAsset]
    let version: Int
}

// MARK: - Asset
struct MacAsset: Codable {
    let shotID: String
    /// Apple's preview image URL for the asset. Optional / may be
    /// missing or empty in practice; `previewImage-900x580` is also
    /// in the manifest but is always empty, so we ignore it entirely.
    let previewImage: String?
    let localizedNameKey, accessibilityLabel: String
    let preferredOrder: Int
    let categories: [String]
    let id: String
    let subcategories: [String]
    let pointsOfInterest: [String: String]
    let url4KSDR240FPS: String
    let includeInShuffle, showInTopLevel: Bool
    let group: LocalizationVersion?

    enum CodingKeys: String, CodingKey {
        case shotID, previewImage, localizedNameKey, accessibilityLabel, preferredOrder, categories, id, subcategories, pointsOfInterest
        case url4KSDR240FPS = "url-4K-SDR-240FPS"
        case includeInShuffle, showInTopLevel, group
    }
}


enum LocalizationVersion: String, Codable {
    case the19J1 = "19J-1"
    case the19K1 = "19K-1"
    case the21J1 = "21J-1"
    case the22L1 = "22L-1"
}

// MARK: - SubcategoryElement
struct SubcategoryElement: Codable {
    let subcategories: [SubcategoryElement]?
    let localizedDescriptionKey, representativeAssetID: String
    let previewImage: String
    let id: String
    let preferredOrder: Int
    let localizedNameKey: String
}

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
    /// Apple's system wallpapers (macOS 27+: the "Mac" colour loops and
    /// the dynamic light/dark Golden Gate graphics) — not aerials, so
    /// they get their own group and can be left out of scene rotations.
    case wallpaper = "Wallpaper"
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

    /// The Sources root this source was found under (set at scan/install
    /// time). Runtime-only — deliberately excluded from Codable so a
    /// moved pack never carries a stale path in its manifest. Empty =
    /// the default root (`/Users/Shared/Aerial/Sources`).
    var rootPath: String = ""

    /// The on-disk folder holding this source's manifest.json,
    /// entries.json and (for non-cacheable packs) its videos.
    var folderPath: String {
        (rootPath.isEmpty ? Cache.defaultSourcesRoot : rootPath) + "/" + name
    }

    /// A downloadable Expansion pack: a non-cacheable network source whose
    /// videos live in its own folder. Excludes the local "My Videos"
    /// source, live sources, and the synthesized "Live Feeds" source (it
    /// parses as non-cacheable but is default-root managed). The one
    /// definition behind `Cache.packsSize()` and the Settings move sheet.
    var isExpansionPack: Bool {
        !isCachable && type != .local && type != .live && name != "Live Feeds"
    }

    enum CodingKeys: String, CodingKey {
        case name, description, manifestUrl, type, scenes, isCachable, license, more
    }


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
        return fileManager.fileExists(atPath: folderPath + "/entries.json")
    }

    /// For tar-published feeds (Apple's `resources-NN.tar`): the tar is
    /// left in the source folder after extraction, so its presence says
    /// which feed version is installed. `nil` for every other source.
    var feedMarkerPath: String? {
        guard let url = URL(string: manifestUrl), url.pathExtension == "tar" else { return nil }
        return folderPath + "/" + url.lastPathComponent
    }

    /// A cached tar source whose installed feed isn't the one this build
    /// points at — e.g. the macOS 26 feed seeded into the `macOS` folder
    /// while the build now wants `resources-27-0-1.tar`. Bypasses the
    /// weekly refresh window so the upgrade happens at the first launch,
    /// and self-heals an aborted staged install (only a successful one
    /// leaves the new tar behind, see `FileHelpers.installFeedArchive`).
    func needsFeedUpgrade() -> Bool {
        guard isCached(), let marker = feedMarkerPath else { return false }
        return !FileManager.default.fileExists(atPath: marker)
    }

    // Read local entries.json and return the video assets as an array
    // This is used to update in place the entries.json at startup when updating local sources
    func getUnprocessedAssets() -> [VideoAsset] {
        if isCached() {
            do {
                let cacheFileUrl = URL(fileURLWithPath: folderPath + "/entries.json")
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
                let cacheFileUrl = URL(fileURLWithPath: folderPath + "/entries.json")
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

    // `existing` is the caller's in-progress rebuild accumulator; assets whose
    // id already appears there are merged into the existing entry (sources /
    // missing-URL patching) instead of being returned again.
    func getVideos(dedupingAgainst existing: [AerialVideo]) -> [AerialVideo] {
        if isCached() {
            do {
                let cacheFileUrl = URL(fileURLWithPath: folderPath + "/entries.json")
                let jsondata = try Data(contentsOf: cacheFileUrl)

                if name.starts(with: "tvOS 13") {
                    return parseVideoManifest(jsondata, dedupingAgainst: existing)
                } else if name.starts(with: "macOS") {
                    return parseMacManifest(jsondata, dedupingAgainst: existing)
                } else {
                    return parseVideoManifest(jsondata, dedupingAgainst: existing)
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

    // MARK: - Apple category → location / scene
    //
    // Apple's macOS manifest files every asset under a top-level category
    // (Landscapes / Cities / Underwater / Space, and since macOS 27
    // Dynamic Wallpapers / Mac) and a subcategory (the place). The
    // subcategory has always been our "By Location" name; the category
    // was decoded and ignored. It is the only reliable marker for the
    // system wallpapers (`includeInShuffle` isn't — 39 real aerials carry
    // `false`), and it lines up with our scenes almost 1:1, so it now
    // backs both the location name and the scene fallback below.

    /// Apple's top-level category name keys. Stable across feed versions
    /// and language-independent (the category ids are UUIDs except for
    /// `dynamic-aerials`, so keys are the safer handle).
    enum AppleCategoryKey {
        static let landscapes = "AerialCategoryLandscapes"
        static let cities = "AerialCategoryCities"
        static let underwater = "AerialCategoryUnderwater"
        static let space = "AerialCategorySpace"
        static let dynamic = "AerialCategoryDynamic"
        static let mac = "AerialCategoryMac"
    }

    /// The top-level category listing `asset` (`categories.first`).
    func appleCategory(for asset: MacAsset, manifest: MacManifest) -> SubcategoryElement? {
        guard let id = asset.categories?.first else { return nil }
        return manifest.categories.first { $0.id == id }
    }

    /// The subcategory (place) listing `asset` (`subcategories.first`).
    func appleSubcategory(for asset: MacAsset, manifest: MacManifest) -> SubcategoryElement? {
        guard let id = asset.subcategories?.first else { return nil }
        for category in manifest.categories {
            if let match = category.subcategories?.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }

    /// Scene implied by Apple's top-level category. Nil for Landscapes and
    /// anything unknown (the caller's default is nature). A light/dark
    /// variant is a system wallpaper whatever category it is filed under.
    static func appleScene(forCategoryKey categoryKey: String?, variant: MacAssetVariant?) -> SourceScene? {
        if variant != nil { return .wallpaper }
        switch categoryKey ?? "" {
        case AppleCategoryKey.cities: return .city
        case AppleCategoryKey.underwater: return .sea
        case AppleCategoryKey.space: return .space
        case AppleCategoryKey.dynamic, AppleCategoryKey.mac: return .wallpaper
        default: return nil
        }
    }

    /// "By Location" name for a macOS asset. Space and Underwater collapse
    /// onto the literal "Space" / "Sea" — the names `AerialVideo.init` has
    /// always given the id-listed ones, and what users' persisted
    /// `location:` filters contain — so a newly published space video
    /// lands with the others instead of under its own place. Dynamic
    /// wallpapers take the category name ("Dynamic Wallpapers"): their
    /// subcategory localises to plain "Golden Gate", which would mix them
    /// with the real Golden Gate aerials. Everything else keeps the
    /// subcategory, as before.
    static func appleLocationName(categoryKey: String?, subcategoryKey: String?,
                                  accessibilityLabel: String?, localize: (String) -> String) -> String {
        switch categoryKey ?? "" {
        case AppleCategoryKey.space: return "Space"
        case AppleCategoryKey.underwater: return "Sea"
        case AppleCategoryKey.dynamic: return localize(AppleCategoryKey.dynamic)
        default: break
        }
        if let key = subcategoryKey { return localize(key) }
        if let key = categoryKey { return localize(key) }
        if let label = accessibilityLabel, !label.isEmpty { return label }
        return "Unknown"
    }

    func locationName(for asset: MacAsset, manifest: MacManifest) -> String {
        Source.appleLocationName(categoryKey: appleCategory(for: asset, manifest: manifest)?.localizedNameKey,
                                 subcategoryKey: appleSubcategory(for: asset, manifest: manifest)?.localizedNameKey,
                                 accessibilityLabel: asset.accessibilityLabel,
                                 localize: { PoiStringProvider.sharedInstance.getLocalizedNameKey(key: $0) })
    }

    func getSecondaryNameFor(_ asset: VideoAsset) -> String {
        return asset.title ?? "Unknown"
    }

    func getSecondaryNameFor(_ asset: MacAsset) -> String {
        let base: String
        if let key = asset.localizedNameKey {
            base = PoiStringProvider.sharedInstance.getLocalizedNameKey(key: key)
        } else {
            base = asset.accessibilityLabel ?? asset.shotID ?? asset.id
        }
        return Source.disambiguatedName(base, variant: asset.variant)
    }

    /// macOS 27's dynamic wallpapers publish a landscape AND a portrait
    /// asset under the same name key ("Light" / "Dark"); suffix the
    /// portrait one so the library doesn't list two identical rows.
    static func disambiguatedName(_ base: String, variant: MacAssetVariant?) -> String {
        guard let variant = variant, variant.isPortrait else { return base }
        return base + " (Portrait)"
    }

    
    func getSceneFor(_ asset: VideoAsset) -> String {
        if let updatedScene = SourceInfo.getSceneForVideo(id: asset.id) {
            return updatedScene.rawValue.lowercased()
        } else {
            return asset.scene ?? "landscape"
        }
    }

    /// Priority: the hand-curated `SourceInfo` lists (they carry deliberate
    /// beach / countryside calls the category can't make), then Apple's
    /// category, then landscape (→ nature).
    func getSceneFor(_ asset: MacAsset, manifest: MacManifest) -> String {
        if let updatedScene = SourceInfo.getSceneForVideo(id: asset.id) {
            return updatedScene.rawValue.lowercased()
        }
        let categoryKey = appleCategory(for: asset, manifest: manifest)?.localizedNameKey
        if let scene = Source.appleScene(forCategoryKey: categoryKey, variant: asset.variant) {
            return scene.rawValue.lowercased()
        }
        return "landscape"
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
                    source: self,
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

    func parseVideoManifest(_ data: Data, dedupingAgainst existing: [AerialVideo]) -> [AerialVideo] {
        if let videoManifest = try? newJSONDecoder().decode(VideoManifest.self, from: data) {
            var processedVideos: [AerialVideo] = []

            for asset in videoManifest.assets {
                let (isDupe, foundVideo) = SourceInfo.findDuplicate(id: asset.id, url1080pH264: asset.url1080H264 ?? "", in: existing)

                if !isDupe {
                    let video = AerialVideo(id: asset.id,
                        name: asset.accessibilityLabel,
                        secondaryName: getSecondaryNameFor(asset),
                        type: "video",
                        timeOfDay: asset.timeOfDay ?? "day",
                        scene: getSceneFor(asset),
                        urls: urlsFor(asset),
                        source: self,
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
    
    func parseMacManifest(_ data: Data, dedupingAgainst existing: [AerialVideo]) -> [AerialVideo] {
        if let videoManifest = try? newJSONDecoder().decode(MacManifest.self, from: data) {
            var processedVideos: [AerialVideo] = []

            for asset in videoManifest.assets {
                let (isDupe, _) = SourceInfo.findDuplicate(id: asset.id, url1080pH264: "", in: existing)

                if !isDupe {
                    // Dynamic-wallpaper variants (macOS 27+) know their own
                    // appearance and orientation; aerials carry neither and
                    // keep the historical "day" default (SourceInfo and the
                    // user override still win inside AerialVideo.init).
                    let variant = asset.variant
                    let video = AerialVideo(id: asset.id,
                        name: locationName(for: asset, manifest: videoManifest),
                        secondaryName: getSecondaryNameFor(asset),
                        type: "video",
                        timeOfDay: variant?.impliedTimeOfDay ?? "day",
                        scene: getSceneFor(asset, manifest: videoManifest),
                        urls: urlsFor(asset),
                        source: self,
                        poi: asset.pointsOfInterest ?? [:],
                        previewImage: asset.previewImage.nilIfEmpty,
                        isVerticalHint: variant?.isPortrait ?? false)

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
/// Apple's macOS aerials manifest (`entries.json` inside `resources-NN.tar`).
/// Everything a newer feed might drop or rename is optional, and the old
/// closed `LocalizationVersion` enum is gone on purpose: `parseMacManifest`
/// is a single `try? decode` of the WHOLE file, so one unknown raw value
/// (a `23L-1` next autumn) would silently zero the Apple catalog — and the
/// cache reaper's keep-set with it. Only `id` and the 240 fps URL are
/// required; a name key is expected but has a fallback.
struct MacManifest: Codable {
    let localizationVersion: String?
    let categories: [SubcategoryElement]
    let initialAssetCount: Int?
    let assets: [MacAsset]
    let version: Int?
}

/// macOS 27+: the same dynamic-wallpaper graphic published as light/dark
/// × landscape/portrait assets that share one `localizedNameKey`. Absent
/// on every aerial.
struct MacAssetVariant: Codable, Equatable {
    let appearance: String?    // "light" | "dark"
    let orientation: String?   // "landscape" | "portrait"

    var isPortrait: Bool { orientation?.lowercased() == "portrait" }
    var isDark: Bool { appearance?.lowercased() == "dark" }
    /// Dark variants are night wallpapers; everything else plays as day.
    var impliedTimeOfDay: String { isDark ? "night" : "day" }
}

// MARK: - Asset
struct MacAsset: Codable {
    let shotID: String?
    /// Apple's preview image URL for the asset. Optional / may be
    /// missing or empty in practice; `previewImage-900x580` (macOS 26
    /// only, always empty) is ignored entirely.
    let previewImage: String?
    let localizedNameKey: String?
    let accessibilityLabel: String?
    let preferredOrder: Int?
    let categories: [String]?
    let id: String
    let subcategories: [String]?
    let pointsOfInterest: [String: String]?
    let url4KSDR240FPS: String
    let includeInShuffle, showInTopLevel: Bool?
    let group: String?
    /// macOS 27+ dynamic wallpapers: light/dark × landscape/portrait.
    let variant: MacAssetVariant?
    /// macOS 27+: "resize" on the dynamic wallpapers (stretch-to-fill).
    /// Decoded for completeness; the renderer keeps aspect-fill.
    let videoGravity: String?

    enum CodingKeys: String, CodingKey {
        case shotID, previewImage, localizedNameKey, accessibilityLabel, preferredOrder, categories, id, subcategories, pointsOfInterest
        case url4KSDR240FPS = "url-4K-SDR-240FPS"
        case includeInShuffle, showInTopLevel, group, variant, videoGravity
    }
}

// MARK: - SubcategoryElement
struct SubcategoryElement: Codable {
    let subcategories: [SubcategoryElement]?
    let localizedDescriptionKey, representativeAssetID: String?
    let previewImage: String?
    let id: String
    let preferredOrder: Int?
    let localizedNameKey: String
}

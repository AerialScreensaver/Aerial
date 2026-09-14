//
//  AppleFeedDecodeTests.swift
//  AerialTests
//
//  Apple's macOS `entries.json` decoder must accept both the macOS 26
//  shape and the macOS 27 one (variants, new categories, no
//  `previewImage-900x580`, non-UUID category ids) — and must not fall
//  over on a future `localizationVersion`, because a decode failure
//  silently zeroes the Apple catalog.
//

import Foundation
import Testing
@testable import Aerial

@Suite("Apple feed decode")
struct AppleFeedDecodeTests {

    // Trimmed from resources-27-0-1.tar: one aerial with POIs, one Golden
    // Gate aerial, one Mac colour wallpaper, two dynamic variants.
    private static let feed27 = """
    {
      "assets": [
        {
          "accessibilityLabel": "Korea and Japan Night",
          "categories": ["55B7C95D-CEAF-4FD8-ADEF-F5BC657D8F6D"],
          "id": "009BA758-7060-4479-8EE8-FB9B40C8FB97",
          "includeInShuffle": true,
          "localizedNameKey": "GMT026_363A_103NC_E1027_KOREA_JAPAN_NIGHT_NAME",
          "pointsOfInterest": {"0": "GMT026_363A_103NC_E1027_0", "110": "GMT026_363A_103NC_E1027_110"},
          "preferredOrder": 9,
          "previewImage": "https://example.invalid/Space_Korea_Japan_01@2x.png",
          "shotID": "GMT026_363A_103NC_E1027_KOREA_JAPAN_NIGHT",
          "showInTopLevel": true,
          "subcategories": ["61171241-39F3-4ADE-84AA-9CD4EE4A78DA"],
          "url-4K-SDR-240FPS": "https://example.invalid/comp_GMT026_KOREA_JAPAN_NIGHT_240fps.mov"
        },
        {
          "accessibilityLabel": "Golden Gate Night",
          "categories": ["A33A55D9-EDEA-4596-A850-6C10B54FBBB5"],
          "id": "86E89C23-C39B-44C8-A985-E56EEA6456FE",
          "includeInShuffle": true,
          "localizedNameKey": "GG_A_NIGHT_NAME",
          "pointsOfInterest": {},
          "preferredOrder": 39,
          "previewImage": "https://example.invalid/GG_A_NIGHT_Golden_Gate_Night_v2.png",
          "shotID": "GG_A_NIGHT",
          "showInTopLevel": true,
          "subcategories": ["67512508-D33E-4CBC-8A9E-BE55CEE35C4C"],
          "url-4K-SDR-240FPS": "https://example.invalid/GG_A_NIGHT_BatterySpencer_HFR_12Mbps.mov"
        },
        {
          "accessibilityLabel": "Mac Blue",
          "categories": ["8048287A-39E6-4093-87EC-B0DCE7CB4A29"],
          "id": "94383DC9-59D3-43EC-9E8E-A783DA633E06",
          "includeInShuffle": false,
          "localizedNameKey": "MAC_WP_BLU_NAME",
          "pointsOfInterest": {},
          "preferredOrder": 81,
          "previewImage": "https://example.invalid/MacOS_WP_Blue_356x356_P3_Thumbnail.png",
          "shotID": "MAC_WP_BLU",
          "showInTopLevel": true,
          "subcategories": ["989909D1-AEFC-4BE5-9249-ABFBA5CABED0"],
          "url-4K-SDR-240FPS": "https://example.invalid/Blue_Comp_2x_Crop_v0041_240p_tsa.mov"
        },
        {
          "accessibilityLabel": "macOS",
          "categories": ["dynamic-aerials"],
          "id": "4DFE24ED-71CC-42D4-9FE8-3B8959B6CC19",
          "includeInShuffle": false,
          "localizedNameKey": "DYNAMIC_LIGHT_KEY",
          "pointsOfInterest": {},
          "preferredOrder": 0,
          "previewImage": "https://example.invalid/Canyon_v9_WallpaperGallery_LM.png",
          "shotID": "GG_LM_H",
          "showInTopLevel": true,
          "subcategories": ["17647EAB-8357-48B0-BCD6-B892194267C5"],
          "url-4K-SDR-240FPS": "https://example.invalid/GG_LM_H_v063_240fps-TSA.mov",
          "variant": {"appearance": "light", "orientation": "landscape"},
          "videoGravity": "resize"
        },
        {
          "accessibilityLabel": "macOS",
          "categories": ["dynamic-aerials"],
          "id": "731140AB-82EF-47B5-B62C-285BA7E112FD",
          "includeInShuffle": false,
          "localizedNameKey": "DYNAMIC_DARK_KEY",
          "pointsOfInterest": {},
          "preferredOrder": 0,
          "previewImage": "https://example.invalid/Canyon_v9_WallpaperGallery_DM.png",
          "shotID": "GG_DM_V",
          "showInTopLevel": true,
          "subcategories": ["17647EAB-8357-48B0-BCD6-B892194267C5"],
          "url-4K-SDR-240FPS": "https://example.invalid/GG_DM_V_v016_240fps-TSA.mov",
          "variant": {"appearance": "dark", "orientation": "portrait"},
          "videoGravity": "resize"
        }
      ],
      "categories": [
        {
          "id": "dynamic-aerials",
          "localizedDescriptionKey": "AerialCategoryDynamicDescription",
          "localizedNameKey": "AerialCategoryDynamic",
          "preferredOrder": 0,
          "previewImage": "https://example.invalid/Canyon_v9_WallpaperGallery.png",
          "representativeAssetID": "4DFE24ED-71CC-42D4-9FE8-3B8959B6CC19",
          "subcategories": [
            {
              "combineVariants": true,
              "id": "17647EAB-8357-48B0-BCD6-B892194267C5",
              "localizedDescriptionKey": "AerialSubcategoryDescriptionGoldenGateGraphical",
              "localizedNameKey": "AerialSubcategoryDescriptionGoldenGateGraphical",
              "preferredOrder": -500,
              "previewImage": "https://example.invalid/Canyon_v9_WallpaperGallery.png",
              "representativeAssetID": "4DFE24ED-71CC-42D4-9FE8-3B8959B6CC19"
            }
          ]
        },
        {
          "id": "A33A55D9-EDEA-4596-A850-6C10B54FBBB5",
          "localizedDescriptionKey": "AerialCategoryLandscapesDescription",
          "localizedNameKey": "AerialCategoryLandscapes",
          "preferredOrder": 1,
          "previewImage": "https://example.invalid/landscapes.png",
          "representativeAssetID": "EE01F02D-1413-436C-AB05-410F224A5B7B",
          "subcategories": [
            {
              "id": "67512508-D33E-4CBC-8A9E-BE55CEE35C4C",
              "localizedDescriptionKey": "AerialSubcategoryDescriptionGoldenGate",
              "localizedNameKey": "AerialSubcategoryGoldenGate",
              "preferredOrder": 0,
              "previewImage": "https://example.invalid/gg.png",
              "representativeAssetID": "6511D2B5-E185-4886-9505-B4004E920D27"
            }
          ]
        },
        {
          "id": "8048287A-39E6-4093-87EC-B0DCE7CB4A29",
          "localizedDescriptionKey": "AerialCategoryMacDescription",
          "localizedNameKey": "AerialCategoryMac",
          "preferredOrder": 5,
          "previewImage": "https://example.invalid/mac.png",
          "representativeAssetID": "94383DC9-59D3-43EC-9E8E-A783DA633E06",
          "subcategories": [
            {
              "id": "989909D1-AEFC-4BE5-9249-ABFBA5CABED0",
              "localizedDescriptionKey": "AerialSubcategoryDescriptionMac",
              "localizedNameKey": "AerialSubcategoryDescriptionMac",
              "preferredOrder": 0,
              "previewImage": "https://example.invalid/mac-sub.png",
              "representativeAssetID": "94383DC9-59D3-43EC-9E8E-A783DA633E06"
            }
          ]
        }
      ],
      "initialAssetCount": 4,
      "localizationVersion": "22L-1",
      "version": 1
    }
    """

    // Trimmed from resources-26-0-1.tar: `previewImage-900x580`, `group`,
    // no variant, the historical field set.
    private static let feed26 = """
    {
      "version": 1,
      "localizationVersion": "22L-1",
      "initialAssetCount": 4,
      "categories": [
        {
          "id": "A33A55D9-EDEA-4596-A850-6C10B54FBBB5",
          "localizedDescriptionKey": "AerialCategoryLandscapesDescription",
          "localizedNameKey": "AerialCategoryLandscapes",
          "preferredOrder": 0,
          "previewImage": "https://example.invalid/landscapes.png",
          "representativeAssetID": "EE01F02D-1413-436C-AB05-410F224A5B7B",
          "subcategories": [
            {
              "id": "0DC99DD8-3386-4D1E-8878-C43E97EB710A",
              "localizedDescriptionKey": "AerialSubcategoryTahoeDescription",
              "localizedNameKey": "AerialSubcategoryTahoe",
              "preferredOrder": -1,
              "previewImage": "https://example.invalid/tahoe.png",
              "representativeAssetID": "4C108785-A7BA-422E-9C79-B0129F1D5550"
            }
          ]
        }
      ],
      "assets": [
        {
          "previewImage-900x580": "",
          "url-4K-SDR-240FPS": "https://example.invalid/TA_L_002_240fps.mov",
          "accessibilityLabel": "Tahoe Day",
          "includeInShuffle": true,
          "localizedNameKey": "TA_L_002_NAME",
          "preferredOrder": 0,
          "shotID": "TA_L_002",
          "pointsOfInterest": {"0": "TA_L_002_0"},
          "previewImage": "https://example.invalid/tahoe-day.png",
          "showInTopLevel": true,
          "subcategories": ["0DC99DD8-3386-4D1E-8878-C43E97EB710A"],
          "categories": ["A33A55D9-EDEA-4596-A850-6C10B54FBBB6"],
          "id": "4C108785-A7BA-422E-9C79-B0129F1D5550",
          "group": "21J-1"
        }
      ]
    }
    """

    private func decode(_ json: String) throws -> MacManifest {
        try JSONDecoder().decode(MacManifest.self, from: Data(json.utf8))
    }

    @Test("macOS 27 shape decodes with variants, new categories and gravity")
    func decodes27() throws {
        let manifest = try decode(Self.feed27)
        #expect(manifest.assets.count == 5)
        #expect(manifest.categories.count == 3)
        #expect(manifest.categories.first?.id == "dynamic-aerials")
        #expect(manifest.localizationVersion == "22L-1")

        let landscapeLight = try #require(manifest.assets.first { $0.shotID == "GG_LM_H" })
        #expect(landscapeLight.variant == MacAssetVariant(appearance: "light", orientation: "landscape"))
        #expect(landscapeLight.variant?.isPortrait == false)
        #expect(landscapeLight.variant?.isDark == false)
        #expect(landscapeLight.variant?.impliedTimeOfDay == "day")
        #expect(landscapeLight.videoGravity == "resize")

        let portraitDark = try #require(manifest.assets.first { $0.shotID == "GG_DM_V" })
        #expect(portraitDark.variant?.isPortrait == true)
        #expect(portraitDark.variant?.impliedTimeOfDay == "night")

        let aerial = try #require(manifest.assets.first { $0.shotID == "GG_A_NIGHT" })
        #expect(aerial.variant == nil)
        #expect(aerial.videoGravity == nil)
        #expect(aerial.group == nil)
    }

    @Test("macOS 26 shape still decodes (group, previewImage-900x580)")
    func decodes26() throws {
        let manifest = try decode(Self.feed26)
        #expect(manifest.assets.count == 1)
        #expect(manifest.assets.first?.group == "21J-1")
        #expect(manifest.assets.first?.variant == nil)
        #expect(manifest.assets.first?.pointsOfInterest?["0"] == "TA_L_002_0")
    }

    @Test("an unknown localizationVersion / group must not fail the whole manifest")
    func toleratesFutureVersions() throws {
        let json = Self.feed26
            .replacingOccurrences(of: "\"22L-1\"", with: "\"23L-1\"")
            .replacingOccurrences(of: "\"21J-1\"", with: "\"99Z-9\"")
        let manifest = try decode(json)
        #expect(manifest.localizationVersion == "23L-1")
        #expect(manifest.assets.first?.group == "99Z-9")
    }

    @Test("only id and the 240 fps URL are required on an asset")
    func minimalAsset() throws {
        let json = """
        {"assets": [{"id": "X", "url-4K-SDR-240FPS": "https://example.invalid/x.mov"}], "categories": []}
        """
        let manifest = try decode(json)
        #expect(manifest.assets.first?.id == "X")
        #expect(manifest.assets.first?.localizedNameKey == nil)
        #expect(manifest.version == nil)
    }

    @Test("portrait variants get a disambiguated display name")
    func disambiguatedNames() {
        let portrait = MacAssetVariant(appearance: "light", orientation: "portrait")
        let landscape = MacAssetVariant(appearance: "light", orientation: "landscape")
        #expect(Source.disambiguatedName("Light", variant: portrait) == "Light (Portrait)")
        #expect(Source.disambiguatedName("Light", variant: landscape) == "Light")
        #expect(Source.disambiguatedName("Golden Gate Night", variant: nil) == "Golden Gate Night")
    }

    @Test("feed sanity check accepts both Apple shapes and rejects junk")
    func entriesSanity() {
        #expect(FileHelpers.feedEntriesLookValid(Data(Self.feed27.utf8)))
        #expect(FileHelpers.feedEntriesLookValid(Data(Self.feed26.utf8)))
        // tvOS / community shape
        let tv = """
        {"assets": [{"accessibilityLabel": "Hawaii", "id": "b1-1", "url-1080-H264": "https://example.invalid/h.mov"}]}
        """
        #expect(FileHelpers.feedEntriesLookValid(Data(tv.utf8)))
        #expect(!FileHelpers.feedEntriesLookValid(Data("{\"assets\": [], \"categories\": []}".utf8)))
        #expect(!FileHelpers.feedEntriesLookValid(Data("<html>404</html>".utf8)))
        #expect(!FileHelpers.feedEntriesLookValid(Data()))
    }

    @Test("Apple top-level category → scene; a variant is a wallpaper regardless")
    func categoryScene() {
        #expect(Source.appleScene(forCategoryKey: "AerialCategoryCities", variant: nil) == .city)
        #expect(Source.appleScene(forCategoryKey: "AerialCategoryUnderwater", variant: nil) == .sea)
        #expect(Source.appleScene(forCategoryKey: "AerialCategorySpace", variant: nil) == .space)
        #expect(Source.appleScene(forCategoryKey: "AerialCategoryDynamic", variant: nil) == .wallpaper)
        #expect(Source.appleScene(forCategoryKey: "AerialCategoryMac", variant: nil) == .wallpaper)
        #expect(Source.appleScene(forCategoryKey: "AerialCategoryLandscapes", variant: nil) == nil)
        #expect(Source.appleScene(forCategoryKey: "AerialCategoryFuture", variant: nil) == nil)
        #expect(Source.appleScene(forCategoryKey: nil, variant: nil) == nil)
        let variant = MacAssetVariant(appearance: "light", orientation: "landscape")
        #expect(Source.appleScene(forCategoryKey: "AerialCategoryLandscapes", variant: variant) == .wallpaper)
    }

    @Test("location name: Space/Sea literals, category name for dynamic wallpapers, subcategory otherwise")
    func locationNames() {
        let localize: (String) -> String = { "L(\($0))" }
        func name(_ category: String?, _ subcategory: String?, _ label: String? = nil) -> String {
            Source.appleLocationName(categoryKey: category, subcategoryKey: subcategory,
                                     accessibilityLabel: label, localize: localize)
        }
        #expect(name("AerialCategorySpace", "AerialSubcategoryChina") == "Space")
        #expect(name("AerialCategoryUnderwater", "AerialSubcategoryPalauJellies") == "Sea")
        #expect(name("AerialCategoryDynamic", "AerialSubcategoryDescriptionGoldenGateGraphical") == "L(AerialCategoryDynamic)")
        #expect(name("AerialCategoryMac", "AerialSubcategoryDescriptionMac") == "L(AerialSubcategoryDescriptionMac)")
        #expect(name("AerialCategoryLandscapes", "AerialSubcategoryGoldenGate") == "L(AerialSubcategoryGoldenGate)")
        #expect(name("AerialCategoryCities", "AerialSubcategoryCitiesNewYork") == "L(AerialSubcategoryCitiesNewYork)")
        #expect(name("AerialCategoryLandscapes", nil) == "L(AerialCategoryLandscapes)")
        #expect(name(nil, nil, "Tahoe Day") == "Tahoe Day")
        #expect(name(nil, nil, "") == "Unknown")
    }

    @Test("category / subcategory / scene resolve through the decoded manifest")
    func manifestLookups() throws {
        let manifest = try decode(Self.feed27)
        let source = Source(name: "macOS", description: "", manifestUrl: "https://example.invalid/r.tar",
                            type: .macOS, scenes: [.nature], isCachable: true, license: "", more: "")

        let portraitDark = try #require(manifest.assets.first { $0.shotID == "GG_DM_V" })
        #expect(source.appleCategory(for: portraitDark, manifest: manifest)?.localizedNameKey == "AerialCategoryDynamic")
        #expect(source.appleSubcategory(for: portraitDark, manifest: manifest)?.localizedNameKey
                == "AerialSubcategoryDescriptionGoldenGateGraphical")
        #expect(source.getSceneFor(portraitDark, manifest: manifest) == "wallpaper")

        let macBlue = try #require(manifest.assets.first { $0.shotID == "MAC_WP_BLU" })
        #expect(source.getSceneFor(macBlue, manifest: manifest) == "wallpaper")

        let goldenGate = try #require(manifest.assets.first { $0.shotID == "GG_A_NIGHT" })
        #expect(source.getSceneFor(goldenGate, manifest: manifest) == "landscape")

        let koreaJapan = try #require(manifest.assets.first { $0.id == "009BA758-7060-4479-8EE8-FB9B40C8FB97" })
        #expect(source.getSceneFor(koreaJapan, manifest: manifest) == "space")

        // Unknown ids resolve to nil, not a crash
        let orphan = MacAsset(shotID: nil, previewImage: nil, localizedNameKey: nil, accessibilityLabel: "X",
                              preferredOrder: nil, categories: ["nope"], id: "X", subcategories: ["nope"],
                              pointsOfInterest: nil, url4KSDR240FPS: "https://example.invalid/x.mov",
                              includeInShuffle: nil, showInTopLevel: nil, group: nil, variant: nil, videoGravity: nil)
        #expect(source.appleCategory(for: orphan, manifest: manifest) == nil)
        #expect(source.appleSubcategory(for: orphan, manifest: manifest) == nil)
        #expect(source.getSceneFor(orphan, manifest: manifest) == "landscape")
    }

    @Test("manifest.json scene strings parse case-insensitively, including wallpaper")
    func jsonScenes() {
        #expect(SourceList.jsonToSceneArray(array: ["wallpaper", "City", "nature", "bogus", "SEA"])
                == [.wallpaper, .city, .nature, .nature, .sea])
    }
}

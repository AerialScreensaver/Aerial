//
//  CodableShimsABITests.swift
//  AerialTests
//
//  The wallpaper extension's settings UI depends on CodableShims
//  producing byte-compatible archives with Apple's private
//  WallpaperTypes structs (we archive a ShimViewModelsXPC and remap the
//  class name to WallpaperSettingsViewModelsXPC on unarchive — see
//  SettingsProvider.remapToRealXPC). Apple's side can't be imported, so
//  this suite replays the exact runtime remap against the live private
//  framework: a failure here after a macOS update means the ABI moved
//  and the shims must be re-matched BEFORE users hit garbage settings.
//

import Testing
import Foundation
@testable import Aerial

@Suite("CodableShims ABI")
struct CodableShimsABITests {

    /// Representative payload exercising every custom-Codable shape:
    /// all Disposability + ContentBadge cases, both Thumbnail cases,
    /// CustomButton, ContextMenu, populated and nil optionals.
    private func makeFixture() -> SettingsViewModels {
        let provider = ChoiceProviderID(rawValue: "com.glouel.Aerial-App.test")
        let choiceID = ChoiceID(id: "aerial-test", descriptor: ChoiceIDDescriptor(
            provider: provider,
            identifier: "aerial-test",
            files: [URL(fileURLWithPath: "/Users/Shared/Aerial/test.mov")],
            configuration: Data([0x01, 0x02])
        ))

        let richItem = SettingsItem(
            id: choiceID,
            localizedName: "Aerial",
            thumbnail: .image(url: URL(fileURLWithPath: "/tmp/thumb.png")),
            choice: ChoiceDescriptor(
                id: choiceID,
                provider: provider,
                identifier: "aerial-test",
                name: "Aerial",
                localizedDescription: "Test choice",
                thumbnail: .customButton(.addColorButton),
                isDownloaded: true,
                // Always empty in production — Apple decodes elements as
                // WallpaperOptionEnum, which the shim can't produce (see
                // the knownGap test below).
                options: []
            ),
            contentBadge: .video,
            showInTopLevel: true,
            sortOrder: 1,
            disposability: .removable
        )
        let richGroup = SettingsGroup(
            id: GroupID(id: "aerial-group"),
            items: [richItem],
            localizedName: "Aerial",
            disposability: .none,
            sortOrder: 0,
            sortID: GroupSortID(id: "sort-0"),
            allChoiceID: choiceID,
            shouldHideItemLabels: false,
            contextMenu: ContextMenu(items: [ContextMenuItem(identifier: "cm1", name: "Refresh")]),
            thumbnail: Data([0xAA, 0xBB])
        )

        // Second group: the remaining enum cases + nil optionals.
        let sparseItem = SettingsItem(
            id: choiceID,
            localizedName: "Sparse",
            thumbnail: .customButton(.shuffleColorsButton),
            choice: ChoiceDescriptor(
                id: choiceID,
                provider: provider,
                identifier: "sparse",
                name: nil,
                localizedDescription: "",
                thumbnail: .image(url: URL(fileURLWithPath: "/")),
                isDownloaded: false,
                options: []
            ),
            contentBadge: .dynamic,
            showInTopLevel: false,
            sortOrder: 2,
            disposability: .purgeable
        )
        let sparseGroup = SettingsGroup(
            id: GroupID(id: "sparse-group"),
            items: [sparseItem],
            localizedName: "Sparse",
            disposability: .purgeable,
            sortOrder: 1,
            // Required by Apple's decoder — see the shim's doc comment.
            sortID: GroupSortID(id: "sort-sparse"),
            allChoiceID: nil,
            // Required by Apple's decoder — see the shim's doc comment.
            shouldHideItemLabels: true,
            contextMenu: nil,
            thumbnail: nil
        )

        return SettingsViewModels(
            desktop: SettingsViewModel(groups: [richGroup], refreshPolicy: .default, isModificationDisabled: false),
            screenSaver: SettingsViewModel(groups: [sparseGroup], refreshPolicy: .default, isModificationDisabled: true)
        )
    }

    /// Replays `SettingsProvider.remapToRealXPC`: archive the shim,
    /// remap the class name, let Apple's `init(coder:)` decode it.
    private func remapThroughRealClass(_ viewModels: SettingsViewModels) throws -> (result: Any?, error: Error?) {
        // A failure on either requirement IS the signal — the
        // extension's settings path would be equally broken.
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit",
            RTLD_LAZY
        )
        try #require(handle != nil, "WallpaperExtensionKit failed to dlopen")
        let realClass = try #require(
            objc_getClass("WallpaperSettingsViewModelsXPC") as? AnyClass,
            "WallpaperSettingsViewModelsXPC no longer exists — Apple renamed/moved it"
        )

        let shim = ShimViewModelsXPC(value: viewModels)
        let data = try NSKeyedArchiver.archivedData(withRootObject: shim, requiringSecureCoding: false)

        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        unarchiver.setClass(realClass, forClassName: "ShimViewModelsXPC")
        let result = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        let error = unarchiver.error
        unarchiver.finishDecoding()
        return (result, error)
    }

    @Test("Apple's WallpaperSettingsViewModelsXPC decodes our shim archive")
    func realClassDecodesShimArchive() throws {
        let (result, error) = try remapThroughRealClass(makeFixture())
        #expect(error == nil,
                "Apple's init(coder:) rejected the shim payload: \(String(describing: error))")
        #expect(result != nil, "decode returned nil — encoding drift")
    }

    @Test("known gap: non-empty options is NOT decodable by Apple's side")
    func knownGapNonEmptyOptions() throws {
        // Apple decodes `options` elements as WallpaperOptionEnum (a
        // one-key enum container); the shim's empty WallpaperOption
        // can't produce that. Production always sends [], so this is a
        // documented boundary, not a bug — if this test ever starts
        // PASSING the decode, the shim (or Apple) changed and both this
        // pin and the WallpaperOption placeholder need re-evaluation.
        var fixture = makeFixture()
        fixture.desktop?.groups[0].items[0].choice.options = [WallpaperOption()]
        let (_, error) = try remapThroughRealClass(fixture)
        #expect(error != nil, "non-empty options unexpectedly decoded — shim gap closed?")
    }

    @Test("shim Codable payload round-trips through a keyed archive")
    func shimPayloadRoundTrip() throws {
        // Pins OUR encoder shapes (the empty-nested-container enum
        // encodings, singleValue ChoiceProviderID, nil-optional
        // omission) independently of Apple's framework.
        let fixture = makeFixture()

        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        try archiver.encodeEncodable(fixture, forKey: "WallpaperSettingsViewModels")
        archiver.finishEncoding()

        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = false
        let decoded = try #require(
            try unarchiver.decodeTopLevelDecodable(SettingsViewModels.self, forKey: "WallpaperSettingsViewModels")
        )
        unarchiver.finishDecoding()

        #expect(decoded == fixture)
    }
}

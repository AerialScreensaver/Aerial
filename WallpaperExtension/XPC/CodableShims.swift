// Codable shims matching WallpaperTypes encoding format.
//
// These structs produce the same NSKeyedArchiver encoding as the real WallpaperTypes structs.
// We archive a ShimViewModelsXPC, swap the class name to WallpaperSettingsViewModelsXPC
// on unarchive, and the real class's init(coder:) decodes it via Codable.
//
// ABI canary: CodableShimsABITests replays this exact remap against the
// live private framework — if it fails after a macOS update, Apple's
// WallpaperTypes encoding moved and these shims must be re-matched.

import Foundation

struct SettingsViewModels: Codable, Equatable {
    var desktop: SettingsViewModel?
    var screenSaver: SettingsViewModel?
}

struct SettingsViewModel: Codable, Equatable {
    var groups: [SettingsGroup]
    var refreshPolicy: RefreshPolicy
    var isModificationDisabled: Bool
}

struct SettingsGroup: Codable, Equatable {
    var id: GroupID
    var items: [SettingsItem]
    var localizedName: String
    var disposability: Disposability
    var sortOrder: Int
    /// REQUIRED by Apple's decoder (plain `decode`, not
    /// `decodeIfPresent` — the ABI canary proved a nil is rejected with
    /// keyNotFound). Non-optional here so it can't be omitted at
    /// compile time.
    var sortID: GroupSortID
    var allChoiceID: ChoiceID?
    /// REQUIRED by Apple's decoder, like `sortID` (canary-proven).
    var shouldHideItemLabels: Bool
    var contextMenu: ContextMenu?
    var thumbnail: Data?
}

/// Real type: WallpaperTypes.WallpaperDisposability — cases: none, removable, purgeable
enum Disposability: Codable, Equatable {
    case none
    case removable
    case purgeable

    private enum CodingKeys: String, CodingKey {
        case none
        case removable
        case purgeable
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .none)
        case .removable:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .removable)
        case .purgeable:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .purgeable)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.none) { self = .none }
        else if container.contains(.removable) { self = .removable }
        else if container.contains(.purgeable) { self = .purgeable }
        else { self = .none }
    }
}

struct GroupID: Codable, Equatable {
    var id: String
}

struct GroupSortID: Codable, Equatable {
    var id: String
}

struct ChoiceID: Codable, Equatable {
    var id: String
    var descriptor: ChoiceIDDescriptor
}

struct ChoiceIDDescriptor: Codable, Equatable {
    var provider: ChoiceProviderID
    var identifier: String
    var files: [URL]
    var configuration: Data
}

struct SettingsItem: Codable, Equatable {
    var id: ChoiceID
    var localizedName: String
    var thumbnail: Thumbnail
    var choice: ChoiceDescriptor
    var contentBadge: ContentBadge
    var showInTopLevel: Bool
    var sortOrder: Int
    var disposability: Disposability
}

/// WallpaperSettingsItem.ContentBadge — cases: none, video, dynamic
enum ContentBadge: Codable, Equatable {
    case none
    case video
    case dynamic

    private enum CodingKeys: String, CodingKey {
        case none
        case video
        case dynamic
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .none)
        case .video:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .video)
        case .dynamic:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .dynamic)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.none) { self = .none }
        else if container.contains(.video) { self = .video }
        else if container.contains(.dynamic) { self = .dynamic }
        else { self = .none }
    }
}

/// WallpaperThumbnail — only `.image(url:)` is needed for our use.
enum Thumbnail: Codable, Equatable {
    case image(url: URL)
    case customButton(CustomButton)

    private enum CodingKeys: String, CodingKey {
        case image
        case customButton
    }

    private enum ImageCodingKeys: String, CodingKey {
        case url
    }

    private enum CustomButtonCodingKeys: String, CodingKey {
        case _0
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .image(url):
            var nested = container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .image)
            try nested.encode(url, forKey: .url)
        case let .customButton(button):
            var nested = container.nestedContainer(keyedBy: CustomButtonCodingKeys.self, forKey: .customButton)
            try nested.encode(button, forKey: ._0)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.image) {
            let nested = try container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .image)
            let url = try nested.decode(URL.self, forKey: .url)
            self = .image(url: url)
        } else if container.contains(.customButton) {
            let nested = try container.nestedContainer(keyedBy: CustomButtonCodingKeys.self, forKey: .customButton)
            let button = try nested.decode(CustomButton.self, forKey: ._0)
            self = .customButton(button)
        } else {
            self = .image(url: URL(fileURLWithPath: "/"))
        }
    }
}

enum CustomButton: Codable, Equatable {
    case addPhotoButton
    case addColorButton
    case shuffleColorsButton

    private enum CodingKeys: String, CodingKey {
        case addPhotoButton
        case addColorButton
        case shuffleColorsButton
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addPhotoButton:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .addPhotoButton)
        case .addColorButton:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .addColorButton)
        case .shuffleColorsButton:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .shuffleColorsButton)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.addPhotoButton) { self = .addPhotoButton }
        else if container.contains(.addColorButton) { self = .addColorButton }
        else if container.contains(.shuffleColorsButton) { self = .shuffleColorsButton }
        else { self = .addPhotoButton }
    }
}

struct ChoiceDescriptor: Codable, Equatable {
    var id: ChoiceID
    var provider: ChoiceProviderID
    var identifier: String
    var name: String?
    var localizedDescription: String
    var thumbnail: Thumbnail
    var isDownloaded: Bool
    var options: [WallpaperOption]
}

/// PLACEHOLDER — never populate. Apple decodes `options` as
/// `[WallpaperOptionEnum]` (a one-key enum container per element), and
/// this empty struct encodes as `{}`, which the real decoder rejects
/// ("Invalid number of keys found, expected one"). Production always
/// sends `options: []`, which decodes fine; the ABI canary test pins
/// both facts (CodableShimsABITests).
struct WallpaperOption: Codable, Equatable {}

struct ChoiceProviderID: Codable, Equatable {
    var rawValue: String

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }
}

enum RefreshPolicy: Codable, Equatable {
    case `default`

    private enum CodingKeys: String, CodingKey {
        case `default`
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .default:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .default)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.default) {
            self = .default
        } else {
            self = .default
        }
    }
}

struct ContextMenu: Codable, Equatable {
    var items: [ContextMenuItem]
}

struct ContextMenuItem: Codable, Equatable {
    var identifier: String
    var name: String
}

enum EmptyCodingKeys: CodingKey {}

/// NSObject wrapper that encodes SettingsViewModels using the same key as the real XPC type.
/// We archive it, then swap the class name to WallpaperSettingsViewModelsXPC on unarchive.
@objc(ShimViewModelsXPC)
class ShimViewModelsXPC: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    let value: SettingsViewModels

    init(value: SettingsViewModels) {
        self.value = value
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("decode not needed")
    }

    func encode(with coder: NSCoder) {
        guard let archiver = coder as? NSKeyedArchiver else {
            debugLog("  [ShimXPC] encode error: coder is not NSKeyedArchiver")
            return
        }
        do {
            try archiver.encodeEncodable(value, forKey: "WallpaperSettingsViewModels")
        } catch {
            debugLog("  [ShimXPC] encode error: \(error)")
        }
    }
}

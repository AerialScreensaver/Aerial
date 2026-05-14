//
//  OverlayConfig.swift
//  Aerial
//
//  Core data model for the overlay editor system.
//  Supports multiple instances of the same overlay type,
//  organized as stacks in 7 positions, with per-screen
//  and separate desktop/screensaver configurations.
//

import Foundation

// MARK: - Position

enum OverlayPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft
    case topCenter
    case topRight
    case center
    case bottomLeft
    case bottomCenter
    case bottomRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topCenter: return "Top Center"
        case .topRight: return "Top Right"
        case .center: return "Center"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomRight: return "Bottom Right"
        }
    }
}

// MARK: - Rotation Mode

enum OverlayRotationMode: String, Codable, CaseIterable, Identifiable {
    case never
    case every10Seconds = "every10s"
    case every30Seconds = "every30s"
    case everyMinute = "every60s"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .never: return "Never"
        case .every10Seconds: return "Every 10 seconds"
        case .every30Seconds: return "Every 30 seconds"
        case .everyMinute: return "Every minute"
        }
    }

    /// Interval between rotations. `nil` when rotation is disabled.
    var interval: TimeInterval? {
        switch self {
        case .never: return nil
        case .every10Seconds: return 10
        case .every30Seconds: return 30
        case .everyMinute: return 60
        }
    }
}

// MARK: - Overlay Kind

enum OverlayKind: String, Codable, CaseIterable, Identifiable {
    case clock
    case date
    case location
    case weather
    case battery
    case verticalSpacer
    case message
    case countdown
    case timer
    case music

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clock: return "Clock"
        case .date: return "Date"
        case .location: return "Location"
        case .weather: return "Weather"
        case .battery: return "Battery"
        case .verticalSpacer: return "Vertical Spacer"
        case .message: return "Message"
        case .countdown: return "Countdown"
        case .timer: return "Timer"
        case .music: return "Music"
        }
    }

    var iconName: String {
        switch self {
        case .clock: return "clock"
        case .date: return "calendar"
        case .location: return "mappin.and.ellipse"
        case .weather: return "cloud.sun"
        case .battery: return "battery.100.bolt"
        case .verticalSpacer: return "arrow.up.and.down"
        case .message: return "text.bubble"
        case .countdown: return "hourglass"
        case .timer: return "timer"
        case .music: return "music.note"
        }
    }

    var description: String {
        switch self {
        case .clock: return "Local time"
        case .date: return "Today's date"
        case .location: return "Information about the video location"
        case .weather: return "Provided by OpenWeather"
        case .battery: return "Battery level and charging status"
        case .verticalSpacer: return "Blank vertical space"
        case .message: return "Custom text, file, or shell command"
        case .countdown: return "Count down to a specific date"
        case .timer: return "Count down from a set duration"
        case .music: return "Now playing from Apple Music"
        }
    }
}

// MARK: - AnyCodableValue

/// Codable wrapper for heterogeneous JSON values in typeSettings
enum AnyCodableValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    var asString: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var asInt: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    var asDouble: Double? {
        if case .double(let v) = self { return v }
        if case .int(let v) = self { return Double(v) }
        return nil
    }

    var asBool: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else {
            throw DecodingError.typeMismatch(
                AnyCodableValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported value type")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        }
    }
}

// MARK: - Overlay Instance

/// A single overlay placed in the editor
struct OverlayInstance: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: OverlayKind
    var position: OverlayPosition
    var fontName: String
    var fontSize: Double
    var fontWeight: String
    var opacity: Double
    var typeSettings: [String: AnyCodableValue]

    enum CodingKeys: String, CodingKey {
        case id, kind, position, fontName, fontSize, fontWeight, opacity, typeSettings
    }

    init(id: UUID, kind: OverlayKind, position: OverlayPosition,
         fontName: String, fontSize: Double, fontWeight: String = "medium",
         opacity: Double = 1.0, typeSettings: [String: AnyCodableValue]) {
        self.id = id
        self.kind = kind
        self.position = position
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.opacity = opacity
        self.typeSettings = typeSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(OverlayKind.self, forKey: .kind)
        position = try container.decode(OverlayPosition.self, forKey: .position)
        fontName = try container.decode(String.self, forKey: .fontName)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        fontWeight = try container.decodeIfPresent(String.self, forKey: .fontWeight) ?? "medium"
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        typeSettings = try container.decode([String: AnyCodableValue].self, forKey: .typeSettings)
    }

    static func defaultInstance(kind: OverlayKind) -> OverlayInstance {
        let defaults = OverlayTypeDefaults.defaults(for: kind)
        return OverlayInstance(
            id: UUID(),
            kind: kind,
            position: .bottomLeft,
            fontName: defaults.fontName,
            fontSize: defaults.fontSize,
            fontWeight: defaults.fontWeight,
            opacity: 1.0,
            typeSettings: defaults.settings
        )
    }
}

// MARK: - Overlay Layout

/// A layout is a set of overlay stacks organized by position, plus global styling
struct OverlayLayout: Codable, Equatable {
    var stacks: [OverlayPosition: [OverlayInstance]]
    var marginTop: Int
    var marginLeft: Int
    var marginBottom: Int
    var marginRight: Int
    var shadowRadius: Int
    var shadowOpacity: Float
    var shadowOffsetX: Double
    var shadowOffsetY: Double
    var shadowColorHex: String
    var textColorHex: String

    static let empty = OverlayLayout(
        stacks: [:],
        marginTop: 50,
        marginLeft: 50,
        marginBottom: 50,
        marginRight: 50,
        shadowRadius: 6,
        shadowOpacity: 1.0,
        shadowOffsetX: 0,
        shadowOffsetY: 3,
        shadowColorHex: "#000000",
        textColorHex: "#FFFFFF"
    )

    /// All instances across all positions, flattened
    var allInstances: [OverlayInstance] {
        stacks.values.flatMap { $0 }
    }

    /// Find an instance by ID
    func instance(withID id: UUID) -> OverlayInstance? {
        allInstances.first { $0.id == id }
    }

    /// Instances in a given position
    func instances(at position: OverlayPosition) -> [OverlayInstance] {
        stacks[position] ?? []
    }

    /// Add an instance at a position (appends to the stack)
    mutating func addInstance(_ instance: OverlayInstance) {
        var stack = stacks[instance.position] ?? []
        stack.append(instance)
        stacks[instance.position] = stack
    }

    /// Remove an instance by ID
    @discardableResult
    mutating func removeInstance(id: UUID) -> OverlayInstance? {
        for (position, stack) in stacks {
            if let index = stack.firstIndex(where: { $0.id == id }) {
                var mutableStack = stack
                let removed = mutableStack.remove(at: index)
                stacks[position] = mutableStack.isEmpty ? nil : mutableStack
                return removed
            }
        }
        return nil
    }

    /// Insert an instance at a specific index within its position's stack
    mutating func insertInstance(_ instance: OverlayInstance, at index: Int) {
        var stack = stacks[instance.position] ?? []
        let clamped = min(index, stack.count)
        stack.insert(instance, at: clamped)
        stacks[instance.position] = stack
    }

    /// Move an instance to a new position at a specific index
    mutating func moveInstance(id: UUID, to newPosition: OverlayPosition, at index: Int) {
        guard var instance = removeInstance(id: id) else { return }
        instance.position = newPosition
        insertInstance(instance, at: index)
    }

    /// Update an instance in place
    mutating func updateInstance(_ instance: OverlayInstance) {
        for (position, stack) in stacks {
            if let index = stack.firstIndex(where: { $0.id == instance.id }) {
                var mutableStack = stack
                // If position changed, move it
                if position != instance.position {
                    mutableStack.remove(at: index)
                    stacks[position] = mutableStack.isEmpty ? nil : mutableStack
                    addInstance(instance)
                } else {
                    mutableStack[index] = instance
                    stacks[position] = mutableStack
                }
                return
            }
        }
    }

    // Custom coding to handle dictionary with enum keys
    enum CodingKeys: String, CodingKey {
        case stacks
        case marginTop, marginLeft, marginBottom, marginRight
        case shadowRadius, shadowOpacity, shadowOffsetX, shadowOffsetY
        case shadowColorHex, textColorHex
        // Legacy keys (read-only, for backwards compatibility)
        case marginXLegacy = "marginX"
        case marginYLegacy = "marginY"
    }

    init(stacks: [OverlayPosition: [OverlayInstance]],
         marginTop: Int, marginLeft: Int, marginBottom: Int, marginRight: Int,
         shadowRadius: Int, shadowOpacity: Float, shadowOffsetX: Double, shadowOffsetY: Double,
         shadowColorHex: String, textColorHex: String) {
        self.stacks = stacks
        self.marginTop = marginTop
        self.marginLeft = marginLeft
        self.marginBottom = marginBottom
        self.marginRight = marginRight
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.shadowOffsetX = shadowOffsetX
        self.shadowOffsetY = shadowOffsetY
        self.shadowColorHex = shadowColorHex
        self.textColorHex = textColorHex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stringKeyedStacks = try container.decode([String: [OverlayInstance]].self, forKey: .stacks)
        var result: [OverlayPosition: [OverlayInstance]] = [:]
        for (key, value) in stringKeyedStacks {
            if let position = OverlayPosition(rawValue: key) {
                result[position] = value
            }
        }
        stacks = result

        // Try the new four-side keys first; fall back to legacy marginX/marginY; finally default to 50.
        let legacyX = (try? container.decodeIfPresent(Int.self, forKey: .marginXLegacy)) ?? 50
        let legacyY = (try? container.decodeIfPresent(Int.self, forKey: .marginYLegacy)) ?? 50
        marginTop    = (try? container.decodeIfPresent(Int.self, forKey: .marginTop))    ?? legacyY
        marginLeft   = (try? container.decodeIfPresent(Int.self, forKey: .marginLeft))   ?? legacyX
        marginBottom = (try? container.decodeIfPresent(Int.self, forKey: .marginBottom)) ?? legacyY
        marginRight  = (try? container.decodeIfPresent(Int.self, forKey: .marginRight))  ?? legacyX

        shadowRadius = try container.decode(Int.self, forKey: .shadowRadius)
        shadowOpacity = try container.decode(Float.self, forKey: .shadowOpacity)
        shadowOffsetX = try container.decode(Double.self, forKey: .shadowOffsetX)
        shadowOffsetY = try container.decode(Double.self, forKey: .shadowOffsetY)

        // Backwards compat: missing colors default to black/white
        shadowColorHex = (try? container.decodeIfPresent(String.self, forKey: .shadowColorHex)) ?? "#000000"
        textColorHex = (try? container.decodeIfPresent(String.self, forKey: .textColorHex)) ?? "#FFFFFF"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var stringKeyedStacks: [String: [OverlayInstance]] = [:]
        for (key, value) in stacks {
            stringKeyedStacks[key.rawValue] = value
        }
        try container.encode(stringKeyedStacks, forKey: .stacks)
        try container.encode(marginTop, forKey: .marginTop)
        try container.encode(marginLeft, forKey: .marginLeft)
        try container.encode(marginBottom, forKey: .marginBottom)
        try container.encode(marginRight, forKey: .marginRight)
        try container.encode(shadowRadius, forKey: .shadowRadius)
        try container.encode(shadowOpacity, forKey: .shadowOpacity)
        try container.encode(shadowOffsetX, forKey: .shadowOffsetX)
        try container.encode(shadowOffsetY, forKey: .shadowOffsetY)
        try container.encode(shadowColorHex, forKey: .shadowColorHex)
        try container.encode(textColorHex, forKey: .textColorHex)
    }
}

// MARK: - Overlay Config (Root)

/// Top-level configuration, saved to /Users/Shared/Aerial/overlay-config.json
struct OverlayConfig: Codable, Equatable {
    var version: Int
    var perScreen: Bool
    var separateDesktopConfig: Bool
    var hideOverlaysDuringLogin: Bool
    var showVersionAtStartup: Bool
    var rotationMode: OverlayRotationMode
    var sharedLayout: OverlayLayout
    var screenLayouts: [String: OverlayLayout]
    var desktopSharedLayout: OverlayLayout?
    var desktopScreenLayouts: [String: OverlayLayout]?

    static let currentVersion = 1

    static let `default` = OverlayConfig(
        version: currentVersion,
        perScreen: false,
        separateDesktopConfig: false,
        hideOverlaysDuringLogin: true,
        showVersionAtStartup: true,
        rotationMode: .never,
        sharedLayout: .empty,
        screenLayouts: [:],
        desktopSharedLayout: nil,
        desktopScreenLayouts: nil
    )

    enum CodingKeys: String, CodingKey {
        case version, perScreen, separateDesktopConfig, hideOverlaysDuringLogin, showVersionAtStartup
        case rotationMode
        case sharedLayout, screenLayouts, desktopSharedLayout, desktopScreenLayouts
    }

    init(version: Int, perScreen: Bool, separateDesktopConfig: Bool,
         hideOverlaysDuringLogin: Bool = true,
         showVersionAtStartup: Bool = true,
         rotationMode: OverlayRotationMode = .never,
         sharedLayout: OverlayLayout, screenLayouts: [String: OverlayLayout],
         desktopSharedLayout: OverlayLayout?, desktopScreenLayouts: [String: OverlayLayout]?) {
        self.version = version
        self.perScreen = perScreen
        self.separateDesktopConfig = separateDesktopConfig
        self.hideOverlaysDuringLogin = hideOverlaysDuringLogin
        self.showVersionAtStartup = showVersionAtStartup
        self.rotationMode = rotationMode
        self.sharedLayout = sharedLayout
        self.screenLayouts = screenLayouts
        self.desktopSharedLayout = desktopSharedLayout
        self.desktopScreenLayouts = desktopScreenLayouts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        perScreen = try container.decode(Bool.self, forKey: .perScreen)
        separateDesktopConfig = try container.decode(Bool.self, forKey: .separateDesktopConfig)
        hideOverlaysDuringLogin = try container.decodeIfPresent(Bool.self, forKey: .hideOverlaysDuringLogin) ?? true
        showVersionAtStartup = try container.decodeIfPresent(Bool.self, forKey: .showVersionAtStartup) ?? true
        rotationMode = try container.decodeIfPresent(OverlayRotationMode.self, forKey: .rotationMode) ?? .never
        sharedLayout = try container.decode(OverlayLayout.self, forKey: .sharedLayout)
        screenLayouts = try container.decode([String: OverlayLayout].self, forKey: .screenLayouts)
        desktopSharedLayout = try container.decodeIfPresent(OverlayLayout.self, forKey: .desktopSharedLayout)
        desktopScreenLayouts = try container.decodeIfPresent([String: OverlayLayout].self, forKey: .desktopScreenLayouts)
    }

    /// Resolve the appropriate layout for a given screen and context.
    /// Pure function — no singleton access, no I/O.
    func resolvedLayout(for screenUUID: String?, isDesktop: Bool) -> OverlayLayout {
        if isDesktop && separateDesktopConfig {
            if perScreen, let uuid = screenUUID {
                return desktopScreenLayouts?[uuid] ?? .empty
            } else {
                return desktopSharedLayout ?? .empty
            }
        } else {
            if perScreen, let uuid = screenUUID {
                return screenLayouts[uuid] ?? .empty
            } else {
                return sharedLayout
            }
        }
    }

    static var fileURL: URL {
        URL(fileURLWithPath: AerialPaths.baseDirectory, isDirectory: true)
            .appendingPathComponent("overlay-config.json")
    }
}

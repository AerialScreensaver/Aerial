//
//  OverlayTypeProvider.swift
//  AerialScreenSaverExtension
//
//  Protocol for extensible overlay types. Each provider supplies
//  its rendering view and settings editor view.
//

import SwiftUI

/// Protocol that each overlay type must implement
protocol OverlayTypeProvider {
    static var kind: OverlayKind { get }

    /// Create the overlay rendering view for the screensaver/preview
    @ViewBuilder static func makeView(instance: OverlayInstance, state: OverlayState) -> AnyView

    /// Create the settings editor view for the overlay editor (Companion only)
    @ViewBuilder static func makeSettingsView(instance: Binding<OverlayInstance>) -> AnyView
}

/// Map weight string to SwiftUI Font.Weight
func fontWeight(from name: String) -> Font.Weight {
    switch name {
    case "ultraLight": return .ultraLight
    case "thin": return .thin
    case "light": return .light
    case "regular": return .regular
    case "medium": return .medium
    case "semibold": return .semibold
    case "bold": return .bold
    case "heavy": return .heavy
    case "black": return .black
    default: return .medium
    }
}

/// Helper to build a font from an OverlayInstance's fontName/fontSize/fontWeight
func overlayFont(for instance: OverlayInstance) -> Font {
    let weight = fontWeight(from: instance.fontWeight)
    if instance.fontName == "system" {
        return .system(size: instance.fontSize, weight: weight)
    }
    return .custom(instance.fontName, size: instance.fontSize).weight(weight)
}

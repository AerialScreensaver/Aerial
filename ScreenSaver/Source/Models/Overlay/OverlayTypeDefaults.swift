//
//  OverlayTypeDefaults.swift
//  Aerial
//
//  Default values for each overlay type.
//

import Foundation

struct OverlayTypeDefaults {

    static func defaults(for kind: OverlayKind) -> (fontName: String, fontSize: Double, fontWeight: String, settings: [String: AnyCodableValue]) {
        switch kind {
        case .clock:
            return (
                fontName: "system",
                fontSize: 50,
                fontWeight: "medium",
                settings: [
                    "showSeconds": .bool(true),
                    "hideAmPm": .bool(false),
                    "clockFormat": .string("default"),
                ]
            )

        case .date:
            return (
                fontName: "system",
                fontSize: 25,
                fontWeight: "medium",
                settings: [
                    "format": .string("textual"),
                    "withYear": .bool(false),
                ]
            )

        case .location:
            return (
                fontName: "system",
                fontSize: 28,
                fontWeight: "medium",
                settings: [
                    "time": .string("always"),
                ]
            )

        case .weather:
            return (
                fontName: "system",
                fontSize: 20,
                fontWeight: "medium",
                settings: [
                    "degree": .string("celsius"),
                    "mode": .string("current"),
                    "showHumidity": .bool(true),
                    "showWind": .bool(false),
                    "windUnit": .string("kmh"),
                    "showCity": .bool(true),
                    "locationMode": .string("current"),
                    "locationString": .string(""),
                ]
            )

        case .music:
            return (
                fontName: "system",
                fontSize: 20,
                fontWeight: "medium",
                settings: [:]
            )

        case .message:
            return (
                fontName: "system",
                fontSize: 20,
                fontWeight: "medium",
                settings: [
                    "message": .string("Hello, World!"),
                    "messageType": .string("text"),
                ]
            )

        case .countdown:
            return (
                fontName: "system",
                fontSize: 28,
                fontWeight: "medium",
                settings: [
                    "showSeconds": .bool(true),
                    "mode": .string("preciseDate"),
                    "targetDate": .string(""),
                    "enforceInterval": .bool(false),
                    "triggerDate": .string(""),
                ]
            )

        case .timer:
            return (
                fontName: "system",
                fontSize: 28,
                fontWeight: "medium",
                settings: [
                    "showSeconds": .bool(true),
                    "duration": .int(300),
                    "replaceWithMessage": .bool(false),
                    "customMessage": .string(""),
                ]
            )

        case .battery:
            return (
                fontName: "system",
                fontSize: 20,
                fontWeight: "medium",
                settings: [
                    "displayMode": .string("iconAndText"),
                    "hideAboveEnabled": .bool(false),
                    "hideAboveThreshold": .int(100),
                    "showOnDesktop": .bool(true),
                ]
            )

        case .verticalSpacer:
            return (
                fontName: "system",
                fontSize: 0,
                fontWeight: "medium",
                settings: [
                    "height": .int(50),
                ]
            )
        }
    }
}

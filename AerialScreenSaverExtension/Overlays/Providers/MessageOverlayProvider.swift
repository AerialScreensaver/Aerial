//
//  MessageOverlayProvider.swift
//  AerialScreenSaverExtension
//
//  Provider for message overlay type.
//

import SwiftUI

struct MessageOverlayProvider: OverlayTypeProvider {
    static let kind: OverlayKind = .message

    static func makeView(instance: OverlayInstance, state: OverlayState) -> AnyView {
        let message = instance.typeSettings["message"]?.asString ?? "Hello, World!"
        return AnyView(
            Text(message)
                .font(overlayFont(for: instance))
        )
    }

    static func makeSettingsView(instance: Binding<OverlayInstance>) -> AnyView {
        AnyView(MessageSettingsContent(instance: instance))
    }
}

private struct MessageSettingsContent: View {
    @Binding var instance: OverlayInstance

    private var message: String {
        instance.typeSettings["message"]?.asString ?? "Hello, World!"
    }

    private var messageType: String {
        instance.typeSettings["messageType"]?.asString ?? "text"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Type", selection: Binding(
                get: { messageType },
                set: { instance.typeSettings["messageType"] = .string($0) }
            )) {
                Text("Text").tag("text")
                Text("Shell Script").tag("shell")
                Text("Text File").tag("textfile")
            }

            TextField("Message", text: Binding(
                get: { message },
                set: { instance.typeSettings["message"] = .string($0) }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }
}

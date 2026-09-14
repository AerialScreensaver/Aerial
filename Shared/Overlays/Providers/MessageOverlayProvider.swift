//
//  MessageOverlayProvider.swift
//  Aerial
//
//  Provider for message overlay type. Three modes:
//  - "text": renders the literal message string.
//  - "shell" / "textfile": renders text produced by Companion's
//    MessageContentProvider (the sandboxed extension can't run scripts
//    or read arbitrary files), relayed via message-content.json and
//    refreshed on the shared overlay tick.
//

import SwiftUI

struct MessageOverlayProvider: OverlayTypeProvider {
    static let kind: OverlayKind = .message

    static func makeView(instance: OverlayInstance, state: OverlayState) -> AnyView {
        let messageType = instance.typeSettings["messageType"]?.asString ?? "text"
        let text: String
        switch messageType {
        case "shell", "textfile":
            text = state.messageText(for: instance) ?? ""
        default:
            text = instance.typeSettings["message"]?.asString ?? "Hello, World!"
        }
        return AnyView(
            Text(text)
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

    private var refreshInterval: Int {
        instance.typeSettings["refreshInterval"]?.asInt ?? 0
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

            switch messageType {
            case "shell":
                pathRow(key: "shellScript", label: "Script", prompt: "Choose a shell script")
                refreshPicker
                relayHint("The script runs in the Aerial app — keep it running for updates. Its output is shown as the message.")
            case "textfile":
                pathRow(key: "textFile", label: "File", prompt: "Choose a text file")
                refreshPicker
                relayHint("The file is read by the Aerial app — keep it running for updates. Its contents are shown as the message.")
            default:
                TextField("Message", text: Binding(
                    get: { message },
                    set: { instance.typeSettings["message"] = .string($0) }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func pathRow(key: String, label: String, prompt: String) -> some View {
        HStack(spacing: 8) {
            TextField(label, text: Binding(
                get: { instance.typeSettings[key]?.asString ?? "" },
                set: { instance.typeSettings[key] = .string($0) }
            ))
            .textFieldStyle(.roundedBorder)

            Button("Browse…") {
                let panel = NSOpenPanel()
                panel.message = prompt
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    instance.typeSettings[key] = .string(url.path)
                }
            }
        }
    }

    private var refreshPicker: some View {
        Picker("Refresh", selection: Binding(
            get: { refreshInterval },
            set: { instance.typeSettings["refreshInterval"] = .int($0) }
        )) {
            Text("Never").tag(0)
            Text("Every 10 seconds").tag(10)
            Text("Every 30 seconds").tag(30)
            Text("Every minute").tag(60)
            Text("Every 5 minutes").tag(300)
            Text("Every 10 minutes").tag(600)
        }
    }

    private func relayHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

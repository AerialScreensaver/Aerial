//
//  OverlaySettingsPane.swift
//  Aerial
//
//  Right sidebar in the overlay editor showing settings for the selected overlay.
//

import SwiftUI

struct OverlaySettingsPane: View {
    @ObservedObject var state: OverlayEditorState
    @Binding var instance: OverlayInstance
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: instance.kind.iconName)
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text(instance.kind.displayName)
                            .font(.title3.bold())
                    }
                    Text(instance.kind.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if instance.kind == .weather {
                        Image("OpenWeatherLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 36)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.white.opacity(0.85))
                                    .opacity(colorScheme == .dark ? 1 : 0)
                            }
                    }
                }
                .padding(.bottom, 4)

                Divider()

                if instance.kind != .verticalSpacer {
                    // Common settings
                    Text("Appearance")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)

                    CommonOverlaySettingsView(instance: $instance)

                    Divider()
                }

                // Type-specific settings
                Text("Options")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                OverlayTypeRegistry.makeSettingsView(for: $instance)

                Divider()

                // Remove button
                Button(role: .destructive) {
                    state.removeInstance(id: instance.id)
                } label: {
                    Label("Remove Overlay", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.delete, modifiers: [])
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(16)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onDeleteCommand {
            state.removeInstance(id: instance.id)
        }
    }
}

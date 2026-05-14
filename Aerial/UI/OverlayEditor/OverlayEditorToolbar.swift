//
//  OverlayEditorToolbar.swift
//  Aerial
//
//  Semi-transparent HUD toolbar floating at the top of the overlay editor preview.
//

import SwiftUI
import AppKit

struct OverlayEditorToolbar: View {
    @ObservedObject var state: OverlayEditorState
    let onClose: () -> Void

    private var config: OverlayConfig {
        OverlayConfigManager.shared.config
    }

    /// Available screens for the per-screen picker.
    private var screens: [(uuid: String, name: String)] {
        NSScreen.screens.enumerated().map { index, screen in
            let name = screen.localizedName
            let label = NSScreen.screens.count > 1 ? "\(index + 1): \(name)" : name
            return (uuid: screen.screenUuid, name: label)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Screen picker (only if per-screen layouts enabled)
            if config.perScreen {
                Picker("", selection: Binding(
                    get: { state.screenUUID ?? "" },
                    set: { state.switchScreen(uuid: $0.isEmpty ? nil : $0) }
                )) {
                    ForEach(screens, id: \.uuid) { screen in
                        Text(screen.name).tag(screen.uuid)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 120)
            }

            // Mode picker (only if desktop overlays enabled)
            if config.separateDesktopConfig {
                Picker("", selection: Binding(
                    get: { state.isDesktopMode },
                    set: { state.switchMode(isDesktop: $0) }
                )) {
                    Text("Screensaver").tag(false)
                    Text("Wallpaper").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            // Add overlay button (toggles floating palette)
            Button {
                state.showPalette.toggle()
            } label: {
                Image(systemName: "plus.circle")
                    .font(.title2)
                    .foregroundStyle(state.showPalette ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle Overlays palette")

            // Scale picker
            Picker("Scale", selection: $state.previewScale) {
                Text("50%").tag(CGFloat(0.5))
                Text("75%").tag(CGFloat(0.75))
                Text("100%").tag(CGFloat(1.0))
            }
            .pickerStyle(.segmented)
            .fixedSize()

            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(WindowDragArea())
        .padding(.top, 12)
    }
}

// MARK: - Window Drag Area

/// Invisible NSView that initiates window dragging on mouseDown.
/// Used so the toolbar acts as a drag handle for the borderless editor window.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private class DraggableView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

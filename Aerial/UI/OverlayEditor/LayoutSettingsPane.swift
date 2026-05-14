//
//  LayoutSettingsPane.swift
//  Aerial
//
//  Inspector content shown when no overlay is selected.
//  Edits layout-level settings (margins, color, shadow) that apply to all overlays.
//

import SwiftUI

struct LayoutSettingsPane: View {
    @ObservedObject var state: OverlayEditorState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.dashed")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("Layout Settings")
                            .font(.title3.bold())
                    }
                    Text("Settings that apply to all overlays in this layout.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                Divider()

                // Margins
                Text("Margins")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    marginRow(label: "Top", value: $state.layout.marginTop)
                    marginRow(label: "Left", value: $state.layout.marginLeft)
                    marginRow(label: "Bottom", value: $state.layout.marginBottom)
                    marginRow(label: "Right", value: $state.layout.marginRight)
                }

                Divider()

                // Color
                Text("Text color")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                ColorPicker("Color", selection: textColorBinding, supportsOpacity: true)

                Divider()

                // Shadow
                Text("Shadow")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    ColorPicker("Color", selection: shadowColorBinding, supportsOpacity: false)
                    shadowStepperRow(label: "Radius", value: $state.layout.shadowRadius, range: 0...30, suffix: "pt")
                    shadowSliderRow(label: "Opacity", value: shadowOpacityBinding, range: 0...1)
                    shadowOffsetRow(label: "Offset X", value: $state.layout.shadowOffsetX)
                    shadowOffsetRow(label: "Offset Y", value: $state.layout.shadowOffsetY)
                }

                Divider()

                // Reset all
                Button {
                    resetAllToDefaults()
                } label: {
                    Label("Reset all to defaults", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
            .padding(16)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Bindings

    private var textColorBinding: Binding<Color> {
        Binding(
            get: { Color(overlayHex: state.layout.textColorHex) },
            set: { state.layout.textColorHex = $0.toOverlayHex() }
        )
    }

    private var shadowColorBinding: Binding<Color> {
        Binding(
            get: { Color(overlayHex: state.layout.shadowColorHex) },
            set: { state.layout.shadowColorHex = $0.toOverlayHex() }
        )
    }

    private var shadowOpacityBinding: Binding<Double> {
        Binding(
            get: { Double(state.layout.shadowOpacity) },
            set: { state.layout.shadowOpacity = Float($0) }
        )
    }

    // MARK: - Row builders

    @ViewBuilder
    private func marginRow(label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .frame(width: 70, alignment: .leading)
            Stepper(value: value, in: 0...500, step: 10) {
                Text("\(value.wrappedValue) pt")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func shadowStepperRow(label: String, value: Binding<Int>, range: ClosedRange<Int>, suffix: String) -> some View {
        HStack {
            Text(label)
                .frame(width: 70, alignment: .leading)
            Stepper(value: value, in: range, step: 1) {
                Text("\(value.wrappedValue) \(suffix)")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func shadowSliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label)
                .frame(width: 70, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func shadowOffsetRow(label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
                .frame(width: 70, alignment: .leading)
            Stepper(value: value, in: -20...20, step: 1) {
                Text(String(format: "%.0f pt", value.wrappedValue))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Reset

    private func resetAllToDefaults() {
        state.layout.marginTop = 50
        state.layout.marginLeft = 50
        state.layout.marginBottom = 50
        state.layout.marginRight = 50
        state.layout.textColorHex = "#FFFFFF"
        state.layout.shadowColorHex = "#000000"
        state.layout.shadowRadius = 6
        state.layout.shadowOpacity = 1.0
        state.layout.shadowOffsetX = 0
        state.layout.shadowOffsetY = 3
    }
}

// MARK: - Color → hex helper (Companion-only, uses NSColor)

private extension Color {
    /// Convert this Color to a hex string `#RRGGBBAA` for storage.
    /// Uses NSColor under sRGB to extract components.
    func toOverlayHex() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        let a = Int(round(ns.alphaComponent * 255))
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}

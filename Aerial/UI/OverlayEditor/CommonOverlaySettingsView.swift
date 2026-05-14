//
//  CommonOverlaySettingsView.swift
//  Aerial
//
//  Common settings controls shared by all overlay types:
//  font picker, font size slider, position picker.
//

import SwiftUI

struct CommonOverlaySettingsView: View {
    @Binding var instance: OverlayInstance

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Font name
            Picker("Font", selection: $instance.fontName) {
                Text("System").tag("system")
                ForEach(availableFonts, id: \.self) { font in
                    Text(font).tag(font)
                }
            }
            .labelsHidden()

            // Font weight
            Picker("Weight", selection: $instance.fontWeight) {
                Text("Ultra Light").tag("ultraLight")
                Text("Thin").tag("thin")
                Text("Light").tag("light")
                Text("Regular").tag("regular")
                Text("Medium").tag("medium")
                Text("Semibold").tag("semibold")
                Text("Bold").tag("bold")
                Text("Heavy").tag("heavy")
                Text("Black").tag("black")
            }

            // Font size
            VStack(alignment: .leading, spacing: 4) {
                Text("Size: \(Int(instance.fontSize))pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $instance.fontSize, in: 10...300, step: 1)
            }

            // Opacity
            VStack(alignment: .leading, spacing: 4) {
                Text("Opacity: \(Int(instance.opacity * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $instance.opacity, in: 0...1, step: 0.01)
            }

            // Position picker
            Picker("Position", selection: $instance.position) {
                ForEach(OverlayPosition.allCases) { position in
                    Text(position.displayName).tag(position)
                }
            }
        }
    }

    private var availableFonts: [String] {
        [
            "Helvetica Neue",
            "Avenir Next",
            "SF Pro",
            "Menlo",
            "Monaco",
            "Georgia",
            "Futura",
            "Gill Sans",
            "Optima",
            "Palatino",
        ]
    }
}

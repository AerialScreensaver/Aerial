//
//  CommonOverlaySettingsView.swift
//  Aerial
//
//  Common settings controls shared by all overlay types:
//  font picker, font size slider, position picker.
//

import SwiftUI
import AppKit

struct CommonOverlaySettingsView: View {
    @Binding var instance: OverlayInstance

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Font name
            Menu {
                Button {
                    instance.fontName = "system"
                } label: {
                    fontMenuLabel("System", isSelected: instance.fontName == "system")
                }

                Divider()

                ForEach(curatedFonts, id: \.self) { font in
                    Button {
                        instance.fontName = font
                    } label: {
                        fontMenuLabel(font, isSelected: instance.fontName == font)
                    }
                }

                Divider()

                Menu("All Fonts") {
                    ForEach(Self.groupedFontFamilies, id: \.key) { group in
                        Menu(group.key) {
                            ForEach(group.fonts, id: \.self) { font in
                                Button {
                                    instance.fontName = font
                                } label: {
                                    fontMenuLabel(font, isSelected: instance.fontName == font)
                                }
                            }
                        }
                    }
                }
            } label: {
                Text(selectedFontDisplayName)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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

    private var curatedFonts: [String] {
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

    /// User-facing name for the current selection; maps the special "system" value.
    private var selectedFontDisplayName: String {
        instance.fontName == "system" ? "System" : instance.fontName
    }

    /// Menu row label with a leading checkmark when it's the active selection.
    @ViewBuilder
    private func fontMenuLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

extension CommonOverlaySettingsView {
    /// Every user-visible font family, enumerated once per process. Hidden system
    /// families (names starting with ".") are dropped to match the macOS font panel.
    static let allFontFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted()

    /// `allFontFamilies` bucketed by uppercased first letter for the "All Fonts"
    /// submenu. Non-letter first characters bucket under "#". Keys are sorted and
    /// each bucket stays alphabetical (inherited from the sorted source).
    static let groupedFontFamilies: [(key: String, fonts: [String])] = {
        var groups: [String: [String]] = [:]
        for family in allFontFamilies {
            let key: String
            if let first = family.uppercased().first, first.isLetter {
                key = String(first)
            } else {
                key = "#"
            }
            groups[key, default: []].append(family)
        }
        return groups
            .map { (key: $0.key, fonts: $0.value) }
            .sorted { $0.key < $1.key }
    }()
}

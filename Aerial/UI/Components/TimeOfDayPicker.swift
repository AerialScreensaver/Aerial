//
//  TimeOfDayPicker.swift
//  Aerial Companion
//
//  Segmented Day / Sunrise / Sunset / Night picker with the time-of-day
//  icons used across the Video Library. Shared by a video's time-of-day
//  override and the live feed editor.
//

import SwiftUI

struct TimeOfDayPicker: View {
    @Binding var selection: String

    static let options: [(value: String, icon: String, label: String)] = [
        ("day", "sun.max", "Day"),
        ("sunrise", "sunrise", "Sunrise"),
        ("sunset", "sunset", "Sunset"),
        ("night", "moon.stars", "Night"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.options, id: \.value) { value, icon, label in
                let isActive = selection == value
                Button(action: { selection = value }) {
                    VStack(spacing: 2) {
                        Image(systemName: icon)
                            .font(.system(size: 14))
                        Text(label)
                            .font(.system(size: 9))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(isActive ? Color.aerial.opacity(0.15) : Color.clear)
                    .foregroundColor(isActive ? .aerial : .secondary)
                    .cornerRadius(4)
                }
                .buttonStyle(.borderless)
                .help("Set to \(label)")
                .accessibilityLabel("Set time of day to \(label)")
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

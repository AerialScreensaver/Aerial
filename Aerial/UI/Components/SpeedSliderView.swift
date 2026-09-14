//
//  SpeedSliderView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

/// Speed slider with tortoise/hare icons
struct SpeedSliderView: View {
    @Binding var speed: Int
    /// Whether to show the trailing numeric label (e.g. "1/8x"). The Home
    /// recap Speed card hides it because the value is shown on its own line.
    var showsLabel: Bool = true

    /// Human-readable multiplier for a 0…100 speed value. Static so other
    /// speed UI (e.g. the Home recap Speed card) formats identically.
    static func label(for speed: Int) -> String {
        switch speed {
        case 100: return "1x"
        case 80: return "2/3x"
        case 60: return "1/2x"
        case 40: return "1/3x"
        case 20: return "1/4x"
        case 0: return "1/8x"
        default: return "\(speed)%"
        }
    }

    private var speedLabel: String { Self.label(for: speed) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tortoise.fill")
                .foregroundColor(.secondary)
                .font(.system(size: 17))

            Slider(
                value: Binding(
                    get: { Double(speed) },
                    set: { speed = Int($0) }
                ),
                in: 0...100,
                step: 20
            )
            .controlSize(.small)
            .help("Playback speed (1⁄8× to 1×)")
            .accessibilityLabel("Playback speed")
            .accessibilityValue(speedLabel)

            Image(systemName: "hare.fill")
                .foregroundColor(.secondary)
                .font(.system(size: 17))

            if showsLabel {
                Text(speedLabel)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .trailing)
                    .monospacedDigit()
            }
        }
    }
}

struct SpeedSliderView_Previews: PreviewProvider {
    @State static var speed = 100

    static var previews: some View {
        SpeedSliderView(speed: $speed)
            .padding()
            .frame(width: 280)
    }
}

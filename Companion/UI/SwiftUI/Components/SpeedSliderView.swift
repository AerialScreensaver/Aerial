//
//  SpeedSliderView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

/// Speed slider with tortoise/hare icons
@available(macOS 11.0, *)
struct SpeedSliderView: View {
    @Binding var speed: Int

    private var speedLabel: String {
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tortoise.fill")
                .foregroundColor(.secondary)
                .font(.system(size: 14))

            Slider(
                value: Binding(
                    get: { Double(speed) },
                    set: { speed = Int($0) }
                ),
                in: 0...100,
                step: 20
            )
            .controlSize(.small)

            Image(systemName: "hare.fill")
                .foregroundColor(.secondary)
                .font(.system(size: 14))

            Text(speedLabel)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 35, alignment: .trailing)
                .monospacedDigit()
        }
    }
}

@available(macOS 11.0, *)
struct SpeedSliderView_Previews: PreviewProvider {
    @State static var speed = 100

    static var previews: some View {
        SpeedSliderView(speed: $speed)
            .padding()
            .frame(width: 280)
    }
}

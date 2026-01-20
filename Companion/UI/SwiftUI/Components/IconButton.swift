//
//  IconButton.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

/// A reusable icon button with a label below
@available(macOS 11.0, *)
struct IconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                Text(label)
                    .font(.caption2)
            }
            .frame(minWidth: 44)
        }
        .buttonStyle(.borderless)
    }
}

@available(macOS 11.0, *)
struct IconButton_Previews: PreviewProvider {
    static var previews: some View {
        HStack {
            IconButton(systemImage: "stop.fill", label: "Stop") {}
            IconButton(systemImage: "pause.fill", label: "Pause") {}
            IconButton(systemImage: "forward.fill", label: "Skip") {}
        }
        .padding()
    }
}

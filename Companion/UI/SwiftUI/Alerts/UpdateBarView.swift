//
//  UpdateBarView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

/// Orange notification bar shown when an update is available
@available(macOS 11.0, *)
struct UpdateBarView: View {
    let message: String
    var onUpdateNow: () -> Void

    init(message: String = "A new version is available!", onUpdateNow: @escaping () -> Void) {
        self.message = message
        self.onUpdateNow = onUpdateNow
    }

    var body: some View {
        HStack {
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)

            Spacer()

            Button(action: onUpdateNow) {
                Label("Update now", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange)
        .cornerRadius(8)
    }
}

@available(macOS 11.0, *)
struct UpdateBarView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            UpdateBarView(onUpdateNow: {})
            UpdateBarView(message: "Downloading...", onUpdateNow: {})
        }
        .padding()
        .frame(width: 300)
    }
}

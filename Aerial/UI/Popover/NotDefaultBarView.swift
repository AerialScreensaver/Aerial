//
//  NotDefaultBarView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

/// Blue notification bar nagging that Aerial 4 isn't yet the active wallpaper /
/// screensaver, with a button that sets it. Used in parallel for both roles.
struct NotDefaultBarView: View {
    let message: String
    var buttonTitle: String = "Set up"
    var onAction: () async -> Void

    @State private var isWorking = false

    var body: some View {
        HStack {
            Text(message)
                .font(.system(size: 13, weight: .medium))

            Spacer()

            Button(action: {
                Task {
                    isWorking = true
                    await onAction()
                    isWorking = false
                }
            }) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Label(buttonTitle, systemImage: "gear")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isWorking)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.aerial.opacity(0.15))
        .cornerRadius(8)
    }
}

struct NotDefaultBarView_Previews: PreviewProvider {
    static var previews: some View {
        NotDefaultBarView(message: "Aerial 4 isn't your wallpaper yet", onAction: {})
            .padding()
            .frame(width: 300)
    }
}

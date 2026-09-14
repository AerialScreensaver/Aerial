//
//  NotDefaultBarView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

/// Blue notification bar shown when Aerial is not set as the default screensaver
struct NotDefaultBarView: View {
    var onSetAsDefault: () async -> Void

    @State private var isSettingDefault = false

    var body: some View {
        HStack {
            Text("Screen Saver is not set as default")
                .font(.system(size: 13, weight: .medium))

            Spacer()

            Button(action: {
                Task {
                    isSettingDefault = true
                    await onSetAsDefault()
                    isSettingDefault = false
                }
            }) {
                if isSettingDefault {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Label("Set", systemImage: "wrench")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isSettingDefault)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.aerial.opacity(0.15))
        .cornerRadius(8)
    }
}

struct NotDefaultBarView_Previews: PreviewProvider {
    static var previews: some View {
        NotDefaultBarView(onSetAsDefault: {})
            .padding()
            .frame(width: 300)
    }
}

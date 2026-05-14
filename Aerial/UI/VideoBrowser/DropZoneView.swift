//
//  DropZoneView.swift
//  Aerial Companion
//
//  Reusable drop zone for video file imports.
//

import SwiftUI

struct DropZoneView: View {
    @Binding var isTargeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                style: StrokeStyle(lineWidth: 2, dash: [8, 4])
            )
            .foregroundColor(isTargeted ? .aerial : .secondary.opacity(0.5))
            .frame(height: 80)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isTargeted ? Color.aerial.opacity(0.1) : Color.clear)
            )
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 24))
                        .foregroundColor(isTargeted ? .aerial : .secondary)

                    Text("Drop video files here to add them")
                        .font(.system(size: 13))
                        .foregroundColor(isTargeted ? .aerial : .secondary)
                }
            }
    }
}

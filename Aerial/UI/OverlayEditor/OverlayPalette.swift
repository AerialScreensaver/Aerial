//
//  OverlayPalette.swift
//  Aerial
//
//  Vertical list of all available overlay types for drag-and-drop.
//

import SwiftUI

struct OverlayPalette: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Drag to add")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(OverlayKind.allCases) { kind in
                        paletteRow(kind: kind)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private func paletteRow(kind: OverlayKind) -> some View {
        let dragData = OverlayDragData(kind: kind, existingInstanceID: nil)

        HStack(spacing: 10) {
            Image(systemName: kind.iconName)
                .font(.system(size: 22))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName)
                    .font(.system(size: 14, weight: .semibold))
                Text(kind.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
        .contentShape(Rectangle())
        .draggable(dragData) {
            // Drag preview — matches palette row style
            HStack(spacing: 10) {
                Image(systemName: kind.iconName)
                    .font(.system(size: 22))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    Text(kind.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.aerial.opacity(0.15))
            )
        }
    }
}

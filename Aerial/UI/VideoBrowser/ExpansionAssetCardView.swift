//
//  ExpansionAssetCardView.swift
//  Aerial Companion
//
//  Read-only metadata card for global search results that come from
//  an uninstalled expansion. Mirrors the layout of VideoBrowserCardView
//  (108-tall thumbnail, title + subtitle below) but carries no
//  playback, download, or selection state. Clicking does nothing —
//  the parent GlobalSearchSourceCard carries the "Open in Expansions"
//  jump button.
//

import SwiftUI

struct ExpansionAssetCardView: View {
    let asset: ExpansionAsset

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
                .frame(height: 108)
                .clipped()
                .cornerRadius(6)

            Text(asset.title ?? asset.id)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            if let label = asset.accessibilityLabel, !label.isEmpty {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = asset.previewImage.flatMap(URL.init(string:)) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    placeholder
                case .empty:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            )
    }
}

//
//  SourceThumbnailCard.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 14/02/2026.
//

import SwiftUI

/// A thumbnail card for a video source category item
struct SourceThumbnailCard: View {
    let name: String
    let videoCount: Int
    let isSelected: Bool
    let thumbnail: NSImage?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack {
                    if let thumbnail = thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 80, height: 45)
                            .clipped()
                            .cornerRadius(6)
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 80, height: 45)
                            .cornerRadius(6)
                            .overlay(
                                Image(systemName: "photo")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 16))
                            )
                    }

                    // Video count badge — top left
                    VStack {
                        HStack {
                            HStack(spacing: 2) {
                                Image(systemName: "film")
                                    .font(.system(size: 8, weight: .semibold))
                                Text("\(videoCount)")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                            .padding(3)
                            Spacer()
                        }
                        Spacer()
                    }
                    .frame(width: 80, height: 45)

                    // Selection checkmark — bottom right
                    if isSelected {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.aerial)
                                    .background(Circle().fill(Color.white).frame(width: 12, height: 12))
                                    .padding(3)
                            }
                        }
                        .frame(width: 80, height: 45)
                    }
                }

                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(width: 80)
            }
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.aerial : Color.clear, lineWidth: 2)
                .padding(-2)
        )
    }
}

struct SourceThumbnailCard_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 12) {
            SourceThumbnailCard(name: "Hawaii", videoCount: 12, isSelected: true, thumbnail: nil, onTap: {})
            SourceThumbnailCard(name: "New York", videoCount: 5, isSelected: false, thumbnail: nil, onTap: {})
        }
        .padding()
    }
}

//
//  FormatBadge.swift
//  Aerial Companion
//
//  Reusable pill showing a video format (e.g. "4K HDR"). Used in the
//  Inspector for the current format and the "Other formats" row.
//

import SwiftUI

struct FormatBadge: View {
    enum Variant {
        case current    // Highlighted — the format that's actually resolving
        case available  // Other format available for this video, tappable
    }

    let format: VideoFormat
    let variant: Variant
    var action: (() -> Void)?

    var body: some View {
        Button(action: { action?() }) {
            Text(AerialVideo.label(for: format))
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundColor(foreground)
                .background(
                    Capsule().fill(background)
                )
                .overlay(
                    Capsule().stroke(stroke, lineWidth: 0.5)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .disabled(action == nil)
    }

    private var foreground: Color {
        switch variant {
        case .current: return .aerial
        case .available: return .secondary
        }
    }

    private var background: Color {
        switch variant {
        case .current: return Color.aerial.opacity(0.15)
        case .available: return Color.secondary.opacity(0.10)
        }
    }

    private var stroke: Color {
        switch variant {
        case .current: return Color.aerial.opacity(0.35)
        case .available: return Color.secondary.opacity(0.20)
        }
    }
}

// Lets the Inspector alert track "which format did the user tap".
extension VideoFormat: Identifiable {
    public var id: Int { rawValue }
}

/// Minimal horizontally-wrapping layout — arranges children left-to-
/// right and wraps to the next row when the proposed width runs out.
/// Used in the Inspector's "Other Formats" row so a handful of
/// format badges reflow cleanly inside the 280pt inspector.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x - spacing)
        }
        return CGSize(width: totalWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

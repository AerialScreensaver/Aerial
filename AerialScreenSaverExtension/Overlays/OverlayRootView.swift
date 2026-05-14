//
//  OverlayRootView.swift
//  AerialScreenSaverExtension
//
//  SwiftUI view hierarchy for the unified overlay system.
//  Uses alignment-based ZStack to position overlays in corners.
//

import SwiftUI

/// Root SwiftUI view that renders all overlays
struct OverlayRootView: View {
    @ObservedObject var state: OverlayState

    /// Clockwise cycle for the four corner positions.
    private static let cornerCycle: [OverlayPosition] =
        [.topLeft, .topRight, .bottomRight, .bottomLeft]

    /// Cycle for the three center positions (top → center → bottom).
    private static let centerCycle: [OverlayPosition] =
        [.topCenter, .center, .bottomCenter]

    var body: some View {
        GeometryReader { geo in
            if !state.configInstances.isEmpty {
                configBasedOverlays(geo: geo)
            }
        }
    }

    // MARK: - Config-Based Rendering

    /// Given the physical screen position we're about to render at and the
    /// current rotation tick, return which configured position's stack
    /// should appear there. At tick 0 this is the identity mapping.
    private func sourcePosition(for screenPos: OverlayPosition, tick: Int) -> OverlayPosition {
        let cycle: [OverlayPosition]
        if Self.cornerCycle.contains(screenPos) {
            cycle = Self.cornerCycle
        } else if Self.centerCycle.contains(screenPos) {
            cycle = Self.centerCycle
        } else {
            return screenPos
        }
        guard let idx = cycle.firstIndex(of: screenPos) else { return screenPos }
        let n = cycle.count
        let shifted = ((idx - tick) % n + n) % n
        return cycle[shifted]
    }

    @ViewBuilder
    private func configBasedOverlays(geo: GeometryProxy) -> some View {
        let layout = state.configLayout ?? .empty
        let tick = state.rotationTick

        ZStack {
            // Inner layer: position stacks with their layout margins
            ZStack {
                ForEach(OverlayPosition.allCases) { screenPos in
                    let source = sourcePosition(for: screenPos, tick: tick)
                    let instances = state.instancesInPosition(source)
                    if !instances.isEmpty {
                        configPositionStack(position: screenPos, instances: instances, screenWidth: geo.size.width)
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: screenPos.swiftUIAlignment
                            )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(configEdgeInsets(layout: layout))
            .foregroundStyle(state.textColor)
            .animation(.easeInOut(duration: 0.6), value: tick)

            // Version banner: independent layer, hugs the bottom-right corner
            if state.showVersionBanner {
                let mLeft: CGFloat = state.isPreview ? 10 : CGFloat(layout.marginLeft)
                let mRight: CGFloat = state.isPreview ? 10 : CGFloat(layout.marginRight)
                Text(state.versionBannerText)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .modifier(ConfigShadowModifier(layout: layout))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, mRight + state.dockInset.trailing)
                    .padding(.leading, mLeft)
                    .padding(.bottom, 16 + state.dockInset.bottom)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 1.0), value: state.showVersionBanner)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func configPositionStack(position: OverlayPosition, instances: [OverlayInstance], screenWidth: CGFloat) -> some View {
        let maxWidth = configCornerMaxWidth(position: position, screenWidth: screenWidth)
        let layout = state.configLayout ?? .empty

        VStack(alignment: position.horizontalStackAlignment, spacing: 10) {
            ForEach(instances) { instance in
                OverlayTypeRegistry.makeView(for: instance, state: state)
                    .modifier(ConfigShadowModifier(layout: layout))
                    .opacity(instance.opacity)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: maxWidth, alignment: position.stackFrameAlignment)
    }

    private func configEdgeInsets(layout: OverlayLayout) -> EdgeInsets {
        let top: CGFloat    = state.isPreview ? 10 : CGFloat(layout.marginTop)
        let left: CGFloat   = state.isPreview ? 10 : CGFloat(layout.marginLeft)
        let bottom: CGFloat = state.isPreview ? 10 : CGFloat(layout.marginBottom)
        let right: CGFloat  = state.isPreview ? 10 : CGFloat(layout.marginRight)
        let d = state.dockInset
        return EdgeInsets(
            top: top + d.top,
            leading: left + d.leading,
            bottom: bottom + d.bottom,
            trailing: right + d.trailing
        )
    }

    private func configCornerMaxWidth(position: OverlayPosition, screenWidth: CGFloat) -> CGFloat {
        switch position {
        case .topCenter, .bottomCenter, .center:
            return screenWidth * 0.6
        default:
            return screenWidth * 0.45
        }
    }

}

// MARK: - Config Shadow

/// Shadow modifier using layout-level settings (for config-based rendering).
private struct ConfigShadowModifier: ViewModifier {
    let layout: OverlayLayout

    func body(content: Content) -> some View {
        content.shadow(
            color: Color(overlayHex: layout.shadowColorHex).opacity(Double(layout.shadowOpacity)),
            radius: CGFloat(layout.shadowRadius),
            x: layout.shadowOffsetX,
            y: -layout.shadowOffsetY
        )
    }
}

// MARK: - OverlayPosition SwiftUI Extensions

extension OverlayPosition {
    var swiftUIAlignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topCenter: return .top
        case .topRight: return .topTrailing
        case .center: return .center
        case .bottomLeft: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }

    var horizontalStackAlignment: HorizontalAlignment {
        switch self {
        case .topLeft, .bottomLeft: return .leading
        case .topCenter, .bottomCenter, .center: return .center
        case .topRight, .bottomRight: return .trailing
        }
    }

    var stackFrameAlignment: Alignment {
        switch self {
        case .topLeft, .bottomLeft: return .leading
        case .topCenter, .bottomCenter, .center: return .center
        case .topRight, .bottomRight: return .trailing
        }
    }
}


//
//  OverlayPreviewRenderer.swift
//  Aerial
//
//  Renders all overlay instances from the editor state using the type registry.
//  Mirrors the same layout logic as OverlayRootView but driven by OverlayEditorState.
//  During a drag, interleaves inline drop zones between overlays for precise ordering.
//

import SwiftUI

struct OverlayPreviewRenderer: View {
    @ObservedObject var state: OverlayEditorState
    @ObservedObject var overlayState: OverlayState
    @State private var refreshTimer: Timer?
    @State private var weatherDebounceTask: DispatchWorkItem?

    var body: some View {
        GeometryReader { geo in
            let scaleFactor = state.previewScale
            let refWidth = geo.size.width / scaleFactor
            let refHeight = geo.size.height / scaleFactor

            ZStack {
                ForEach(OverlayPosition.allCases) { position in
                    let instances = state.layout.instances(at: position)
                    if !instances.isEmpty || state.isDragging {
                        positionStack(position: position, instances: instances, screenWidth: refWidth)
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: position.swiftUIAlignment
                            )
                    }
                }
            }
            .padding(previewEdgeInsets)
            .foregroundStyle(Color(overlayHex: state.layout.textColorHex))
            .frame(width: refWidth, height: refHeight)
            .overlay(
                dockMiniature
                    .frame(width: refWidth, height: refHeight),
                alignment: .center
            )
            .scaleEffect(scaleFactor, anchor: .topLeading)
        }
        .dropDestination(for: OverlayDragData.self) { _, _ in false } isTargeted: { targeted in
            if targeted { state.dragEntered() } else { state.dragExited() }
        }
        .onAppear {
            startRefreshTimer()
            fetchAllWeatherPreviews()
            fetchMusicPreview()
        }
        .onDisappear { stopRefreshTimer() }
        .onChange(of: weatherSettingsSnapshot) { _ in
            weatherDebounceTask?.cancel()
            let task = DispatchWorkItem { fetchAllWeatherPreviews() }
            weatherDebounceTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: task)
        }
        .onChange(of: state.isDragging) { dragging in
            if dragging { stopRefreshTimer() } else { startRefreshTimer() }
        }
    }

    private func startRefreshTimer() {
        stopRefreshTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            overlayState.objectWillChange.send()
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @ViewBuilder
    private func positionStack(position: OverlayPosition, instances: [OverlayInstance], screenWidth: CGFloat) -> some View {
        let maxWidth = cornerMaxWidth(position: position, screenWidth: screenWidth)
        let zoneWidth = screenWidth * 0.2
        let visible = instances.filter { $0.id != state.draggingInstanceID }

        VStack(alignment: position.horizontalStackAlignment, spacing: state.isDragging ? 2 : 10) {
            if visible.isEmpty && state.isDragging {
                EmptyPositionDropZone(state: state, position: position, zoneWidth: zoneWidth)
            } else if state.isDragging {
                // Interleave drop zones: [zone 0] [overlay 0] [zone 1] [overlay 1] [zone 2]
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, instance in
                    InlineDropZone(state: state, position: position, index: index, zoneWidth: zoneWidth)
                    instanceView(instance: instance)
                        .onTapGesture { state.select(instance.id) }
                        .draggable(OverlayDragData(kind: instance.kind, existingInstanceID: instance.id)) {
                            scaledDragPreview(instance: instance)
                        }
                }
                InlineDropZone(state: state, position: position, index: visible.count, zoneWidth: zoneWidth)
            } else {
                ForEach(instances) { instance in
                    instanceView(instance: instance)
                        .onTapGesture { state.select(instance.id) }
                        .draggable(OverlayDragData(kind: instance.kind, existingInstanceID: instance.id)) {
                            scaledDragPreview(instance: instance)
                        }
                }
            }
        }
        .frame(maxWidth: maxWidth, alignment: position.stackFrameAlignment)
    }

    @ViewBuilder
    private func scaledDragPreview(instance: OverlayInstance) -> some View {
        instanceView(instance: instance)
            .scaleEffect(state.previewScale)
            .fixedSize()
            .onAppear {
                DispatchQueue.main.async {
                    state.draggingInstanceID = instance.id
                }
            }
    }

    @ViewBuilder
    private func instanceView(instance: OverlayInstance) -> some View {
        let isSelected = state.selectedInstanceID == instance.id
        let layout = state.layout

        OverlayTypeRegistry.makeView(for: instance, state: overlayState)
            .shadow(
                color: Color(overlayHex: layout.shadowColorHex).opacity(Double(layout.shadowOpacity)),
                radius: CGFloat(layout.shadowRadius),
                x: layout.shadowOffsetX,
                y: -layout.shadowOffsetY
            )
            .opacity(instance.opacity)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? Color.aerial : (state.isDragging ? Color.clear : Color.white.opacity(0.15)),
                        style: StrokeStyle(
                            lineWidth: isSelected ? 2 : 1,
                            dash: isSelected ? [] : [4, 4]
                        )
                    )
            )
    }

    /// Snapshot of weather-relevant settings for all weather instances, used to detect changes.
    private var weatherSettingsSnapshot: [String] {
        state.layout.allInstances
            .filter { $0.kind == .weather }
            .map { inst in
                let loc = inst.typeSettings["locationMode"]?.asString ?? ""
                let city = inst.typeSettings["locationString"]?.asString ?? ""
                let deg = inst.typeSettings["degree"]?.asString ?? ""
                let mode = inst.typeSettings["mode"]?.asString ?? ""
                return "\(inst.id)|\(loc)|\(city)|\(deg)|\(mode)"
            }
    }

    private func fetchAllWeatherPreviews() {
        for instance in state.layout.allInstances where instance.kind == .weather {
            overlayState.fetchWeatherForPreview(instance: instance)
        }
    }

    private func fetchMusicPreview() {
        let hasMusicOverlay = state.layout.allInstances.contains { $0.kind == .music }
        guard hasMusicOverlay else { return }

        NowPlayingCoordinator.shared.fetchCurrentSong { song in
            overlayState.songInfo = song
        }
    }

    private var previewEdgeInsets: EdgeInsets {
        let top    = CGFloat(state.layout.marginTop)
        let left   = CGFloat(state.layout.marginLeft)
        let bottom = CGFloat(state.layout.marginBottom)
        let right  = CGFloat(state.layout.marginRight)
        // In desktop mode, add the dock inset so previewed overlays sit clear of the dock miniature.
        let d = state.isDesktopMode ? state.dockInfo.swiftUIInsets : EdgeInsets()
        return EdgeInsets(
            top: top + d.top,
            leading: left + d.leading,
            bottom: bottom + d.bottom,
            trailing: right + d.trailing
        )
    }

    /// Translucent dock miniature shown only when editing desktop mode and a dock is present.
    @ViewBuilder
    private var dockMiniature: some View {
        if state.isDesktopMode && state.dockInfo.edge != .none {
            let thickness = state.dockInfo.thickness
            let inset: CGFloat = 6
            let bar = ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                    )
                Text("Dock")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }

            switch state.dockInfo.edge {
            case .bottom:
                bar
                    .frame(maxWidth: .infinity)
                    .frame(height: thickness)
                    .padding(.horizontal, inset)
                    .padding(.bottom, inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
            case .left:
                bar
                    .frame(width: thickness)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, inset)
                    .padding(.leading, inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            case .right:
                bar
                    .frame(width: thickness)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, inset)
                    .padding(.trailing, inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .allowsHitTesting(false)
            case .none:
                EmptyView()
            }
        }
    }

    private func cornerMaxWidth(position: OverlayPosition, screenWidth: CGFloat) -> CGFloat {
        switch position {
        case .topCenter, .bottomCenter, .center:
            return screenWidth * 0.6
        default:
            return screenWidth * 0.45
        }
    }
}

// MARK: - Inline Drop Zone

/// Drop indicator that appears between overlays during a drag.
/// Shows a dashed rounded rect, fills with accent color when targeted.
private struct InlineDropZone: View {
    @ObservedObject var state: OverlayEditorState
    let position: OverlayPosition
    let index: Int
    let zoneWidth: CGFloat
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(isTargeted ? Color.aerial.opacity(0.3) : Color.clear)
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isTargeted ? Color.aerial : Color.white.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1.5, dash: isTargeted ? [] : [5, 3])
                )
        }
        .frame(width: zoneWidth, height: 40)
        .dropDestination(for: OverlayDragData.self) { items, _ in
            guard let item = items.first else { return false }
            if let existingID = item.existingInstanceID {
                state.moveInstance(id: existingID, to: position, at: index)
            } else {
                state.addInstance(kind: item.kind, at: position, index: index)
            }
            state.isDragging = false
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
            if targeted { state.dragEntered() }
        }
    }
}

// MARK: - Empty Position Drop Zone

/// Labeled drop target shown at empty positions during a drag.
private struct EmptyPositionDropZone: View {
    @ObservedObject var state: OverlayEditorState
    let position: OverlayPosition
    let zoneWidth: CGFloat
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(isTargeted ? Color.aerial.opacity(0.2) : Color.white.opacity(0.05))
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isTargeted ? Color.aerial : Color.white.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                )
            Text(position.displayName)
                .font(.caption)
                .foregroundStyle(.white.opacity(isTargeted ? 0.9 : 0.5))
        }
        .frame(width: zoneWidth, height: 40)
        .dropDestination(for: OverlayDragData.self) { items, _ in
            guard let item = items.first else { return false }
            if let existingID = item.existingInstanceID {
                state.moveInstance(id: existingID, to: position, at: 0)
            } else {
                state.addInstance(kind: item.kind, at: position, index: 0)
            }
            state.isDragging = false
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
            if targeted { state.dragEntered() }
        }
    }
}

//
//  OverlayEditorState.swift
//  Aerial
//
//  Observable state for the overlay visual editor.
//  Manages the working layout copy, selection, and auto-saves to OverlayConfigManager.
//

import SwiftUI
import Combine

@MainActor
class OverlayEditorState: ObservableObject {

    // MARK: - Published State

    @Published var layout: OverlayLayout {
        didSet { autoSave() }
    }

    @Published var selectedInstanceID: UUID?
    @Published var previewScale: CGFloat = 0.75
    @Published var isDesktopMode: Bool = false
    @Published var screenUUID: String?
    @Published var dockInfo: DockInfo = .none
    @Published var showPalette: Bool = true
    @Published var draggingInstanceID: UUID?
    @Published var isDragging: Bool = false {
        didSet {
            if !isDragging {
                dragEndWork?.cancel(); dragEndWork = nil
                draggingInstanceID = nil
            }
        }
    }

    private var dragEndWork: DispatchWorkItem?

    /// Called when any drop destination detects the drag entering its area.
    func dragEntered() {
        dragEndWork?.cancel()
        dragEndWork = nil
        isDragging = true
    }

    /// Called when a drop destination detects the drag leaving. Debounced so that
    /// moving between parent and child zones doesn't flicker.
    func dragExited() {
        dragEndWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.isDragging = false }
        dragEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// URL of the video to show as preview background
    var previewVideoURL: URL?

    /// Callback set by the window controller; used by the view to close the editor.
    var onCloseEditor: (() -> Void)?

    /// Callback set by the window controller; moves editor window to the given screen.
    var onMoveToScreen: ((NSScreen) -> Void)?

    // MARK: - Initialization

    init(screenUUID: String? = nil, isDesktop: Bool = false) {
        self.screenUUID = screenUUID
        self.isDesktopMode = isDesktop
        self.layout = OverlayConfigManager.shared.layout(for: screenUUID, isDesktop: isDesktop)
        self.refreshDockInfo()
    }

    /// Re-detect the dock info for the currently targeted screen.
    func refreshDockInfo() {
        let screen: NSScreen?
        if let uuid = screenUUID {
            screen = NSScreen.getScreenByUuid(uuid) ?? NSScreen.main
        } else {
            screen = NSScreen.main
        }
        if let s = screen {
            dockInfo = DockInfo.detect(for: s)
        } else {
            dockInfo = .none
        }
    }

    // MARK: - Selected Instance

    func bindingForInstance(id: UUID) -> Binding<OverlayInstance>? {
        guard layout.instance(withID: id) != nil else { return nil }
        return Binding(
            get: { [weak self] in
                self?.layout.instance(withID: id) ?? OverlayInstance.defaultInstance(kind: .clock)
            },
            set: { [weak self] newValue in
                self?.layout.updateInstance(newValue)
            }
        )
    }

    // MARK: - Mutations

    func removeInstance(id: UUID) {
        layout.removeInstance(id: id)
        if selectedInstanceID == id {
            selectedInstanceID = nil
        }
    }

    func addInstance(kind: OverlayKind, at position: OverlayPosition, index: Int) {
        var instance = OverlayInstance.defaultInstance(kind: kind)
        instance.position = position
        layout.insertInstance(instance, at: index)
        selectedInstanceID = instance.id
    }

    func moveInstance(id: UUID, to position: OverlayPosition, at index: Int) {
        layout.moveInstance(id: id, to: position, at: index)
    }

    func select(_ id: UUID?) {
        guard selectedInstanceID != id else { return }
        selectedInstanceID = id
    }

    func deselect() {
        guard selectedInstanceID != nil else { return }
        selectedInstanceID = nil
    }

    // MARK: - Mode & Screen Switching

    func switchMode(isDesktop: Bool) {
        isDesktopMode = isDesktop
        layout = OverlayConfigManager.shared.layout(for: screenUUID, isDesktop: isDesktop)
        selectedInstanceID = nil
    }

    func switchScreen(uuid: String?) {
        screenUUID = uuid
        layout = OverlayConfigManager.shared.layout(for: screenUUID, isDesktop: isDesktopMode)
        selectedInstanceID = nil
        refreshDockInfo()

        // Move the editor window to the selected screen
        if let uuid = uuid, let screen = NSScreen.getScreenByUuid(uuid) {
            onMoveToScreen?(screen)
        }
    }

    // MARK: - Persistence

    private func autoSave() {
        OverlayConfigManager.shared.setLayout(layout, for: screenUUID, isDesktop: isDesktopMode)
    }
}

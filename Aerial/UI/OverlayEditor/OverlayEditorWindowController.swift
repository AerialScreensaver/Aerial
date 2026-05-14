//
//  OverlayEditorWindowController.swift
//  Aerial
//
//  Window controller for the visual overlay editor.
//  Creates a borderless, fixed-size window at a fraction of screen size.
//  Manages a floating NSPanel for the overlay palette.
//

import Cocoa
import SwiftUI
import Combine

private class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

class OverlayEditorWindowController: NSWindowController {

    private var editorState: OverlayEditorState?
    private var palettePanel: NSPanel?
    private var inspectorPanel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    convenience init(screenUUID: String? = nil, onScreen: NSScreen? = nil) {
        let state = OverlayEditorState(screenUUID: screenUUID)
        print("[OverlayEditor] state created, layout instances: \(state.layout.allInstances.count), screenUUID: \(screenUUID ?? "shared")")

        // Pick a video URL for the preview background. Use `localPathFor`
        // so My Videos / non-cacheable sources resolve to their source
        // directory rather than the global cache (where the file isn't),
        // and check `fileExists` to filter out live streams — those
        // report `isAvailableOffline = true` but have no local file.
        let usable: (AerialVideo) -> Bool = { video in
            guard video.isAvailableOffline else { return false }
            let path = VideoList.instance.localPathFor(video: video)
            return !path.isEmpty && FileManager.default.fileExists(atPath: path)
        }
        let urlFor: (AerialVideo) -> URL = { video in
            URL(fileURLWithPath: VideoList.instance.localPathFor(video: video))
        }

        if let video = PlaylistManager.shared.currentVideo(), usable(video) {
            state.previewVideoURL = urlFor(video)
        } else if let video = VideoList.instance.currentRotation().first(where: usable) {
            state.previewVideoURL = urlFor(video)
        } else if let video = VideoList.instance.videos.first(where: usable) {
            state.previewVideoURL = urlFor(video)
        }
        // If nothing usable on disk, previewVideoURL stays nil → black screen

        let editorView = OverlayEditorView(state: state)
        let hostingController = NSHostingController(rootView: editorView)
        hostingController.sizingOptions = []

        // Initial size = 75% of screen (matching screen aspect ratio)
        let screen = onScreen ?? NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.visibleFrame
        let initialScale: CGFloat = 0.75
        let width = screenFrame.width * initialScale
        let height = screenFrame.height * initialScale

        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        // Rounded corners
        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 12
            contentView.layer?.masksToBounds = true
            contentView.layer?.backgroundColor = NSColor.black.cgColor
        }

        self.init(window: window)
        self.editorState = state

        // Force the desired frame *after* contentViewController assignment,
        // which can trigger a layout pass that shrinks the window.
        let centeredFrame = NSRect(
            x: screenFrame.origin.x + (screenFrame.width - width) / 2,
            y: screenFrame.origin.y + (screenFrame.height - height) / 2,
            width: width,
            height: height
        )
        window.setFrame(centeredFrame, display: false)

        state.onCloseEditor = { [weak self] in self?.close() }
        state.onMoveToScreen = { [weak self] screen in self?.moveToScreen(screen) }

        // Subscribe to scale changes (async to avoid re-entrant SwiftUI layout)
        state.$previewScale
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] scale in
                DispatchQueue.main.async {
                    self?.resizeWindow(to: scale)
                }
            }
            .store(in: &cancellables)

        // Subscribe to palette visibility
        state.$showPalette
            .removeDuplicates()
            .sink { [weak self] show in
                if show {
                    self?.showPalettePanel()
                } else {
                    self?.hidePalettePanel()
                }
            }
            .store(in: &cancellables)

        // Inspector is always visible: instance settings when something is selected,
        // layout settings (margins, etc.) otherwise. The InspectorPanelView itself
        // observes selectedInstanceID and switches content automatically.

        // Reposition panels when editor window moves or resizes
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: window)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: window))
            .sink { [weak self] _ in
                self?.repositionPalettePanel()
                self?.repositionInspectorPanel()
            }
            .store(in: &cancellables)

        // Refresh dock info when screen layout changes (dock moved, autohide toggled, displays added/removed)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.editorState?.refreshDockInfo()
            }
            .store(in: &cancellables)

        print("[OverlayEditor] init complete, window: \(String(describing: self.window))")
    }

    func showEditorWindow() {
        print("[OverlayEditor] showEditorWindow, window=\(String(describing: window))")
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Show palette on open if state says so
        if editorState?.showPalette == true {
            showPalettePanel()
        }

        // Inspector is always shown alongside the editor.
        showInspectorPanel()
    }

    // MARK: - Window Resizing

    private func resizeWindow(to scale: CGFloat) {
        guard let window = window else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.visibleFrame

        let newWidth = screenFrame.width * scale
        let newHeight = screenFrame.height * scale

        let newX: CGFloat
        let newY: CGFloat

        if scale >= 1.0 {
            // Fill the screen (use the full visible frame)
            newX = screenFrame.origin.x
            newY = screenFrame.origin.y
        } else {
            // Center on screen
            newX = screenFrame.origin.x + (screenFrame.width - newWidth) / 2
            newY = screenFrame.origin.y + (screenFrame.height - newHeight) / 2
        }

        let newFrame = NSRect(x: newX, y: newY, width: newWidth, height: newHeight)
        window.setFrame(newFrame, display: true, animate: true)

        // Reposition panels relative to new window position
        repositionPalettePanel()
        repositionInspectorPanel()
    }

    // MARK: - Screen Switching

    private func moveToScreen(_ screen: NSScreen) {
        guard let window = window else { return }
        let scale = editorState?.previewScale ?? 0.75
        let screenFrame = screen.visibleFrame

        let newWidth = screenFrame.width * scale
        let newHeight = screenFrame.height * scale

        let newX: CGFloat
        let newY: CGFloat
        if scale >= 1.0 {
            newX = screenFrame.origin.x
            newY = screenFrame.origin.y
        } else {
            newX = screenFrame.origin.x + (screenFrame.width - newWidth) / 2
            newY = screenFrame.origin.y + (screenFrame.height - newHeight) / 2
        }

        let newFrame = NSRect(x: newX, y: newY, width: newWidth, height: newHeight)
        window.setFrame(newFrame, display: true, animate: true)

        repositionPalettePanel()
        repositionInspectorPanel()
    }

    // MARK: - Floating Palette Panel

    private func makePalettePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 580),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Overlays"
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating + 1
        panel.hasShadow = true

        let paletteView = OverlayPalette()
        let hosting = NSHostingController(rootView: paletteView)
        panel.contentViewController = hosting

        // Handle user closing the panel via its close button
        panel.delegate = self

        return panel
    }

    private func showPalettePanel() {
        if palettePanel == nil {
            palettePanel = makePalettePanel()
        }
        repositionPalettePanel()
        palettePanel?.orderFront(nil)
    }

    private func hidePalettePanel() {
        palettePanel?.orderOut(nil)
    }

    private func repositionPalettePanel() {
        guard let panel = palettePanel, let window = window else { return }
        let windowFrame = window.frame
        // Position near the left edge of the editor window, vertically centered
        let panelWidth: CGFloat = 280
        let panelHeight: CGFloat = 580
        let x = windowFrame.origin.x + 16
        let y = windowFrame.origin.y + (windowFrame.height - panelHeight) / 2
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }

    // MARK: - Floating Inspector Panel

    private func makeInspectorPanel() -> NSPanel {
        guard let state = editorState else { fatalError("editorState must exist") }
        // No .closable: the inspector is always visible while the editor is open.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 580),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Inspector"
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating + 1
        panel.hasShadow = true

        let inspectorView = InspectorPanelView(state: state)
        let hosting = NSHostingController(rootView: inspectorView)
        hosting.sizingOptions = []
        panel.contentViewController = hosting

        panel.delegate = self

        return panel
    }

    private func showInspectorPanel() {
        if inspectorPanel == nil {
            inspectorPanel = makeInspectorPanel()
        }
        repositionInspectorPanel()
        inspectorPanel?.makeKeyAndOrderFront(nil)
    }

    private func repositionInspectorPanel() {
        guard let panel = inspectorPanel, let window = window else { return }
        let windowFrame = window.frame
        let panelWidth: CGFloat = 300
        let panelHeight: CGFloat = 580
        let x = windowFrame.maxX - panelWidth - 16
        let y = windowFrame.origin.y + (windowFrame.height - panelHeight) / 2
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }

    // MARK: - Cleanup

    override func close() {
        inspectorPanel?.close()
        inspectorPanel = nil
        palettePanel?.close()
        palettePanel = nil
        cancellables.removeAll()
        super.close()
    }
}

// MARK: - NSWindowDelegate

extension OverlayEditorWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // If the palette panel's close button is clicked, update state
        if (notification.object as? NSPanel) === palettePanel {
            editorState?.showPalette = false
        }
    }
}

//
//  AerialConfigurationViewController.swift
//  AerialScreenSaverExtension
//
//  Configuration sheet view controller for the screensaver extension.
//

import AppKit

/// Configuration sheet view controller for the Aerial screensaver.
/// This provides the settings interface shown when clicking "Screen Saver Options...".
/// For now, this is a minimal placeholder that will eventually link to Aerial Companion settings.
@objc(AerialConfigurationViewController)
class AerialConfigurationViewController: NSViewController {

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        debugLog("AerialConfigurationViewController.init(nibName:bundle:)")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        debugLog("AerialConfigurationViewController.init(coder:)")
    }

    override func loadView() {
        debugLog("AerialConfigurationViewController.loadView()")

        // Create a simple placeholder view
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))

        // Add a label explaining that settings are in Aerial Companion
        let label = NSTextField(labelWithString: "Configure Aerial in the Aerial app.")
        label.font = NSFont.systemFont(ofSize: 14)
        label.textColor = NSColor.labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(label)

        // Add an "Open Aerial Companion" button
        let openButton = NSButton(title: "Open Aerial", target: self, action: #selector(openAerialCompanion))
        openButton.bezelStyle = .rounded
        openButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(openButton)

        // Add a close button
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}" // Escape key
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(closeButton)

        // Layout constraints
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            label.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 40),

            openButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            openButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 30),

            closeButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            closeButton.topAnchor.constraint(equalTo: openButton.bottomAnchor, constant: 20),
        ])

        self.view = containerView
        self.preferredContentSize = NSSize(width: 400, height: 200)

        debugLog("AerialConfigurationViewController.loadView() completed")
    }

    @objc private func openAerialCompanion() {
        debugLog("Opening Aerial Companion app")

        // Open the Aerial Companion app
        if let url = URL(string: "aerialcompanion://") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func closeSheet(_ sender: Any?) {
        debugLog("closeSheet()")
        if let window = self.view.window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            self.dismiss(nil)
        }
    }
}

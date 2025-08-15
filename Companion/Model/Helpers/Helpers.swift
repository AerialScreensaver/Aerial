//
//  Helpers.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 25/07/2020.
//

import Cocoa

struct Helpers {
    static func showErrorAlert(question: String, text: String, button: String = "OK") {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = text
        alert.alertStyle = .critical
        alert.icon = NSImage(named: NSImage.cautionName)
        alert.addButton(withTitle: button)
        alert.runModal()
    }
    
    static func showAlert(question: String, text: String, button1: String = "OK", button2: String = "Cancel") -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.icon = NSImage(named: NSImage.cautionName)
        alert.addButton(withTitle: button1)
        alert.addButton(withTitle: button2)
        
        alert.buttons[0].isHighlighted = true
        return alert.runModal() == NSApplication.ModalResponse.alertFirstButtonReturn
    }
    
    static var version: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
    
    static var supportPath: String {
        // Grab an array of Application Support paths
        let appSupportPaths = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory,
            .userDomainMask,
            true)

        if appSupportPaths.isEmpty {
            errorLog("FATAL : app support does not exist!")
            fatalError()
        }

        let appSupportDirectory = (appSupportPaths[0] as String).appending("/AerialUpdater")

        if FileManager.default.fileExists(atPath: appSupportDirectory) {
            return appSupportDirectory
        } else {
            debugLog("Creating app support directory...")

            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(atPath: appSupportDirectory,
                                                withIntermediateDirectories: true, attributes: nil)
                return appSupportDirectory
            } catch let error {
                errorLog("FATAL : Couldn't create app support directory in User directory: \(error)")
                fatalError()
            }
        }
    }

    
    // Launch a process through shell and capture/return output
    static func shell(launchPath: String, arguments: [String] = []) -> String? {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        task.launch()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)
        task.waitUntilExit()
        return output
    }
    
    static func getSymbol(_ named: String) -> NSImage? {
        if let imagePath = Bundle(for: MenuViewController.self).path(
            forResource: named,
            ofType: "pdf") {
            return NSImage(contentsOfFile: imagePath)
        }

        return nil
    }

}

extension NSImage {

    func tinting(with tintColor: NSColor) -> NSImage {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        
        return NSImage(size: size, flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            
            tintColor.set()
            context.clip(to: bounds, mask: cgImage)
            context.fill(bounds)
            
            return true
        }
    }
}

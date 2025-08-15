//
//  NextViewController.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 16/08/2020.
//

import Cocoa

class NextViewController: NSViewController {
    var windowController: FirstTimeSetupWindowController?

    @IBOutlet var nextButton: NSButton!
    @IBOutlet var previousButton: NSButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do view setup here.
    }
    
    func setNoPrev() {
        previousButton.isEnabled = false
        nextButton.isEnabled = true
        nextButton.title = "Next"
    }

    func setPrevNext() {
        previousButton.isEnabled = true
        nextButton.isEnabled = true
        nextButton.title = "Next"
    }

    func setClose() {
        previousButton.isEnabled = true
        nextButton.isEnabled = true
        nextButton.title = "Close"
    }
    
    @IBAction func previousButtonClick(_ sender: Any) {
        windowController!.previousAction()
    }

    @IBAction func nextButtonClick(_ sender: Any) {
        windowController!.nextAction()
    }
}

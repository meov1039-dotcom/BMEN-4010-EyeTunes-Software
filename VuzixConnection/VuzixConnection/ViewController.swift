//
//  ViewController.swift
//  VuzixConnection
//
//  Created by Alena Tucker on 1/8/26.
//

import UIKit
import UltraliteSDK

class ViewController: UltraliteBaseViewController {

    private var textHandle: Int?
    private var deviceListener: BondListener<[Ultralite]>?
    private var connectionListener: BondListener<Bool>?

    
    // Callback to SwiftUI
    var connectionUpdate: ((Bool) -> Void)?

    private var isConnectedListener: BondListener<Bool>?

    override func viewDidLoad() {
        super.viewDidLoad()

        displayTimeout = 60
        maximumNumTaps = 1

        // Poll until currentDevice becomes available
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { return }

            if let device = UltraliteManager.shared.currentDevice {
                print("👓 currentDevice detected")
                self.listenForConnection(device: device)
                timer.invalidate()
            }
        }
    }


    
    private func listenForConnection(device: Ultralite) {
        connectionListener = BondListener(listener: { [weak self] connected in
            print("Ultralite connected:", connected)
            self?.connectionUpdate?(connected)
        })

        device.isConnected.bind(listener: connectionListener!)
    }



    // Called from SwiftUI
    func showPickerFromSwiftUI() {
        showPairingPicker()
    }

    func showHelloWorld() {
        guard let device = UltraliteManager.shared.currentDevice else {
            print("No device available")
            return
        }

        print("Requesting control (this also sets layout)")

        let success = device.requestControl(
            layout: .canvas,
            timeout: displayTimeout,
            hideStatusBar: true
        )

        print("Control granted:", success)

        guard success else { return }

        // Give the glasses time to enter canvas mode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {

            print("Clearing canvas")
            device.canvas.clear()

            print("Creating text")
            self.textHandle = device.canvas.createText(
                text: "HELLO WORLD",
                textAlignment: .center,
                textColor: .white,
                anchor: .center,
                xOffset: 0,
                yOffset: 0
            )

            print("Committing")
            device.canvas.commit()
        }
    }
}

//
//  VuzixBridge.swift
//  EyeTunesFullConnection
//
//  Created by Alena Tucker on 4/13/26.
//

import Foundation
import Combine

class VuzixBridge: ObservableObject {
    weak var controller: ViewController? {
        didSet {
            // If we had a pending start, fire it now that controller is available
            if let pending = pendingStart, controller != nil {
                pendingStart = nil
                startLiveTranscription(speechRecognizer: pending)
            }
        }
    }

    // Queued if controller wasn't ready when start was called
    private var pendingStart: SpeechRecognizer?

    func showPicker() {
        controller?.showPickerFromSwiftUI()
    }

    func startLiveTranscription(speechRecognizer: SpeechRecognizer) {
        guard let controller = controller else {
            print("VuzixBridge: controller not ready, queuing start...")
            pendingStart = speechRecognizer
            return
        }
        pendingStart = nil
        controller.startLiveTranscription(speechRecognizer: speechRecognizer)
    }

    func stopLiveTranscription() {
        pendingStart = nil
        controller?.stopLiveTranscription()
    }
}

//
//  VuzixControllerView.swift
//  VuzixConnection
//
//  Created by Alena Tucker on 1/14/26.
//

import SwiftUI

struct VuzixControllerView: UIViewControllerRepresentable {
    
    class Coordinator {
        var controller: ViewController?
    }
    
    let coordinator = Coordinator()
    
    func makeCoordinator() -> Coordinator {
        coordinator
    }
    
    func makeUIViewController(context: Context) -> ViewController {
        let vc = ViewController()
        context.coordinator.controller = vc
        return vc
    }
    
    func updateUIViewController(_ uiViewController: ViewController, context: Context) {
        // No-op
    }
    
    
    // Expose UIKit methods to SwiftUI
    func showPicker() {
        coordinator.controller?.showPickerFromSwiftUI()
    }
    
    func startLiveTranscription() {
        coordinator.controller?.startLiveTranscription()
    }
    
    func stopLiveTranscription() {
        coordinator.controller?.stopLiveTranscription()
    }
    
}

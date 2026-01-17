//
//  VuzixControllerView.swift
//  VuzixConnection
//
//  Created by Alena Tucker on 1/14/26.
//

import SwiftUI
import UltraliteSDK

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

    // Expose methods to SwiftUI (connects SwiftUI to ViewController)
    func showHelloWorld() {
        coordinator.controller?.showHelloWorld()
    }

    func showPicker() {
        coordinator.controller?.showPickerFromSwiftUI()
    }
}

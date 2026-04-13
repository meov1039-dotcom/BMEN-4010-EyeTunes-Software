//
//  VuzixControllerView.swift
//  EyeTunesFullConnection
//
//  Created by Alena Tucker on 1/28/26.
//

import SwiftUI

struct VuzixControllerView: UIViewControllerRepresentable {
    let bridge: VuzixBridge

    func makeUIViewController(context: Context) -> ViewController {
        let vc = ViewController()
        bridge.controller = vc   // Register immediately, once, stably
        return vc
    }

    func updateUIViewController(_ uiViewController: ViewController, context: Context) {
        // Always keep bridge pointed at the live VC instance
        bridge.controller = uiViewController
    }
}

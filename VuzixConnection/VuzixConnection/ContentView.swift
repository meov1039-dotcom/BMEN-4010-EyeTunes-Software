//
//  ContentView.swift
//  VuzixConnection
//
//  Created by Alena Tucker on 1/8/26.
//

import SwiftUI

struct ContentView: View {

    @State private var vuzixView = VuzixControllerView()

    var body: some View {
        VStack(spacing: 20) {

            Text("Vuzix Controller")
                .font(.title)

            Button("Pair Glasses") {
                vuzixView.showPicker()
            }

            Button("Show Hello World") {
                vuzixView.showHelloWorld()
            }
            

            // Hidden UIKit controller
            vuzixView
                .frame(height: 0)
        }
        .padding()
    }
}



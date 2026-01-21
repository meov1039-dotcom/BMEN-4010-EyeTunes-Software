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

            Text("Vuzix Live Transcriber")
                .font(.title)

            Button("Pair Glasses") {
                vuzixView.showPicker()
            }

            //Button("Show Hello World") {
            //    vuzixView.showHelloWorld()
            //}

            Divider()

            Button("Start Live Transcription") {
                vuzixView.startLiveTranscription()
            }

            Button("Stop Transcription") {
                vuzixView.stopLiveTranscription()
            }

            
            // Hidden UIKit controller
            vuzixView
                .frame(height: 0)
        }
        .padding()
    }
}




//
//  ContentView.swift
//  EyeTunesFullConnection
//
//  Created by Alena Tucker on 1/28/26.
//

import SwiftUI
import Speech

struct ContentView: View {
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @StateObject private var audioReceiver = WiFiAudioReceiver()
    @StateObject private var vuzixBridge = VuzixBridge()   // stable across re-renders

    @State private var isListening = false
    @State private var isDisplayingOnGlasses = false

    var body: some View {
        VStack(spacing: 20) {
            Text("ESP32 → Phone → Vuzix")
                .font(.title)

            if !speechRecognizer.currentLatency.isEmpty {
                Text(speechRecognizer.currentLatency)
                    .font(.headline)
                    .foregroundColor(.blue)
            }

            ScrollView {
                Text(speechRecognizer.transcript.isEmpty
                     ? "Transcript will appear here..."
                     : speechRecognizer.transcript)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            .border(Color.gray)

            Button(action: { isListening ? stopListening() : startListening() }) {
                Label(isListening ? "Stop ESP32 Audio" : "Start ESP32 Audio",
                      systemImage: isListening ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title2)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(isListening ? Color.red : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }

            Divider()

            Button("Pair Glasses") {
                vuzixBridge.showPicker()
            }
            .buttonStyle(.bordered)

            Button(action: {
                if isDisplayingOnGlasses {
                    vuzixBridge.stopLiveTranscription()
                    isDisplayingOnGlasses = false
                } else {
                    vuzixBridge.startLiveTranscription(speechRecognizer: speechRecognizer)
                    isDisplayingOnGlasses = true
                }
            }) {
                Label(isDisplayingOnGlasses ? "Stop Glasses Display" : "Start Glasses Display",
                      systemImage: "eyeglasses")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(isDisplayingOnGlasses ? Color.orange : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }

            if !speechRecognizer.latencySummary.isEmpty {
                ScrollView {
                    Text(speechRecognizer.latencySummary)
                        .font(.system(.caption, design: .monospaced))
                        .padding()
                }
                .frame(height: 150)
                .border(Color.gray)
            }

            // Hidden bridge — always in the view hierarchy so the VC is never deallocated
            VuzixControllerView(bridge: vuzixBridge)
                .frame(width: 0, height: 0)
        }
        .padding()
        .onAppear { requestPermissions() }
    }

    func startListening() {
        isListening = true
        audioReceiver.startReceiving(speechRecognizer: speechRecognizer)
        Task { await speechRecognizer.startTranscribing() }
    }

    func stopListening() {
        isListening = false
        audioReceiver.stopReceiving()
        speechRecognizer.stopTranscribing()
    }

    func requestPermissions() {
        Task {
            let status = await SpeechRecognizer.requestSpeechAuthorization()
            if status != .authorized { print("Speech recognition not authorized") }
        }
    }
}

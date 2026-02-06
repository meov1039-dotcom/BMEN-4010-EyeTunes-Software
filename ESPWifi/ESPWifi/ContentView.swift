import SwiftUI
import Speech

struct ContentView: View {
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @StateObject private var audioReceiver = WiFiAudioReceiver()
    @State private var isListening = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("ESP32 Audio Transcription")
                .font(.title)
            
            // Live latency display
            Text(speechRecognizer.currentLatency)
                .font(.headline)
                .foregroundColor(.blue)
            
            // Transcript
            ScrollView {
                Text(speechRecognizer.transcript)
                    .padding()
            }
            .frame(height: 200)
            .border(Color.gray)
            
            // Start/Stop button
            Button(action: {
                if isListening {
                    stopListening()
                } else {
                    startListening()
                }
            }) {
                Text(isListening ? "Stop" : "Start")
                    .font(.title2)
                    .padding()
                    .background(isListening ? Color.red : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            
            // Final report
            if !speechRecognizer.latencySummary.isEmpty {
                ScrollView {
                    Text(speechRecognizer.latencySummary)
                        .font(.system(.caption, design: .monospaced))
                        .padding()
                }
                .frame(height: 150)
                .border(Color.gray)
            }
        }
        .padding()
        .onAppear {
            requestPermissions()
        }
    }
    
    func startListening() {
        isListening = true
        
        // Start UDP receiver
        audioReceiver.startReceiving(speechRecognizer: speechRecognizer)
        
        // Start speech recognition
        Task {
            await speechRecognizer.startTranscribing()
        }
    }
    
    func stopListening() {
        isListening = false
        
        // Stop everything
        audioReceiver.stopReceiving()
        speechRecognizer.stopTranscribing()
    }
    
    func requestPermissions() {
        Task {
            let status = await SpeechRecognizer.requestSpeechAuthorization()
            if status != .authorized {
                print("⚠️ Speech recognition not authorized")
            }
        }
    }
}

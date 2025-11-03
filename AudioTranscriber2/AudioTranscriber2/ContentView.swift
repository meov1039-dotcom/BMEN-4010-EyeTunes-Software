import SwiftUI
import Speech

struct ContentView: View {
    @State private var transcription: String = ""
    @State private var duration: Double?
    @State private var isTranscribing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("🎙️ Audio Transcriber")
                .font(.title)
                .bold()

            Button(action: startTranscription) {
                if isTranscribing {
                    ProgressView()
                } else {
                    Text("Start Transcription")
                }
            }
            .disabled(isTranscribing)
            .padding()
            .buttonStyle(.borderedProminent)

            if let duration = duration {
                Text("⏱️ Time taken: \(String(format: "%.2f", duration)) seconds")
                    .font(.headline)
            }

            if !transcription.isEmpty {
                ScrollView {
                    Text(transcription)
                        .padding()
                }
                .frame(maxHeight: 300)
            }

            if let errorMessage = errorMessage {
                Text("⚠️ \(errorMessage)")
                    .foregroundColor(.red)
            }

            Spacer()
        }
        .padding()
        .frame(width: 400, height: 500)
    }

    // MARK: - Transcription logic
    private func startTranscription() {
        guard let audioURL = Bundle.main.url(forResource: "Clip3", withExtension: "m4a") else {
            errorMessage = "Audio file not found."
            return
        }

        isTranscribing = true
        transcription = ""
        duration = nil
        errorMessage = nil

        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                guard authStatus == .authorized else {
                    self.errorMessage = "Speech recognition not authorized."
                    self.isTranscribing = false
                    return
                }
                self.transcribeAudioFile(url: audioURL)
            }
        }
    }

    private func transcribeAudioFile(url: URL) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            self.errorMessage = "Recognizer not available for locale."
            self.isTranscribing = false
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        let startTime = CFAbsoluteTimeGetCurrent()

        recognizer.recognitionTask(with: request) { result, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.errorMessage = "Error: \(error.localizedDescription)"
                    self.isTranscribing = false
                    print("⚠️ Transcription error: \(error.localizedDescription)")
                    return
                }

                if let result = result {
                    // Print partial transcription updates to the debugger
                    print("📝 Partial transcript: \(result.bestTranscription.formattedString)")

                    // Update UI
                    self.transcription = result.bestTranscription.formattedString

                    if result.isFinal {
                        let endTime = CFAbsoluteTimeGetCurrent()
                        self.duration = endTime - startTime
                        self.isTranscribing = false

                        // Final transcription output
                        print("\n✅ Final transcription:\n\(self.transcription)")
                        print("⏱️ Time taken: \(String(format: "%.2f", self.duration ?? 0)) seconds\n")
                    }
                }
            }
        }
    }
}


import SwiftUI
import Foundation
import AVFoundation
import Speech
import Observation
import CoreAudio

// MARK: - Main View
struct ContentView: View {
    @State private var isTranscribing = false
    @State private var speechRecognizer: SpeechRecognizer?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("🎙️ Audio Transcriber")
                .font(.title)
                .bold()

            // ✅ Transcript display
            ScrollView {
                Text(speechRecognizer?.transcript.isEmpty == true
                     ? "Say something..."
                     : (speechRecognizer?.transcript ?? ""))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.default, value: speechRecognizer?.transcript)
            }
            .frame(height: 200)
            .border(Color.gray.opacity(0.3))

            // ✅ Start/Stop button
            Button(action: {
                Task {
                    guard let recognizer = speechRecognizer else { return }
                    if isTranscribing {
                        await recognizer.stopTranscribing()
                    } else {
                        await recognizer.startTranscribing()
                    }
                    isTranscribing.toggle()
                }
            }) {
                Text(isTranscribing ? "🛑 Stop Transcription" : "🎤 Start Transcription")
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(isTranscribing ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .animation(.easeInOut, value: isTranscribing)
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
        .task {
            // ✅ Initialize the recognizer once the view appears
            do {
                speechRecognizer = try await SpeechRecognizer()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

// MARK: - Speech Recognizer Actor
@Observable
final class SpeechRecognizer {

    enum RecognizerError: Error {
        case nilRecognizer
        case notAuthorizedToRecognize
        case notPermittedToRecord
        case recognizerUnavailable

        var message: String {
            switch self {
            case .nilRecognizer: return "Can't initialize speech recognizer."
            case .notAuthorizedToRecognize: return "Not authorized to recognize speech."
            case .notPermittedToRecord: return "Not permitted to record audio."
            case .recognizerUnavailable: return "Speech recognizer is unavailable."
            }
        }
    }

    @MainActor var transcript: String = ""

    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer: SFSpeechRecognizer?

    // MARK: - Init
    init() async throws {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard recognizer != nil else { throw RecognizerError.nilRecognizer }

        guard await SFSpeechRecognizer.hasAuthorizationToRecognize() else {
            throw RecognizerError.notAuthorizedToRecognize
        }

        guard await Self.hasMicrophonePermission() else {
            throw RecognizerError.notPermittedToRecord
        }
    }
    
    

    // MARK: - Public Methods
    @MainActor
    func startTranscribing() async {
        await transcribe()
    }

    @MainActor
    func stopTranscribing() async {
        await reset()
    }

    @MainActor
    func clearTranscript() {
        transcript = ""
    }

    // MARK: - Core Transcription Logic
    private func transcribe() {
        guard let recognizer, recognizer.isAvailable else {
            transcribeError(RecognizerError.recognizerUnavailable)
            return
        }

        do {
            let (engine, request) = try Self.prepareEngine()
            audioEngine = engine
            self.request = request

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let result = result {
                    print("🗣️ Recognized partial: \(result.bestTranscription.formattedString)")
                }
                if let error = error {
                    print("❌ Recognition error: \(error.localizedDescription)")
                }
                self?.handleRecognition(result: result, error: error)
            }
        } catch {
            reset()
            transcribeError(error)
        }
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            updateTranscript(result.bestTranscription.formattedString)
        }

        if result?.isFinal == true || error != nil {
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
        }
    }

    private func reset() {
        task?.cancel()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        request = nil
        task = nil
    }

    // MARK: - Helpers
    private func updateTranscript(_ text: String) {
        Task { @MainActor in
            transcript = text
        }
    }

    private func transcribeError(_ error: Error) {
        let message: String
        if let e = error as? RecognizerError {
            message = e.message
        } else {
            message = error.localizedDescription
        }

        Task { @MainActor in
            transcript = "<< \(message) >>"
        }
    }
    
    private static func prepareEngine() throws -> (AVAudioEngine, SFSpeechAudioBufferRecognitionRequest) {
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        // Force recognizer format: 44.1 kHz, mono, float32
        guard let recognizerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "SpeechRecognizer", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create format"])
        }

        // Mixer node to resample and downmix if needed
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        engine.connect(inputNode, to: mixer, format: inputFormat)

        mixer.installTap(onBus: 0, bufferSize: 1024, format: recognizerFormat) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        try engine.start()

        print("🎤 Audio engine started: \(engine.isRunning)")
        print("🎧 Input device format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch → \(recognizerFormat.sampleRate) Hz mono")
        return (engine, request)
    }






    // MARK: - Permissions
    private static func hasMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}



// MARK: - SFSpeechRecognizer Extension
extension SFSpeechRecognizer {
    static func hasAuthorizationToRecognize() async -> Bool {
        await withCheckedContinuation { continuation in
            requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}


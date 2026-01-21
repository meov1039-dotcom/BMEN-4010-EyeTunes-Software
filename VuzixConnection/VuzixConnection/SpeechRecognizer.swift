//
//  SpeechRecognizer.swift
//  VuzixConnection
//
//  Created by Alena Tucker on 1/18/26.
//

import Foundation
import AVFoundation
import Speech
import Observation

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

    @MainActor
    func startTranscribing() async {
        transcribe()
    }

    @MainActor
    func stopTranscribing() async {
        reset()
    }

    // MARK: - Core logic

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
        let message = (error as? RecognizerError)?.message ?? error.localizedDescription

        Task { @MainActor in
            transcript = "<< \(message) >>"
        }
    }

    private static func prepareEngine()
    throws -> (AVAudioEngine, SFSpeechAudioBufferRecognitionRequest) {

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        print("Mic format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")

        // Install tap using the SAME format as hardware
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        try engine.start()

        print("Audio engine started: \(engine.isRunning)")

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

extension SFSpeechRecognizer {
    static func hasAuthorizationToRecognize() async -> Bool {
        await withCheckedContinuation { continuation in
            requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

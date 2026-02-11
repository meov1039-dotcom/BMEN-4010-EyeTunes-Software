//
//  ExternalAudioSpeechRecognizer.swift
//  EyeTunesFullConnection
//
//  Created by Alena Tucker on 1/28/26.
//



import Foundation
import Speech
import AVFoundation
import Observation // <--- The Modern Way

@Observable
final class SpeechRecognizer {

    // MARK: - UI Published Variables
    // No need for @Published anymore; @Observable handles it automatically
    @MainActor var transcript: String = ""
    @MainActor var currentLatency: String = ""

    // MARK: - Speech Engine Variables
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // MARK: - State Variables
    private var accumulatedText: String = ""
    private var liveText: String = ""
    private var isUserStopping = false
    
    // MARK: - Latency Variables
    private var latencyReadings: [Double] = []
    private var taskStartTime: Date?

    // MARK: - Init
    init() {
        // We don't need 'await' or 'throws' in init for this setup
    }
    
    // Latency Tracking
    private var endToEndLatencies: [Double] = []
    private var bufferTimestamps: [(esp32Time: UInt64, receiptTime: Date)] = []

    // MARK: - Start Recognition
    @MainActor
    func startTranscribing() async {
        // 1. Reset if needed
        if isUserStopping || accumulatedText.isEmpty {
            print("SpeechRecognizer: Starting New Session")
            resetSessionState()
            isUserStopping = false
        }
        
        // 2. Setup Request
        recognitionTask?.cancel()
        recognitionTask = nil
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true
        
        // 3. Check Engine
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            print("Speech recognizer unavailable")
            return
        }
        
        self.taskStartTime = Date()

        // 4. Start Task
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, taskError in
            guard let self = self else { return }

            var isFinal = false
            
            if let result = result {
                self.liveText = result.bestTranscription.formattedString
                
                // --- LATENCY MATH ---
                if let lastSegment = result.bestTranscription.segments.last {
                    let transcriptionTime = Date()
                    
                    // Map segment timestamp to our receipt buffer
                    if let receiptTime = self.getReceiptTime(for: lastSegment) {
                        let e2e = transcriptionTime.timeIntervalSince(receiptTime)
                        
                        if e2e > 0 && e2e < 10 { // Filter outliers
                            self.endToEndLatencies.append(e2e)
                            Task { @MainActor in
                                self.currentLatency = String(format: "%.0f ms", e2e * 1000)
                            }
                        }
                    }
                }
                
                // Update the transcript for the UI
                Task { @MainActor in
                    self.transcript = self.accumulatedText + " " + self.liveText
                }

                // Latency Math
                if let lastSegment = result.bestTranscription.segments.last,
                   let taskStart = self.taskStartTime {
                    let lag = Date().timeIntervalSince(taskStart) - lastSegment.timestamp
                    if lag > 0 { self.latencyReadings.append(lag) }
                }
                isFinal = result.isFinal
            }

            // Auto-Restart Logic (if not stopping)
            if taskError != nil || isFinal {
                if !self.isUserStopping {
                    Task { @MainActor in
                        if !self.liveText.isEmpty {
                            self.accumulatedText += " " + self.liveText
                            self.liveText = ""
                        }
                        self.recognitionTask = nil
                        self.recognitionRequest = nil
                        print("SpeechRecognizer: Auto-restarting...")
                        await self.startTranscribing()
                    }
                }
            }
        }
    }

    // MARK: - The Bridge: Feed Audio Here
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, esp32Timestamp: UInt64, receiptTime: Date) {
            // Store the time this specific chunk arrived
            bufferTimestamps.append((esp32Timestamp, receiptTime))
            
            // Keep buffer small (approx last 5 seconds of audio) to save memory
            if bufferTimestamps.count > 100 { bufferTimestamps.removeFirst() }
            
            recognitionRequest?.append(buffer)
        }
    
    // Helper to find which packet matches the transcribed word
        private func getReceiptTime(for segment: SFTranscriptionSegment) -> Date? {
            // Each packet/buffer is roughly 64ms of audio (1024 samples @ 16kHz)
            // If your ESP sends different sizes, adjust '0.064'
            let bufferIndex = Int(segment.timestamp / 0.064)
            
            if bufferIndex >= 0 && bufferIndex < bufferTimestamps.count {
                return bufferTimestamps[bufferIndex].receiptTime
            }
            return nil
        }

    // MARK: - Stop
    func stopTranscribing() {
        isUserStopping = true
        
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        let finalFullTranscript = accumulatedText + " " + liveText
        recognitionTask = nil
        recognitionRequest = nil

        // Print Report
        print("\n════════ FINAL REPORT ════════")
        print("Transcript: \(finalFullTranscript)")
        if !endToEndLatencies.isEmpty {
            let avg = endToEndLatencies.reduce(0, +) / Double(endToEndLatencies.count)
            print(String(format: "Average End-to-End Latency: %.0f ms", avg * 1000))
        }
        print("══════════════════════════════")
        
        // DO NOT RESET HERE. Wait for next start.
    }
    
    private func resetSessionState() {
        accumulatedText = ""
        liveText = ""
        latencyReadings.removeAll()
    }
}

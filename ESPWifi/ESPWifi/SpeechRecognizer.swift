import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class SpeechRecognizer: ObservableObject {

    // MARK: - UI Published Variables
    @Published var transcript: String = ""
    @Published var latencySummary: String = ""
    @Published var currentLatency: String = "" // NEW: Show live latency

    // MARK: - Speech Engine Variables
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // MARK: - State Variables
    private var accumulatedText: String = ""
    private var liveText: String = ""
    private var isUserStopping = false
    
    // MARK: - Latency Variables
    private var taskStartTime: Date?
    private var endToEndLatencies: [Double] = []
    private var bufferTimestamps: [(esp32Time: UInt64, receiptTime: Date, appendTime: Date)] = []
    
    // Used for the internal buffer/frame logic if needed
    private var totalFramesAppended = 0
    private var totalBuffersAppended = 0

    // MARK: - Init
    init() {
        print("✅ SpeechRecognizer initialized")
    }

    // MARK: - Start Recognition
    func startTranscribing() async {
        // 1. If we were previously stopped, this is a fresh start. Reset everything now.
        if isUserStopping || accumulatedText.isEmpty {
            print("🟢 Starting New Session")
            resetSessionState()
            isUserStopping = false
        }
        
        // 2. Cancel existing (just in case)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        
        // 3. Create Request
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.requiresOnDeviceRecognition = true
        
        // 4. Check Engine Availability
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            print("❌ Speech recognizer unavailable")
            return
        }
        
        // 5. Mark Time for Latency Math
        self.taskStartTime = Date()
        
        // 6. Assign to property
        self.recognitionRequest = newRequest
        
        // 7. Start Task
        recognitionTask = speechRecognizer.recognitionTask(with: newRequest) { [weak self] result, taskError in
            guard let self = self else { return }

            var isFinal = false
            
            if let result = result {
                self.liveText = result.bestTranscription.formattedString
                
                DispatchQueue.main.async {
                    self.transcript = self.accumulatedText + " " + self.liveText
                }

                // Calculate end-to-end latency
                if let lastSegment = result.bestTranscription.segments.last {
                    let transcriptionTime = Date()
                    
                    if let (_, receiptTime) = self.findTimestampForSegment(lastSegment) {
                        let endToEndLatency = transcriptionTime.timeIntervalSince(receiptTime)
                        
                        if endToEndLatency > 0 && endToEndLatency < 10 {
                            self.endToEndLatencies.append(endToEndLatency)
                            
                            DispatchQueue.main.async {
                                self.currentLatency = String(format: "🌐 Latency: %.0f ms", endToEndLatency * 1000)
                            }
                            
                            if self.endToEndLatencies.count % 10 == 0 {
                                print(String(format: "📊 End-to-End: %.0f ms | Word: '%@'",
                                           endToEndLatency * 1000,
                                           lastSegment.substring))
                            }
                        }
                    }
                }
                
                isFinal = result.isFinal
            }

            if taskError != nil || isFinal {
                if !self.isUserStopping {
                    DispatchQueue.main.async {
                        if !self.liveText.isEmpty {
                            self.accumulatedText += " " + self.liveText
                            self.liveText = ""
                        }
                        
                        self.recognitionTask?.cancel()
                        self.recognitionTask = nil
                        self.recognitionRequest = nil
                        
                        print("🔄 Auto-restarting (preserving text)...")
                        Task {
                            await self.startTranscribing()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Append Audio with Timestamp
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer,
                          esp32Timestamp: UInt64,
                          receiptTime: Date) {
        guard let recognitionRequest = recognitionRequest else { return }
        
        let appendTime = Date()
        
        bufferTimestamps.append((esp32Timestamp, receiptTime, appendTime))
        
        if bufferTimestamps.count > 80 {
            bufferTimestamps.removeFirst()
        }
        
        recognitionRequest.append(buffer)
        totalFramesAppended += Int(buffer.frameLength)
        totalBuffersAppended += 1
    }

    // MARK: - Find Timestamp for Segment
    private func findTimestampForSegment(_ segment: SFTranscriptionSegment) -> (UInt64, Date)? {
        let segmentAudioTime = segment.timestamp
        let bufferIndex = Int(segmentAudioTime / 0.064)
        
        if bufferIndex >= 0 && bufferIndex < bufferTimestamps.count {
            let bufferInfo = bufferTimestamps[bufferIndex]
            return (bufferInfo.esp32Time, bufferInfo.receiptTime)
        }
        
        return nil
    }

    // MARK: - Stop & Summarize
    func stopTranscribing() {
        isUserStopping = true
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        let finalFullTranscript = accumulatedText + " " + liveText
        
        recognitionTask = nil
        recognitionRequest = nil

        guard !finalFullTranscript.isEmpty else {
            print("🛑 Stopped — No transcript generated yet.")
            return
        }

        var lines: [String] = []
        lines.append("\n════════════ FINAL REPORT ════════════")
        
        if !endToEndLatencies.isEmpty {
            let avgEndToEnd = endToEndLatencies.reduce(0, +) / Double(endToEndLatencies.count)
            let minEndToEnd = endToEndLatencies.min() ?? 0
            let maxEndToEnd = endToEndLatencies.max() ?? 0
            
            lines.append("🌐 END-TO-END LATENCY (ESP32 → Transcription):")
            lines.append(String(format: "   AVG: %.0f ms", avgEndToEnd * 1000))
            lines.append(String(format: "   Min: %.0f ms | Max: %.0f ms", minEndToEnd * 1000, maxEndToEnd * 1000))
            lines.append(String(format: "   Samples: %d", endToEndLatencies.count))
        } else {
            lines.append("⚡️ Latency: No valid readings.")
        }

        lines.append("──────────────────────────────────────")
        lines.append("📝 FULL TRANSCRIPT:")
        lines.append(finalFullTranscript)
        lines.append("══════════════════════════════════════")
        
        let summary = lines.joined(separator: "\n")
        latencySummary = summary
        print(summary)
    }
    
    private func resetSessionState() {
        accumulatedText = ""
        liveText = ""
        endToEndLatencies.removeAll()
        bufferTimestamps.removeAll()
        totalFramesAppended = 0
        totalBuffersAppended = 0
    }

    // MARK: - Auth Helper
    static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

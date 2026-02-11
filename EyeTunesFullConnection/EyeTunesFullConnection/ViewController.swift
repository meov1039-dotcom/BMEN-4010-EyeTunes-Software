//
//  ViewController.swift
//  EyeTunesFullConnection
//
//  Created by Alena Tucker on 1/28/26.
//

import UIKit
import UltraliteSDK

class ViewController: UltraliteBaseViewController {

    private var connectionListener: BondListener<Bool>?
    private var speechRecognizer: SpeechRecognizer?
    private var updateTimer: Timer?
    private var udpReceiver = UDPAudioReceiver()
    
    private var textBlockIds: [Int] = []  // Store IDs of created text blocks
    private var captionLines: [String] = []
    private var fullCaptionText = ""
    private let maxVisibleLines = 2   // Only 1-2 lines like real captions
    private let charsPerLine = 35     // Fewer chars for bigger text
    
    // Latency tracking
    private var lastTranscriptLength = 0
    private var latencyMeasurements: [TimeInterval] = []
    
    // Flag to prevent double initialization
    private var isTranscriptionActive = false

    override func viewDidLoad() {
        super.viewDidLoad()
        displayTimeout = 120
        maximumNumTaps = 1
        
        // Listen for device connection
        startConnectionListener()
    }
    
    deinit {
        stopLiveTranscription()
        connectionListener = nil
    }

    // MARK: - Device Connection
    private func startConnectionListener() {
        guard UltraliteManager.shared.currentDevice != nil else {
            print("No device found at startup")
            return
        }
        
        connectionListener = BondListener { [weak self] connected in
            //print("Ultralite connected:", connected)
            if !connected {
                self?.stopLiveTranscription()
            }
        }
        
        UltraliteManager.shared.currentDevice?.isConnected.bind(listener: connectionListener!)
    }

    // MARK: - Pairing
    func showPickerFromSwiftUI() {
        showPairingPicker()
    }

    // MARK: - Live Transcription
        func startLiveTranscription() {
            // Prevent double initialization
            guard !isTranscriptionActive else {
                print("Transcription already active, ignoring duplicate call")
                return
            }
            
            guard let device = UltraliteManager.shared.currentDevice,
                  device.isConnected.value else {
                print("Device not connected")
                showError("Device not connected. Please pair your Vuzix Z100 glasses first.")
                return
            }

            print("Device connected, using CANVAS layout for captions")
            
            // Release any previous control
            device.releaseControl()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                
                // Use CANVAS layout
                let success = device.requestControl(layout: .canvas,
                                                    timeout: self.displayTimeout,
                                                    hideStatusBar: true)
                guard success else {
                    print("Failed to get canvas control")
                    self.showError("Failed to initialize display. Please try again.")
                    return
                }

                // Mark as active
                self.isTranscriptionActive = true
                
                // Setup canvas
                device.canvas.clear(shouldClearBackground: true)
                self.createCaptionTextBlocks()
                device.canvas.commit(callback: nil)
                print("Text layout ready for captions")

                // Start Speech and UDP
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self, self.isTranscriptionActive else { return }
                    
                    self.startSpeechAndUDP() // <--- NEW HELPER FUNCTION
                }
            }
        }
    
    private func startSpeechAndUDP() {
            Task {
                do {
                    print("Initializing SpeechRecognizer")
                    speechRecognizer = SpeechRecognizer() // No 'try await' needed for the new init
                    
                    guard self.isTranscriptionActive, let recognizer = speechRecognizer else { return }
                    
                    // 1. Start the Speech Engine (It will wait for audio)
                    print("Starting Speech Engine...")
                    await recognizer.startTranscribing()
                    
                    // 2. Start UDP Listener (Feeds audio to the engine)
                    print("Starting UDP Listener...")
                    udpReceiver.startListening(feeding: recognizer)
                    
                    print("✅ System Running: UDP Audio -> Speech -> Glasses")

                    // 3. Start Display Timer
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        self.updateTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
                            guard let self = self,
                                  self.isTranscriptionActive,
                                  let recognizer = self.speechRecognizer else {
                                timer.invalidate()
                                return
                            }
                            self.updateCaptionDisplay(recognizer.transcript)
                        }
                    }
                }
            }
        }
    
    private func createCaptionTextBlocks() {
        guard let device = UltraliteManager.shared.currentDevice else { return }
        
        // Create text blocks at the bottom of the screen
        textBlockIds = []
        
        // Z100 display height is typically around 360 pixels
        // Start text blocks near the bottom
        let startYPosition = 300  // Near bottom, adjust if needed
        let lineHeight = 40       // Taller for bigger text
        
        for i in 0..<maxVisibleLines {
            if let textId = device.canvas.createText(
                text: "",
                textAlignment: .center,  // Center aligned like real captions
                textColor: .white,
                anchor: .topLeft,
                xOffset: 10,
                yOffset: startYPosition + (i * lineHeight),
                isVisible: true,
                width: 620,  // Full width
                height: lineHeight,
                wrapMode: .truncate
            ) {
                textBlockIds.append(textId)
            }
        }
    }

    private func startSpeechRecognition() {
        guard isTranscriptionActive else { return }

        Task {
            do {
                print("Starting ESP32 audio listener")
                speechRecognizer = SpeechRecognizer()
                try await speechRecognizer?.startTranscribing()

                await MainActor.run {
                    self.updateTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
                        guard let self = self,
                              self.isTranscriptionActive,
                              let recognizer = self.speechRecognizer else {
                            timer.invalidate()
                            return
                        }

                        self.updateCaptionDisplay(recognizer.transcript)
                    }
                }

            } catch {
                print("Speech error:", error.localizedDescription)
            }
        }
    }


    func stopLiveTranscription() {
            guard isTranscriptionActive else { return }
            
            print("Stopping live transcription...")
            isTranscriptionActive = false
            
            // Stop Timer
            updateTimer?.invalidate()
            updateTimer = nil
            
            // Stop UDP
            udpReceiver.stopListening()
            
            // Stop Speech
            Task {
                await speechRecognizer?.stopTranscribing()
                speechRecognizer = nil // Clean up
            }

            // Clear Display (Existing logic...)
            Task { @MainActor in
                self.fullCaptionText = ""
                self.captionLines = []
                
                if let device = UltraliteManager.shared.currentDevice {
                    for textId in self.textBlockIds {
                        device.canvas.removeText(id: textId)
                    }
                    self.textBlockIds = []
                    device.canvas.commit(callback: nil)
                    device.releaseControl()
                }
                print("Live transcription stopped")
            }
        }

    // MARK: - Caption Display
    private func updateCaptionDisplay(_ transcript: String) {
        guard let device = UltraliteManager.shared.currentDevice,
              isTranscriptionActive,
              !transcript.isEmpty,
              !textBlockIds.isEmpty else { return }

        // Check if we have new content
        guard transcript.count > fullCaptionText.count else { return }
        
        // Start latency measurement
        let displayStartTime = CFAbsoluteTimeGetCurrent()
        
        // Update full text
        fullCaptionText = transcript
        
        // Wrap text into lines
        captionLines = wrapTextIntoLines(fullCaptionText, maxCharsPerLine: charsPerLine)
        
        // Get the most recent lines (scrolling effect)
        let visibleLines = Array(captionLines.suffix(maxVisibleLines))
        
        // Update each text block
        for (index, textId) in textBlockIds.enumerated() {
            let lineText = index < visibleLines.count ? visibleLines[index] : ""
            device.canvas.updateText(text: lineText, id: textId)
        }
        
        device.canvas.commit { [weak self] in
            // Measure latency after commit completes
            let displayEndTime = CFAbsoluteTimeGetCurrent()
            let latency = (displayEndTime - displayStartTime) * 1000 // Convert to milliseconds
            
            self?.recordLatency(latency)
        }
    }
    
    // MARK: - Latency Tracking
    private func recordLatency(_ latency: TimeInterval) {
        latencyMeasurements.append(latency)
        
        // Calculate statistics
        let avgLatency = latencyMeasurements.reduce(0, +) / Double(latencyMeasurements.count)
        let minLatency = latencyMeasurements.min() ?? 0
        let maxLatency = latencyMeasurements.max() ?? 0
        let stdDev = calculateStandardDeviation(values: latencyMeasurements, mean: avgLatency)
        
        print("LATENCY: \(String(format: "%.1f", latency))ms | AVG: \(String(format: "%.1f", avgLatency))ms | StdDev: \(String(format: "%.1f", stdDev))ms | MIN: \(String(format: "%.1f", minLatency))ms | MAX: \(String(format: "%.1f", maxLatency))ms | Samples: \(latencyMeasurements.count)")
        
        // Keep only last 100 measurements to prevent memory growth
        if latencyMeasurements.count > 100 {
            latencyMeasurements.removeFirst()
        }
    }
    
    private func calculateStandardDeviation(values: [TimeInterval], mean: TimeInterval) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return sqrt(variance)
    }
    
    
    // MARK: - Text Wrapping Helper
    private func wrapTextIntoLines(_ text: String, maxCharsPerLine: Int) -> [String] {
        var lines: [String] = []
        var currentLine = ""
        
        let words = text.split(separator: " ")
        
        for word in words {
            let wordStr = String(word)
            let testLine = currentLine.isEmpty ? wordStr : currentLine + " " + wordStr
            
            if testLine.count <= maxCharsPerLine {
                currentLine = testLine
            } else {
                // Line is full, start new line
                if !currentLine.isEmpty {
                    lines.append(currentLine)
                }
                
                // If single word is longer than max, split it
                if wordStr.count > maxCharsPerLine {
                    var remainingWord = wordStr
                    while remainingWord.count > maxCharsPerLine {
                        let chunk = String(remainingWord.prefix(maxCharsPerLine))
                        lines.append(chunk)
                        remainingWord = String(remainingWord.dropFirst(maxCharsPerLine))
                    }
                    currentLine = remainingWord
                } else {
                    currentLine = wordStr
                }
            }
        }
        
        // Add final line
        if !currentLine.isEmpty {
            lines.append(currentLine)
        }
        
        return lines
    }
    
    // MARK: - Error Handling
    private func showError(_ message: String) {
        isTranscriptionActive = false
        
        let alert = UIAlertController(title: "Error",
                                     message: message,
                                     preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

import UIKit
import UltraliteSDK

class ViewController: UltraliteBaseViewController {

    private var connectionListener: BondListener<Bool>?
    // No longer owns SpeechRecognizer — it's injected
    private weak var speechRecognizer: SpeechRecognizer?
    private var updateTimer: Timer?

    private var textBlockIds: [Int] = []
    private var captionLines: [String] = []
    private var fullCaptionText = ""
    private let maxVisibleLines = 2
    private let charsPerLine = 35

    private var lastTranscriptLength = 0
    private var latencyMeasurements: [TimeInterval] = []
    private var isTranscriptionActive = false

    override func viewDidLoad() {
        super.viewDidLoad()
        displayTimeout = 120
        maximumNumTaps = 1
        startConnectionListener()
    }

    deinit {
        stopLiveTranscription()
        connectionListener = nil
    }

    // MARK: - Device Connection
    private func startConnectionListener() {
        guard UltraliteManager.shared.currentDevice != nil else { return }

        connectionListener = BondListener { [weak self] connected in
            if !connected { self?.stopLiveTranscription() }
        }
        UltraliteManager.shared.currentDevice?.isConnected.bind(listener: connectionListener!)
    }

    func showPickerFromSwiftUI() { showPairingPicker() }

    // MARK: - Live Transcription (injected recognizer)
    func startLiveTranscription(speechRecognizer: SpeechRecognizer) {
        guard !isTranscriptionActive else {
            print("Already active, ignoring duplicate start")
            return
        }

        guard let device = UltraliteManager.shared.currentDevice,
              device.isConnected.value else {
            showError("Device not connected. Please pair your Vuzix Z100 glasses first.")
            return
        }

        self.speechRecognizer = speechRecognizer
        print("speechRecognizer injected: \(speechRecognizer)")

        device.releaseControl()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }

            let success = device.requestControl(layout: .canvas,
                                                timeout: self.displayTimeout,
                                                hideStatusBar: true)
            guard success else {
                self.showError("Failed to initialize display. Please try again.")
                return
            }

            self.isTranscriptionActive = true
            device.canvas.clear(shouldClearBackground: true)
            self.createCaptionTextBlocks()

            // Commit canvas setup, then wait for confirmation before starting timer
            device.canvas.commit { [weak self] in
                guard let self = self, self.isTranscriptionActive else { return }
                print("Canvas ready — starting display timer")
                DispatchQueue.main.async {
                    self.startDisplayTimer()
                }
            }
        }
    }

    private func startDisplayTimer() {
        // Always invalidate first to avoid duplicates
        updateTimer?.invalidate()
        updateTimer = nil
        
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // If transcription was stopped externally, clean up
            guard self.isTranscriptionActive else {
                self.updateTimer?.invalidate()
                self.updateTimer = nil
                return
            }
            
            guard let recognizer = self.speechRecognizer else {
                print("speechRecognizer is nil in timer — did the bridge lose it?")
                return
            }
            
            self.updateCaptionDisplay(recognizer.transcript)
        }
    }

    func stopLiveTranscription() {
        guard isTranscriptionActive else { return }

        isTranscriptionActive = false
        updateTimer?.invalidate()
        updateTimer = nil
        // NOTE: We do NOT stop speechRecognizer here — ContentView owns that lifecycle

        fullCaptionText = ""
        captionLines = []
        lastTranscriptLength = 0
        latencyMeasurements = []

        if let device = UltraliteManager.shared.currentDevice {
            for textId in textBlockIds { device.canvas.removeText(id: textId) }
            textBlockIds = []
            device.canvas.commit(callback: nil)
            device.releaseControl()
        }
    }

    // MARK: - Caption Display (unchanged from your original)
    private func createCaptionTextBlocks() {
        guard let device = UltraliteManager.shared.currentDevice else { return }
        textBlockIds = []
        let startYPosition = 300
        let lineHeight = 40

        for i in 0..<maxVisibleLines {
            if let textId = device.canvas.createText(
                text: "",
                textAlignment: .center,
                textColor: .white,
                anchor: .topLeft,
                xOffset: 10,
                yOffset: startYPosition + (i * lineHeight),
                isVisible: true,
                width: 620,
                height: lineHeight,
                wrapMode: .truncate
            ) {
                textBlockIds.append(textId)
            }
        }
    }

    private func updateCaptionDisplay(_ transcript: String) {
        guard let device = UltraliteManager.shared.currentDevice,
              isTranscriptionActive,
              !transcript.trimmingCharacters(in: .whitespaces).isEmpty,
              !textBlockIds.isEmpty else { return }

        // CHANGED: use != instead of > so restarted sessions still update
        guard transcript != fullCaptionText else { return }

        let displayStartTime = CFAbsoluteTimeGetCurrent()
        fullCaptionText = transcript
        captionLines = wrapTextIntoLines(fullCaptionText, maxCharsPerLine: charsPerLine)
        let visibleLines = Array(captionLines.suffix(maxVisibleLines))

        for (index, textId) in textBlockIds.enumerated() {
            let lineText = index < visibleLines.count ? visibleLines[index] : ""
            device.canvas.updateText(text: lineText, id: textId)
        }

        device.canvas.commit { [weak self] in
            let latency = (CFAbsoluteTimeGetCurrent() - displayStartTime) * 1000
            self?.recordLatency(latency)
        }
    }

    private func recordLatency(_ latency: TimeInterval) {
        latencyMeasurements.append(latency)
        if latencyMeasurements.count > 100 { latencyMeasurements.removeFirst() }

        let avg = latencyMeasurements.reduce(0, +) / Double(latencyMeasurements.count)
        let std = calculateStandardDeviation(values: latencyMeasurements, mean: avg)
        let mn = latencyMeasurements.min() ?? 0
        let mx = latencyMeasurements.max() ?? 0
        print(String(format: "DISPLAY LATENCY: %.1fms | AVG: %.1fms | StdDev: %.1fms | MIN: %.1fms | MAX: %.1fms",
                     latency, avg, std, mn, mx))
    }

    private func calculateStandardDeviation(values: [TimeInterval], mean: TimeInterval) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        return sqrt(values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count))
    }

    private func wrapTextIntoLines(_ text: String, maxCharsPerLine: Int) -> [String] {
        var lines: [String] = []
        var currentLine = ""
        for word in text.split(separator: " ").map(String.init) {
            let test = currentLine.isEmpty ? word : currentLine + " " + word
            if test.count <= maxCharsPerLine {
                currentLine = test
            } else {
                if !currentLine.isEmpty { lines.append(currentLine) }
                var rem = word
                while rem.count > maxCharsPerLine {
                    lines.append(String(rem.prefix(maxCharsPerLine)))
                    rem = String(rem.dropFirst(maxCharsPerLine))
                }
                currentLine = rem
            }
        }
        if !currentLine.isEmpty { lines.append(currentLine) }
        return lines
    }

    private func showError(_ message: String) {
        isTranscriptionActive = false
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

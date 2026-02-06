import Foundation
import Network
import AVFoundation
import Combine

class WiFiAudioReceiver: ObservableObject {
    @Published var isReceiving = false
    
    private var udpListener: NWListener?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var speechRecognizer: SpeechRecognizer?
    
    private let port: NWEndpoint.Port = 12345
    
    // Track packet receipt times
    private var packetReceiptTimes: [UInt64: Date] = [:]
    
    // MARK: - Start Receiving
    func startReceiving(speechRecognizer: SpeechRecognizer) {
        self.speechRecognizer = speechRecognizer
        setupAudioEngine()
        setupUDPListener()
    }
    
    // MARK: - Stop Receiving
    func stopReceiving() {
        udpListener?.cancel()
        udpListener = nil
        
        audioEngine?.stop()
        playerNode?.stop()
        
        isReceiving = false
        print("🛑 UDP Listener stopped")
    }
    
    // MARK: - Setup Audio Engine
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        
        guard let audioEngine = audioEngine,
              let playerNode = playerNode else {
            print("❌ Failed to create audio engine")
            return
        }
        
        audioEngine.attach(playerNode)
        
        // Audio format: 16kHz, 1 channel (mono), 16-bit
        let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )
        
        guard let format = audioFormat else {
            print("❌ Failed to create audio format")
            return
        }
        
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        
        do {
            try audioEngine.start()
            playerNode.play()
            print("✅ Audio Engine started")
        } catch {
            print("❌ Failed to start audio engine: \(error)")
        }
    }
    
    // MARK: - Setup UDP Listener
    private func setupUDPListener() {
        do {
            udpListener = try NWListener(using: .udp, on: port)
            
            udpListener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            udpListener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("✅ UDP Listener ready on port \(self.port)")
                case .failed(let error):
                    print("❌ UDP Listener failed: \(error)")
                case .cancelled:
                    print("⚠️ UDP Listener cancelled")
                default:
                    break
                }
            }
            
            udpListener?.start(queue: .main)
            isReceiving = true
            
        } catch {
            print("❌ Failed to create UDP listener: \(error)")
        }
    }
    
    // MARK: - Handle Connection
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        
        func receiveNextMessage() {
            connection.receiveMessage { [weak self] data, context, isComplete, error in
                guard let self = self else { return }
                
                if let data = data, !data.isEmpty {
                    // Record receipt time immediately
                    let receiptTime = Date()
                    
                    // Extract timestamp and audio data
                    self.processPacket(data: data, receiptTime: receiptTime)
                }
                
                if let error = error {
                    print("❌ Receive error: \(error)")
                } else {
                    receiveNextMessage()
                }
            }
        }
        
        receiveNextMessage()
    }
    
    // MARK: - Process Packet
    private func processPacket(data: Data, receiptTime: Date) {
        // Extract ESP32 timestamp from packet header
        guard data.count >= 8 else {
            print("⚠️ Packet too small: \(data.count) bytes")
            return
        }
        
        // First 8 bytes = uint64 timestamp in microseconds
        let timestampBytes = data.prefix(8)
        let esp32Timestamp = timestampBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
        
        // Store receipt time for this packet
        packetReceiptTimes[esp32Timestamp] = receiptTime
        
        // Clean up old entries (keep only last 1000)
        if packetReceiptTimes.count > 1000 {
            let sortedKeys = packetReceiptTimes.keys.sorted()
            for key in sortedKeys.prefix(packetReceiptTimes.count - 1000) {
                packetReceiptTimes.removeValue(forKey: key)
            }
        }
        
        // Log occasionally to verify timestamps
        if packetReceiptTimes.count % 100 == 0 {
            print("📦 Received packet \(packetReceiptTimes.count) - ESP timestamp: \(esp32Timestamp) µs")
        }
        
        // Rest of the data is audio (starting from byte 8)
        let audioData = data.dropFirst(8)
        
        // Convert to PCM buffer
        if let pcmBuffer = self.dataToPCMBuffer(audioData) {
            // Send to speech recognizer with timestamp
            speechRecognizer?.appendAudioBuffer(pcmBuffer,
                                               esp32Timestamp: esp32Timestamp,
                                               receiptTime: receiptTime)
            
            // Also play through speakers (optional)
            playerNode?.scheduleBuffer(pcmBuffer)
        }
    }
    
    // MARK: - Convert Data to PCM Buffer
    private func dataToPCMBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        // Audio format: 16kHz, 1 channel, 16-bit PCM
        guard let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            print("❌ Failed to create audio format")
            return nil
        }
        
        // Calculate frame count (2 bytes per sample for 16-bit audio)
        let frameCount = UInt32(data.count / 2)
        
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: frameCount
        ) else {
            print("❌ Failed to create PCM buffer")
            return nil
        }
        
        pcmBuffer.frameLength = frameCount
        
        // Copy audio data into buffer
        guard let channelData = pcmBuffer.int16ChannelData else {
            print("❌ No channel data in buffer")
            return nil
        }
        
        data.withUnsafeBytes { (bufferPointer: UnsafeRawBufferPointer) in
            guard let baseAddress = bufferPointer.baseAddress else { return }
            let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
            channelData[0].update(from: int16Pointer, count: Int(frameCount))
        }
        
        return pcmBuffer
    }
}

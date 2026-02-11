//
//  UDPAudioReceiver.swift
//  VuzixConnection
//
//  Created by Alena Tucker on 1/28/26.
//

import Foundation
import Network
import AVFoundation
import Observation

@Observable
final class UDPAudioReceiver {
    
    // MARK: - Properties
    var isReceiving = false
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 12345
    
    // Reference to the Speech Engine
    private weak var speechRecognizer: SpeechRecognizer?
    private let processingQueue = DispatchQueue(label: "udp.processing.queue")

    func triggerLocalNetworkPrompt() {
        let connection = NWConnection(host: "192.168.1.255", port: 12345, using: .udp)
        connection.start(queue: .main)
        connection.send(content: "ping".data(using: .utf8), completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
    
    
    // MARK: - Start Listening
    func startListening(feeding recognizer: SpeechRecognizer) {
        self.speechRecognizer = recognizer
        
        // 1. Setup Listener using the exact default parameters that worked before
        do {
            self.listener = try NWListener(using: .udp, on: port)
            
            // 2. Handle New Connections (The ESP32 "Connection")
            self.listener?.newConnectionHandler = { [weak self] connection in
                print("Connection Detected from \(connection.endpoint)")
                self?.handleConnection(connection)
            }
            
            // 3. Handle State Changes
            self.listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("UDP Listener Ready on Port 12345")
                    Task { @MainActor in self.isReceiving = true }
                case .failed(let error):
                    print("UDP Listener Failed: \(error)")
                    Task { @MainActor in self.isReceiving = false }
                case .cancelled:
                    print("UDP Listener Cancelled")
                    Task { @MainActor in self.isReceiving = false }
                default:
                    break
                }
            }
            
            // 4. Start on Main Queue (Matches your old working code)
            self.listener?.start(queue: .main)
            
        } catch {
            print("Failed to create UDP listener: \(error)")
        }
    }
    
    // MARK: - Stop Listening
    func stopListening() {
        listener?.cancel()
        listener = nil
        isReceiving = false
    }
    
    // MARK: - Connection Handler
    private func handleConnection(_ connection: NWConnection) {
        // Start the connection to allow data flow
        connection.start(queue: .global(qos: .userInitiated))
        
        // Begin the receive loop
        receiveNextMessage(connection: connection)
    }
    
    private func receiveNextMessage(connection: NWConnection) {
        connection.receiveMessage { [weak self] (data, context, isComplete, error) in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                // Pass to processing (Unblocks the network thread immediately)
                self.processingQueue.async {
                    self.processPacket(data)
                }
            }
            
            if error == nil {
                // Keep listening for the next packet
                self.receiveNextMessage(connection: connection)
            } else {
                print("Connection Error: \(error?.localizedDescription ?? "Unknown")")
            }
        }
    }
    
    // MARK: - Process Packet (Logic from your Old Code)
    private func processPacket(_ data: Data) {
        // 1. Extract the 8-byte timestamp (UInt64)
        guard data.count > 8 else { return }
        let timestampBytes = data.prefix(8)
        let esp32Timestamp = timestampBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
        
        // 2. Strip header
        let audioData = data.dropFirst(8)
        
        // 3. Convert to PCM and pass with receipt time
        if let pcmBuffer = self.dataToPCMBuffer(audioData) {
            // Capture exactly when this packet arrived on the iPhone
            let receiptTime = Date()
            
            self.speechRecognizer?.appendAudioBuffer(
                pcmBuffer,
                esp32Timestamp: esp32Timestamp,
                receiptTime: receiptTime
            )
        }
    }
    
    // MARK: - Helper: Data -> PCM Buffer
    private func dataToPCMBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        // Audio format: 16kHz, 1 channel, 16-bit
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false) else { return nil }
        
        let frameCount = UInt32(data.count) / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        
        buffer.frameLength = frameCount
        
        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let src = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            buffer.int16ChannelData?.pointee.update(from: src, count: Int(frameCount))
        }
        
        return buffer
    }
}

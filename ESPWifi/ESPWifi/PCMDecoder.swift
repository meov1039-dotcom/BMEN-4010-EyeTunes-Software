//
//  PCMDecoder.swift
//  ESPWifi
//
//  Created by Alena Tucker on 2/3/26.
//

import AVFoundation
import Foundation

func int16ToPCMBuffer(_ data: Data, sampleRate: Double = 16000) -> AVAudioPCMBuffer? {
    guard data.count >= 2 else { return nil }

    let bytes = Array(data)
    let frameCount = UInt32(bytes.count / 2)

    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: sampleRate,
                                     channels: 1,
                                     interleaved: false) else { return nil }

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: frameCount) else { return nil }
    buffer.frameLength = frameCount

    guard let floatData = buffer.floatChannelData?[0] else { return nil }

    // Everything inside one closure so the raw pointer is valid for the
    // entire duration we read from it.
    bytes.withUnsafeBufferPointer { (bytePtr: UnsafeBufferPointer<UInt8>) in
        guard let base = bytePtr.baseAddress else { return }
        for i in 0..<Int(frameCount) {
            // Read two bytes manually in little-endian order — no pointer
            // rebinding, no lifetime ambiguity.
            let lo = base[i * 2]
            let hi = base[i * 2 + 1]
            let sample = Int16(bitPattern: UInt16(hi) << 8 | UInt16(lo))
            floatData[i] = Float(sample) / 32768.0
        }
    }

    return buffer
}

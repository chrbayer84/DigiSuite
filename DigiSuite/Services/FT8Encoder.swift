import Foundation

enum FT8EncodeError: LocalizedError {
    case invalidMessage
    var errorDescription: String? {
        switch self {
        case .invalidMessage: return "The FT8 message could not be encoded."
        }
    }
}

/// FT8 transmit: message text -> 77-bit payload -> LDPC codeword -> 79 audio tones.
/// Ported from GridTracker2's ft8_lib (encode.c, crc.c). BSD-3-Clause.
struct FT8Transmitter: TransmitModem, Sendable {
    let mode: RadioModeID = .ft8

    func encode(_ payload: String, sampleRate: Double, amplitude: Float) throws -> [Float] {
        try FT8Encoder.encode(message: payload, sampleRate: sampleRate, amplitude: amplitude)
    }
}

enum FT8Encoder {
    static let symbolPeriod = 0.160
    static let baseFrequency = 1500.0
    static let toneSpacing = 6.25

    static func encode(message: String, sampleRate: Double, amplitude: Float) throws -> [Float] {
        guard let payload = FT8Message.encode(message) else {
            throw FT8EncodeError.invalidMessage
        }
        let tones = tonesForPayload(payload)
        let samplesPerSymbol = Int((symbolPeriod * sampleRate).rounded())
        var output = [Float]()
        output.reserveCapacity(tones.count * samplesPerSymbol)
        var phase = 0.0
        for tone in tones {
            let frequency = baseFrequency + Double(tone) * toneSpacing
            let step = 2 * .pi * frequency / sampleRate
            for _ in 0..<samplesPerSymbol {
                output.append(amplitude * Float(sin(phase)))
                phase += step
                if phase >= 2 * .pi { phase -= 2 * .pi }
            }
        }
        return output
    }

    static func tonesForPayload(_ payload: [UInt8]) -> [UInt8] {
        var a91 = [UInt8](repeating: 0, count: FT8Constants.ldpcKBytes)
        addCRC(payload, into: &a91)
        var codeword = [UInt8](repeating: 0, count: FT8Constants.ldpcNBytes)
        encode174(a91, into: &codeword)

        var tones = [UInt8](repeating: 0, count: FT8Constants.nn)
        var mask: UInt8 = 0x80
        var byteIndex = 0
        for iTone in 0..<FT8Constants.nn {
            if iTone < 7 {
                tones[iTone] = FT8Constants.costas[iTone]
            } else if iTone >= 36 && iTone < 43 {
                tones[iTone] = FT8Constants.costas[iTone - 36]
            } else if iTone >= 72 && iTone < 79 {
                tones[iTone] = FT8Constants.costas[iTone - 72]
            } else {
                var bits3: UInt8 = 0
                if codeword[byteIndex] & mask != 0 { bits3 |= 4 }
                mask >>= 1; if mask == 0 { mask = 0x80; byteIndex += 1 }
                if codeword[byteIndex] & mask != 0 { bits3 |= 2 }
                mask >>= 1; if mask == 0 { mask = 0x80; byteIndex += 1 }
                if codeword[byteIndex] & mask != 0 { bits3 |= 1 }
                mask >>= 1; if mask == 0 { mask = 0x80; byteIndex += 1 }
                tones[iTone] = FT8Constants.gray[Int(bits3)]
            }
        }
        return tones
    }

    static func addCRC(_ payload: [UInt8], into a91: inout [UInt8]) {
        for i in 0..<10 { a91[i] = payload[i] }
        a91[9] &= 0xF8
        a91[10] = 0
        let checksum = FT8Message.computeCRC(a91, numBits: 96 - 14)
        a91[9] |= UInt8(truncatingIfNeeded: checksum >> 11)
        a91[10] = UInt8(truncatingIfNeeded: checksum >> 3)
        a91[11] = UInt8(truncatingIfNeeded: UInt32(checksum) << 5)
    }

    static func encode174(_ message: [UInt8], into codeword: inout [UInt8]) {
        for j in 0..<FT8Constants.ldpcNBytes {
            codeword[j] = j < FT8Constants.ldpcKBytes ? message[j] : 0
        }
        var colMask: UInt8 = 0x80 >> (FT8Constants.ldpcK % 8)
        var colIndex = FT8Constants.ldpcKBytes - 1
        for i in 0..<FT8Constants.ldpcM {
            var nsum: UInt8 = 0
            for j in 0..<FT8Constants.ldpcKBytes {
                let bits = message[j] & FT8Constants.ldpcGenerator[i][j]
                nsum ^= parity8(bits)
            }
            if nsum % 2 != 0 {
                codeword[colIndex] |= colMask
            }
            colMask >>= 1
            if colMask == 0 {
                colMask = 0x80
                colIndex += 1
            }
        }
    }

    private static func parity8(_ x: UInt8) -> UInt8 {
        var x = x
        x ^= x >> 4
        x ^= x >> 2
        x ^= x >> 1
        return x % 2
    }
}

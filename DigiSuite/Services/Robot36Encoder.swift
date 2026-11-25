import Foundation

struct Robot36Transmitter: TransmitModem, Sendable {
    let mode: RadioModeID = .robot36

    func encode(_ payload: Data, sampleRate: Double, amplitude: Float) throws -> [Float] {
        Robot36Encoder.encode(rgba: payload, sampleRate: sampleRate, amplitude: amplitude)
    }
}

enum Robot36Encoder {
    static let width = 320
    static let height = 240

    /// Encodes an RGBA Robot 36 image as phase-continuous mono audio.
    static func encode(rgba: Data, sampleRate: Double, amplitude: Float = 0.35) -> [Float] {
        guard rgba.count >= width * height * 4, sampleRate > 0 else { return [] }
        let pixels = [UInt8](rgba.prefix(width * height * 4))
        var output: [Float] = []
        output.reserveCapacity(Int(sampleRate * 37))
        var phase = 0.0
        var elapsed = 0.0

        func tone(_ frequency: Double, _ duration: Double) {
            let endTime = elapsed + duration
            let endSample = Int((endTime * sampleRate).rounded())
            while output.count < endSample {
                phase += 2 * .pi * frequency / sampleRate
                if phase >= 2 * .pi { phase.formTruncatingRemainder(dividingBy: 2 * .pi) }
                output.append(amplitude * Float(sin(phase)))
            }
            elapsed = endTime
        }

        // VIS code 8: leader, break, leader, start, seven LSB-first data bits,
        // even parity, and stop.
        tone(1900, 0.300); tone(1200, 0.010); tone(1900, 0.300); tone(1200, 0.030)
        let vis: UInt8 = 8
        var parity = 0
        for bit in 0..<7 {
            let one = (vis & (1 << bit)) != 0
            if one { parity += 1 }
            tone(one ? 1100 : 1300, 0.030)
        }
        tone(parity.isMultiple(of: 2) ? 1300 : 1100, 0.030)
        tone(1200, 0.030)

        func component(_ x: Int, _ y: Int, _ channel: Int) -> Double {
            Double(pixels[(y * width + x) * 4 + channel])
        }
        func luma(_ x: Int, _ y: Int) -> Double {
            0.299 * component(x, y, 0) + 0.587 * component(x, y, 1) + 0.114 * component(x, y, 2)
        }
        func scan(_ duration: Double, value: (Int) -> Double) {
            let pixelDuration = duration / Double(width)
            for x in 0..<width {
                let frequency = 1500 + min(255, max(0, value(x))) * 800 / 255
                tone(frequency, pixelDuration)
            }
        }

        for y in 0..<height {
            tone(1200, 0.009)
            tone(1500, 0.003)
            scan(0.088) { luma($0, y) }
            let even = y.isMultiple(of: 2)
            tone(even ? 1500 : 2300, 0.0045)
            tone(1900, 0.0015)
            let pair = even ? y : y - 1
            scan(0.044) { x in
                let next = min(height - 1, pair + 1)
                let firstY = luma(x, pair)
                let secondY = luma(x, next)
                let channel = even ? 0 : 2
                let denominator = even ? 1.402 : 1.772
                return 128 + ((component(x, pair, channel) - firstY) + (component(x, next, channel) - secondY)) / (2 * denominator)
            }
        }

        let ramp = Int(sampleRate * 0.005)
        for index in 0..<min(ramp, output.count) { output[index] *= Float(index) / Float(max(1, ramp)) }
        let tailStart = output.count
        output.append(contentsOf: repeatElement(0, count: Int(sampleRate * 0.2)))
        if tailStart > ramp {
            for index in 0..<ramp { output[tailStart - 1 - index] *= Float(index) / Float(max(1, ramp)) }
        }
        return output
    }
}

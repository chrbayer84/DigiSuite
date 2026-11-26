import Foundation

struct RadioReceiveOutput: Sendable {
    let events: [ReceiveEvent]
    let spectrumRows: [SpectrumRow]
}

/// Serializes mode decoding and shared spectrum analysis away from the UI and audio callback.
final class RadioReceivePipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "radio.receive.pipeline", qos: .userInitiated)
    private var decoder: ReceiveModem = Robot36Decoder()
    private let spectrum = SpectrumAnalyzer()

    func setMode(_ mode: RadioModeID) {
        queue.sync {
            guard decoder.mode != mode else { return }
            decoder = Self.makeDecoder(mode)
        }
    }

    private static func makeDecoder(_ mode: RadioModeID) -> ReceiveModem {
        switch mode {
        case .robot36: return Robot36Decoder()
        case .ft8: return FT8Decoder()
        case .rtty: return Robot36Decoder() // not yet implemented
        }
    }

    func process(_ chunk: AudioChunk) -> RadioReceiveOutput {
        queue.sync {
            RadioReceiveOutput(events: decoder.consume(chunk), spectrumRows: spectrum.append(chunk.samples))
        }
    }

    func reset() -> [ReceiveEvent] {
        queue.sync {
            let events = decoder.reset()
            spectrum.reset()
            return events
        }
    }
}

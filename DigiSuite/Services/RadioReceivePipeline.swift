import Foundation

struct RadioReceiveOutput: Sendable {
    let events: [ReceiveEvent]
    let spectrumRows: [SpectrumRow]
}

/// Serializes mode decoding and shared spectrum analysis away from the UI and audio callback.
final class RadioReceivePipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "radio.receive.pipeline", qos: .userInitiated)
    private let decoder = Robot36Decoder()
    private let spectrum = SpectrumAnalyzer()

    func process(_ chunk: AudioChunk) -> RadioReceiveOutput {
        queue.sync {
            RadioReceiveOutput(events: decoder.consume(chunk), spectrumRows: spectrum.append(chunk.samples))
        }
    }

    func reset() {
        queue.sync {
            decoder.reset()
            spectrum.reset()
        }
    }
}

import XCTest
@testable import DigiSuite

final class RadioModemSignalTests: XCTestCase {
    func testSpectrumAnalyzerFinds1500HzToneAcrossChunkBoundaries() {
        let analyzer = SpectrumAnalyzer(sampleRate: 12_000, transformSize: 256, hopSize: 384)
        let audio = tone(frequency: 1_500, duration: 0.032, amplitude: 0.8)
        XCTAssertTrue(analyzer.append(Array(audio.prefix(100))).isEmpty)
        let rows = analyzer.append(Array(audio.dropFirst(100)))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].decibels.count, 65)
        XCTAssertGreaterThan(rows[0].decibels[32], -12)
    }

    func testRobot36VIS8StartsPicture() {
        let decoder = Robot36Decoder()
        var signal: [Float] = []
        appendTone(1_900, seconds: 0.300, to: &signal)
        appendTone(1_200, seconds: 0.010, to: &signal)
        appendTone(1_900, seconds: 0.300, to: &signal)
        appendTone(1_200, seconds: 0.030, to: &signal)
        let vis: UInt8 = 8
        var parity = 0
        for bit in 0..<7 {
            let one = (vis & (1 << bit)) != 0
            if one { parity += 1 }
            appendTone(one ? 1_100 : 1_300, seconds: 0.030, to: &signal)
        }
        appendTone(parity.isMultiple(of: 2) ? 1_300 : 1_100, seconds: 0.030, to: &signal)
        appendTone(1_200, seconds: 0.030, to: &signal)
        appendTone(1_200, seconds: 0.080, to: &signal)

        var events: [ReceiveEvent] = []
        for start in stride(from: 0, to: signal.count, by: 960) {
            let end = min(signal.count, start + 960)
            events += decoder.consume(AudioChunk(samples: Array(signal[start..<end]), sampleRate: 12_000, startSample: Int64(start)))
        }

        XCTAssertTrue(events.contains { event in
            if case .pictureStarted(_, let title, let width, let height, _) = event {
                return title == "Robot 36" && width == 320 && height == 240
            }
            return false
        }, "Expected VIS 8 to start a 320×240 Robot 36 picture")
    }

    func testStreamingResamplerProducesTwelveKilohertzOutput() {
        let inputRate = 48_000.0
        let source = tone(frequency: 1_500, duration: 1, amplitude: 0.5, sampleRate: inputRate)
        let resampler = StreamingAudioResampler(targetRate: 12_000)
        let result = resampler.process(source, sampleRate: inputRate)
        XCTAssertTrue((11_990...12_000).contains(result.count))
        XCTAssertTrue(result.contains { abs($0) > 0.1 })
    }

    private func tone(frequency: Double, duration: Double, amplitude: Float, sampleRate: Double = 12_000) -> [Float] {
        let count = Int((duration * sampleRate).rounded())
        return (0..<count).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    private func appendTone(_ frequency: Double, seconds: Double, to output: inout [Float]) {
        let count = Int((seconds * 12_000).rounded())
        let start = output.count
        for index in 0..<count {
            output.append(0.6 * Float(sin(2 * .pi * frequency * Double(start + index) / 12_000)))
        }
    }
}

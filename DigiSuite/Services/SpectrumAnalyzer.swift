import Foundation

/// Streaming, windowed short-time DFT for the shared audio waterfall.
/// The frequency bins and time-over-frequency scrolling follow the MMD waterfall model.
final class SpectrumAnalyzer {
    let sampleRate: Double
    let transformSize: Int
    let hopSize: Int
    private let window: [Float]
    private let cosine: [[Float]]
    private let sine: [[Float]]
    private var pending: [Float] = []
    private var nextStart = 0
    private var absoluteSamples: Int64 = 0

    init(sampleRate: Double = 12_000, transformSize: Int = 256, hopSize: Int = 384) {
        precondition(transformSize > 0 && transformSize.nonzeroBitCount == 1)
        self.sampleRate = sampleRate
        self.transformSize = transformSize
        self.hopSize = max(transformSize, hopSize)
        window = (0..<transformSize).map {
            Float(0.5 - 0.5 * cos(2 * .pi * (Double($0) + 0.5) / Double(transformSize)))
        }
        cosine = (0...(transformSize / 4)).map { k in
            (0..<transformSize).map { Float(cos(2 * .pi * Double(k * $0) / Double(transformSize))) }
        }
        sine = (0...(transformSize / 4)).map { k in
            (0..<transformSize).map { Float(sin(2 * .pi * Double(k * $0) / Double(transformSize))) }
        }
    }

    func reset() {
        pending.removeAll(keepingCapacity: true)
        nextStart = 0
        absoluteSamples = 0
    }

    func append(_ samples: [Float]) -> [SpectrumRow] {
        guard !samples.isEmpty else { return [] }
        pending.append(contentsOf: samples)
        absoluteSamples += Int64(samples.count)
        var rows: [SpectrumRow] = []
        while nextStart + transformSize <= pending.count {
            let frameStart = nextStart
            var levels = [Float](repeating: -120, count: transformSize / 4 + 1)
            let norm = Float(transformSize * transformSize) / 4
            for k in 0..<levels.count {
                var real: Float = 0
                var imaginary: Float = 0
                for n in 0..<transformSize {
                    let sample = pending[frameStart + n] * window[n]
                    real += sample * cosine[k][n]
                    imaginary -= sample * sine[k][n]
                }
                let power = (real * real + imaginary * imaginary) / norm
                levels[k] = max(-120, 10 * log10(max(power, 1e-12)))
            }
            let samplesAt = max(0, absoluteSamples - Int64(pending.count) + Int64(frameStart + transformSize))
            rows.append(SpectrumRow(decibels: levels, sampleTime: Double(samplesAt) / sampleRate))
            nextStart += hopSize
        }
        if nextStart > 0 {
            let consumed = min(nextStart, pending.count)
            pending.removeFirst(consumed)
            nextStart -= consumed
        }
        return rows
    }
}

enum WaterfallPalette {
    private static let stops: [(Float, SIMD3<Float>)] = [
        (0, SIMD3(0, 0, 0)),
        (0.27, SIMD3(0, 0, 0.55)),
        (0.51, SIMD3(0, 0.65, 0.9)),
        (0.74, SIMD3(0.95, 0.9, 0)),
        (0.92, SIMD3(1, 0.25, 0)),
        (1, SIMD3(1, 1, 1))
    ]

    static func color(level: Float, floor: Float = -88, range: Float = 55) -> SIMD3<Float> {
        let normalized = min(1, max(0, (level - floor) / range))
        for index in 0..<(stops.count - 1) where normalized <= stops[index + 1].0 {
            let (x0, c0) = stops[index]
            let (x1, c1) = stops[index + 1]
            let t = (normalized - x0) / (x1 - x0)
            return c0 + (c1 - c0) * t
        }
        return stops[stops.count - 1].1
    }
}

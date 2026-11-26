import Foundation

/// Robot 36 receive path guided by JL Barber N7CXI's published SSTV mode
/// specification and the GridTracker2 MMD behavior. Input is mono 12 kHz audio.
final class Robot36Decoder: ReceiveModem {
    let mode: RadioModeID = .robot36
    private let sampleRate = 12_000
    private let samplesPerFrame = 12 // frequency observations every millisecond
    private let sampleRingSize = 32_768
    private let frameRingSize = 40_000
    private let fftLength = 256
    private let analysisLength = 70 // 140 audio samples, matching the MMD idle-window scale
    private let bins = Array(3...73) // 140.6 ... 3421.9 Hz at 46.875 Hz/bin
    private let window: [Float]
    private let cosTable: [[Float]]
    private let sinTable: [[Float]]
    private let syncWindow: [Float]
    private let syncCosTable: [[Float]]
    private let syncSinTable: [[Float]]

    private var sampleRing: [Float]
    private var frequencyRing: [Float]
    private var syncFrequencyRing: [Float]
    private var totalSamples: Int64 = 0
    private var frameCount: Int64 = 0
    private var searchedThrough: Int64 = -1
    private var pictureID: UUID?
    private var pictureStartFrame: Int64 = 0
    private var decodedLines = 0
    private var senderOffset: Float = 0
    private var pictureStartedAt = Date.now
    // The line clock fitted from the sync pulses: where line 0 starts (ms) and the
    // line period (ms). Ported from GridTracker2's sstvFit/sstvLineStart.
    private var clockIntercept: Double = 0
    private var clockPeriod: Double = 150
    private var linePoints: [(line: Double, start: Double, weight: Double)] = []
    private var image = [UInt8](repeating: 0, count: 320 * 240 * 4)
    private var luminance = [Float](repeating: 0, count: 320 * 240)
    private var redDifference = [Float](repeating: 128, count: 320 * 240)
    private var blueDifference = [Float](repeating: 128, count: 320 * 240)
    private var latestStatus: ModemStatus = .listening

    init() {
        let analysisLength = self.analysisLength
        let fftLength = self.fftLength
        let bins = self.bins
        window = (0..<analysisLength).map {
            Float(0.5 - 0.5 * cos(2 * .pi * (Double($0) + 0.5) / Double(analysisLength)))
        }
        cosTable = bins.map { bin in
            (0..<analysisLength).map { n in Float(cos(2 * .pi * Double(bin * n) / Double(fftLength / 2))) }
        }
        sinTable = bins.map { bin in
            (0..<analysisLength).map { n in Float(sin(2 * .pi * Double(bin * n) / Double(fftLength / 2))) }
        }
        syncWindow = (0..<36).map {
            Float(0.5 - 0.5 * cos(2 * .pi * (Double($0) + 0.5) / 36))
        }
        syncCosTable = bins.map { bin in
            (0..<36).map { n in Float(cos(2 * .pi * Double(bin) * Double(n) / Double(fftLength))) }
        }
        syncSinTable = bins.map { bin in
            (0..<36).map { n in Float(sin(2 * .pi * Double(bin) * Double(n) / Double(fftLength))) }
        }
        sampleRing = [Float](repeating: 0, count: sampleRingSize)
        frequencyRing = [Float](repeating: 0, count: frameRingSize)
        syncFrequencyRing = [Float](repeating: 0, count: frameRingSize)
    }

    func reset() -> [ReceiveEvent] {
        let events = flushPartialPicture()
        totalSamples = 0
        frameCount = 0
        searchedThrough = -1
        pictureID = nil
        pictureStartFrame = 0
        pictureStartedAt = .now
        decodedLines = 0
        senderOffset = 0
        clockIntercept = 0
        clockPeriod = 150
        linePoints.removeAll(keepingCapacity: true)
        image = [UInt8](repeating: 0, count: image.count)
        luminance = [Float](repeating: 0, count: luminance.count)
        redDifference = [Float](repeating: 128, count: redDifference.count)
        blueDifference = [Float](repeating: 128, count: blueDifference.count)
        latestStatus = .listening
        return events
    }

    /// Emits the current picture as a finished-but-incomplete record so partial
    /// reception is never lost on stop, clear, or route change.
    private func flushPartialPicture() -> [ReceiveEvent] {
        guard pictureID != nil, decodedLines > 0 else { return [] }
        let picture = RadioPicture(startedAt: pictureStartedAt, rgba: Data(image),
                                   complete: false, frequencyOffsetHz: Int(senderOffset.rounded()))
        return [.pictureFinished(picture)]
    }

    func consume(_ chunk: AudioChunk) -> [ReceiveEvent] {
        guard chunk.sampleRate == Double(sampleRate) else {
            return [.status(.error("Robot 36 decoder requires 12 kHz mono audio; got \(Int(chunk.sampleRate)) Hz."))]
        }
        var events: [ReceiveEvent] = []
        for sample in chunk.samples {
            sampleRing[Int(totalSamples % Int64(sampleRingSize))] = sample
            totalSamples += 1
            if totalSamples >= Int64(analysisLength * 2), totalSamples % Int64(samplesPerFrame) == 0 {
                let center = totalSamples - Int64(analysisLength)
                let value = estimateTone(center: center)
                let frameIndex = center / Int64(samplesPerFrame)
                frequencyRing[Int(frameIndex % Int64(frameRingSize))] = value
                syncFrequencyRing[Int(frameIndex % Int64(frameRingSize))] = estimateSyncTone(center: center)
                frameCount = max(frameCount, frameIndex + 1)
                if pictureID == nil, let vis = findVIS(endingAt: frameIndex) {
                    beginPicture(vis: vis, endFrame: frameIndex, events: &events)
                }
                if pictureID != nil {
                    decodeReadyLines(through: frameIndex, events: &events)
                }
            }
        }
        if events.isEmpty, latestStatus == .listening {
            events.append(.status(.listening))
        }
        return events
    }

    private func estimateTone(center: Int64) -> Float {
        let first = center - Int64(analysisLength)
        var bestPower: Float = 0
        var bestFrequency: Float = 0
        var peakIndex = 0
        var powers = [Float](repeating: 0, count: bins.count)
        for (binIndex, bin) in bins.enumerated() {
            var real: Float = 0
            var imaginary: Float = 0
            for n in 0..<analysisLength {
                let sampleIndex = first + Int64(n * 2)
                let sample = sampleRing[Int((sampleIndex + Int64(sampleRingSize)) % Int64(sampleRingSize))] * window[n]
                real += sample * cosTable[binIndex][n]
                imaginary += sample * sinTable[binIndex][n]
            }
            let power = real * real + imaginary * imaginary
            powers[binIndex] = power
            if power > bestPower {
                bestPower = power
                bestFrequency = Float(bin) * Float(sampleRate) / Float(fftLength)
                peakIndex = binIndex
            }
        }
        if peakIndex > 0 && peakIndex + 1 < powers.count {
            let left = log(max(powers[peakIndex - 1], 1e-20))
            let middle = log(max(powers[peakIndex], 1e-20))
            let right = log(max(powers[peakIndex + 1], 1e-20))
            let denominator = 2 * (2 * middle - left - right)
            if denominator > 0 {
                let delta = max(-0.5, min(0.5, (right - left) / denominator))
                bestFrequency += delta * Float(sampleRate) / Float(fftLength)
            }
        }
        return bestPower > 1e-8 ? bestFrequency : 0
    }

    private func estimateSyncTone(center: Int64) -> Float {
        let first = center - 18
        var powers = [Float](repeating: 0, count: bins.count)
        var bestPower: Float = 0
        var bestFrequency: Float = 0
        var peakIndex = 0
        for binIndex in bins.indices {
            var real: Float = 0
            var imaginary: Float = 0
            for n in 0..<36 {
                let sampleIndex = first + Int64(n)
                let ringIndex = Int((sampleIndex + Int64(sampleRingSize)) % Int64(sampleRingSize))
                let sample = sampleRing[ringIndex] * syncWindow[n]
                real += sample * syncCosTable[binIndex][n]
                imaginary += sample * syncSinTable[binIndex][n]
            }
            let power = real * real + imaginary * imaginary
            powers[binIndex] = power
            if power > bestPower {
                bestPower = power
                bestFrequency = Float(bins[binIndex]) * Float(sampleRate) / Float(fftLength)
                peakIndex = binIndex
            }
        }
        if peakIndex > 0 && peakIndex + 1 < powers.count {
            let left = log(max(powers[peakIndex - 1], 1e-20))
            let middle = log(max(powers[peakIndex], 1e-20))
            let right = log(max(powers[peakIndex + 1], 1e-20))
            let denominator = 2 * (2 * middle - left - right)
            if denominator > 0 {
                let delta = max(-0.5, min(0.5, (right - left) / denominator))
                bestFrequency += delta * Float(sampleRate) / Float(fftLength)
            }
        }
        return bestPower > 1e-8 ? bestFrequency : 0
    }

    private func frequency(at frame: Int64) -> Float {
        guard frame >= 0, frameCount > 0 else { return 0 }
        // A frame not heard yet takes the newest reading rather than a stale or zero
        // one (a zero chroma would paint the line green).
        let clamped = min(frame, frameCount - 1)
        guard frameCount - clamped < Int64(frameRingSize) else { return 0 }
        return frequencyRing[Int(clamped % Int64(frameRingSize))]
    }

    private func syncFrequency(at frame: Int64) -> Float {
        guard frame >= 0, frameCount > 0 else { return 0 }
        let clamped = min(frame, frameCount - 1)
        guard frameCount - clamped < Int64(frameRingSize) else { return 0 }
        return syncFrequencyRing[Int(clamped % Int64(frameRingSize))]
    }

    private func medianFrequency(from start: Int64, to end: Int64, stride: Int64 = 5) -> Float {
        guard end > start else { return 0 }
        var values: [Float] = []
        var index = start
        while index < end {
            let value = frequency(at: index)
            if value > 0 { values.append(value) }
            index += stride
        }
        guard !values.isEmpty else { return 0 }
        values.sort()
        return values[values.count / 2]
    }

    private func medianSyncFrequency(from start: Int64, to end: Int64, stride: Int64 = 1) -> Float {
        guard end > start else { return 0 }
        var values: [Float] = []
        var index = start
        while index < end {
            let value = syncFrequency(at: index)
            if value > 0 { values.append(value) }
            index += stride
        }
        guard !values.isEmpty else { return 0 }
        values.sort()
        return values[values.count / 2]
    }

    /// Detect VIS 8 by checking the leader, start/stop tones, seven LSB-first bits,
    /// and even parity over stable portions of each nominal 30 ms symbol.
    private func findVIS(endingAt frame: Int64) -> (start: Int64, shift: Float)? {
        let candidate = frame - 300
        guard candidate > searchedThrough, candidate >= 300 else { return nil }
        searchedThrough = candidate
        let leader = medianFrequency(from: candidate - 250, to: candidate - 30)
        guard leader > 0 else { return nil }
        let shift = leader - 1900
        guard abs(shift) <= 1000 else { return nil }
        guard abs(medianFrequency(from: candidate - 610, to: candidate - 320) - shift - 1900) < 100,
              abs(medianSyncFrequency(from: candidate - 310, to: candidate - 300) - shift - 1200) < 120,
              abs(medianFrequency(from: candidate - 295, to: candidate - 30) - shift - 1900) < 100 else { return nil }
        func tone(_ from: Int64, _ to: Int64, _ expected: Float) -> Bool {
            abs(medianFrequency(from: candidate + from, to: candidate + to) - shift - expected) < 100
        }
        guard tone(0, 30, 1200), tone(270, 300, 1200) else { return nil }
        var code = 0
        var ones = 0
        for bit in 0..<8 {
            let observed = medianFrequency(from: candidate + Int64(30 + bit * 30), to: candidate + Int64(60 + bit * 30)) - shift
            let oneError = abs(observed - 1100)
            let zeroError = abs(observed - 1300)
            guard min(oneError, zeroError) < 100 else { return nil }
            let one = oneError < zeroError
            if one { ones += 1 }
            if bit < 7 && one { code |= 1 << bit }
        }
        guard code == 8, ones.isMultiple(of: 2) else { return nil }
        return (candidate, shift)
    }

    private func beginPicture(vis: (start: Int64, shift: Float), endFrame: Int64, events: inout [ReceiveEvent]) {
        let id = UUID()
        pictureID = id
        pictureStartFrame = vis.start + 300
        senderOffset = vis.shift
        pictureStartedAt = .now.addingTimeInterval(-0.91)
        decodedLines = 0
        clockIntercept = Double(pictureStartFrame)
        clockPeriod = 150
        linePoints.removeAll(keepingCapacity: true)
        image = [UInt8](repeating: 0, count: image.count)
        luminance = [Float](repeating: 0, count: luminance.count)
        redDifference = [Float](repeating: 128, count: redDifference.count)
        blueDifference = [Float](repeating: 128, count: blueDifference.count)
        latestStatus = .receiving(mode: "Robot 36", line: 0, totalLines: 240)
        events.append(.pictureStarted(id: id, title: "Robot 36", width: 320, height: 240, offsetHz: Int(vis.shift.rounded())))
        events.append(.status(latestStatus))
        _ = endFrame
    }

    private func decodeReadyLines(through frame: Int64, events: inout [ReceiveEvent]) {
        guard let id = pictureID else { return }
        while decodedLines < 240 {
            let estimate = lineStart(for: decodedLines)
            // Wait until the whole line's audio plus the sync search window has been
            // heard, so the chroma never reads samples that have not arrived yet (a
            // stale or zero reading there paints the line green).
            guard frame >= Int64(estimate.rounded(.down)) + 168 else { break }

            let expectedSyncEnd = estimate + 9 * (clockPeriod / 150)
            var start = estimate
            if let found = findSyncEnd(expectedSyncEnd: expectedSyncEnd) {
                let observedSync = medianSyncFrequency(from: Int64(found.end - 8), to: Int64(found.end - 2))
                if observedSync > 0 {
                    let correction = max(-25, min(25, (observedSync - 1200 - senderOffset) * 0.5))
                    senderOffset += correction
                }
                linePoints.append((line: Double(decodedLines), start: found.end - 9, weight: found.clarity))
                fitClock()
                start = found.end - 9
            }

            decodeLine(decodedLines, start: start)
            if decodedLines % 2 == 1 {
                let firstRow = decodedLines - 1
                paintRows(firstRow, firstRow + 2)
                let bytes = Data(image[(firstRow * 320 * 4)..<((firstRow + 2) * 320 * 4)])
                events.append(.pictureRows(id: id, from: firstRow, count: 2, rgba: bytes))
            }
            decodedLines += 1
            latestStatus = .receiving(mode: "Robot 36", line: decodedLines, totalLines: 240)
            if decodedLines.isMultiple(of: 12) { events.append(.status(latestStatus)) }
        }
        if decodedLines == 240 {
            // Redraw everything with the final line clock (the sender's rate, drift
            // and Doppler corrected), as GridTracker2 does.
            redrawPicture()
            let picture = RadioPicture(startedAt: pictureStartedAt, rgba: Data(image), complete: true, frequencyOffsetHz: Int(senderOffset.rounded()))
            events.append(.pictureFinished(picture))
            events.append(.status(.complete("Robot 36 picture complete")))
            pictureID = nil
            latestStatus = .listening
        }
    }

    /// The start of line `line`, in milliseconds, by the fitted clock.
    private func lineStart(for line: Int) -> Double {
        if linePoints.isEmpty { return Double(pictureStartFrame) + Double(line) * 150 }
        return clockIntercept + clockPeriod * Double(line)
    }

    /// Fits the line clock to the measured sync pulses (GridTracker2's sstvFit): the
    /// nominal period until three points, then a weighted least squares with the
    /// points far off the fit dropped, and the rate kept within 0.6% of nominal.
    private func fitClock() {
        guard !linePoints.isEmpty else { return }
        var points = linePoints
        let nominal = 150.0
        for _ in 0..<3 {
            let a: Double
            let b: Double
            if points.count < 3 {
                b = nominal
                a = points.reduce(0.0) { $0 + ($1.start - b * $1.line) } / Double(points.count)
            } else {
                var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
                for p in points {
                    sw += p.weight
                    sx += p.weight * p.line
                    sy += p.weight * p.start
                    sxx += p.weight * p.line * p.line
                    sxy += p.weight * p.line * p.start
                }
                let den = sw * sxx - sx * sx
                var slope = den > 0 ? (sw * sxy - sx * sy) / den : nominal
                slope = max(nominal * 0.994, min(nominal * 1.006, slope))
                b = slope
                a = (sy - b * sx) / sw
            }
            clockIntercept = a
            clockPeriod = b
            let residuals = points.map { abs($0.start - a - b * $0.line) }
            let rms = sqrt(residuals.reduce(0.0) { $0 + $1 * $1 } / Double(residuals.count))
            let limit = max(2.0, 2.5 * rms)
            var keep: [(line: Double, start: Double, weight: Double)] = []
            for (index, point) in points.enumerated() where residuals[index] <= limit {
                keep.append(point)
            }
            if keep.count == points.count || keep.count < 3 { break }
            points = keep
        }
        if linePoints.count > 64 { linePoints.removeFirst(linePoints.count - 64) }
    }

    /// The sync pulse end nearest the expected one (GridTracker2's sstvSyncEnd): the
    /// window widens while few pulses have been measured, then narrows.
    private func findSyncEnd(expectedSyncEnd: Double) -> (end: Double, clarity: Double)? {
        let spread = linePoints.count >= 8 ? 3.0 : (linePoints.isEmpty ? 15.0 : max(4.0, 9.0))
        let before = 7
        let after = 2
        let edge = 1500 + senderOffset - 150
        let first = Int64((expectedSyncEnd - spread).rounded())
        let last = Int64((expectedSyncEnd + spread).rounded())
        guard last > first else { return nil }
        var best: Double = -1
        var bestAt = Int64(expectedSyncEnd.rounded())
        for e in first...last {
            var high = 0
            var low = 0
            for i in (e - Int64(before))..<e where syncFrequency(at: i) < edge { high += 1 }
            for i in e..<(e + Int64(after)) where syncFrequency(at: i) < edge { low += 1 }
            let score = Double(high) / Double(before) - Double(low) / Double(after)
            if score > best { best = score; bestAt = e }
        }
        return best > 0.3 ? (Double(bestAt), best) : nil
    }

    private func decodeLine(_ line: Int, start: Double) {
        let scale = clockPeriod / 150
        let base = line * 320
        let luminanceStart = start + 12 * scale
        let luminancePixel = 88 * scale / 320
        for x in 0..<320 {
            let frame = Int64((luminanceStart + (Double(x) + 0.5) * luminancePixel).rounded())
            luminance[base + x] = level(frequency(at: frame))
        }
        let separator = medianSyncFrequency(from: Int64((start + 101 * scale).rounded()),
                                            to: Int64((start + 104 * scale).rounded())) - senderOffset
        let isRed = separator < 1900
        let chromaStart = start + 106 * scale
        let chromaPixel = 44 * scale / 320
        let pairBase = (line / 2) * 2 * 320
        for x in 0..<320 {
            let frame = Int64((chromaStart + (Double(x) + 0.5) * chromaPixel).rounded())
            let value = level(frequency(at: frame))
            if isRed {
                redDifference[pairBase + x] = value
                redDifference[pairBase + 320 + x] = value
            } else {
                blueDifference[pairBase + x] = value
                blueDifference[pairBase + 320 + x] = value
            }
        }
    }

    /// Re-reads every line with the final clock and repaints it (the reference redraws
    /// the picture as the line rate improves).
    private func redrawPicture() {
        guard decodedLines > 0 else { return }
        fitClock()
        for y in 0..<decodedLines {
            decodeLine(y, start: lineStart(for: y))
        }
        paintRows(0, decodedLines - (decodedLines % 2))
    }

    private func level(_ frequency: Float) -> Float {
        min(255, max(0, (frequency - 1500 - senderOffset) * 255 / 800))
    }

    private func paintRows(_ from: Int, _ to: Int) {
        for row in from..<to {
            for x in 0..<320 {
                let index = row * 320 + x
                let y = luminance[index]
                let v = redDifference[index] - 128
                let u = blueDifference[index] - 128
                let rgbaIndex = index * 4
                image[rgbaIndex] = byte(y + 1.402 * v)
                image[rgbaIndex + 1] = byte(y - 0.344 * u - 0.714 * v)
                image[rgbaIndex + 2] = byte(y + 1.772 * u)
                image[rgbaIndex + 3] = 255
            }
        }
    }

    private func byte(_ value: Float) -> UInt8 { UInt8(max(0, min(255, value.rounded()))) }
}

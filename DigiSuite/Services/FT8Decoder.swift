import Accelerate
import Foundation

/// FT8 receive modem. Ports GridTracker2's ft8_lib (decode.c, ldpc.c) plus a
/// 2048-point FFT waterfall, using the standard FT8 messages. BSD-3-Clause.
final class FT8Decoder: ReceiveModem {
    let mode: RadioModeID = .ft8

    private let inputRate = 12_000.0
    private let rate = 12_800.0           // 2048-point FFT => 6.25 Hz bins
    private let fftSize = 2048
    private let numBins = 1024            // 0..6400 Hz positive bins
    private let symbolSamples = 2048      // 0.160 s at 12.8 kHz
    private let slotSeconds = 15.0
    private let symbolsPerMessage = 79
    private let maxCandidates = 10
    private let ldpcIterations = 20

    private let resampler = StreamingAudioResampler(targetRate: 12_800)
    private let fftSetup: FFTSetup
    private let window: [Float]

    private var sampleBuffer: [Float] = []
    private var streamStartDate: Date?
    private var resampledCount: Int64 = 0

    // Rolling waterfall: magnitudes in dB, with the UTC time of each row's first sample.
    private var rows: [[Float]] = []
    private var rowDates: [Date] = []

    private var hashes: [UInt32: String] = [:]
    private var decodedSlots: Set<Double> = []

    init() {
        fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Double(fftSize))), FFTRadix(kFFTRadix2))!
        window = (0..<fftSize).map {
            Float(0.5 - 0.5 * cos(2 * .pi * (Double($0) + 0.5) / Double(fftSize)))
        }
    }

    func reset() -> [ReceiveEvent] {
        sampleBuffer.removeAll(keepingCapacity: true)
        streamStartDate = nil
        resampledCount = 0
        rows.removeAll(keepingCapacity: true)
        rowDates.removeAll(keepingCapacity: true)
        decodedSlots.removeAll(keepingCapacity: true)
        return []
    }

    func consume(_ chunk: AudioChunk) -> [ReceiveEvent] {
        guard chunk.sampleRate == inputRate else {
            return [.status(.error("FT8 decoder requires 12 kHz mono audio."))]
        }
        if streamStartDate == nil {
            streamStartDate = chunk.startDate.addingTimeInterval(-Double(chunk.startSample) / inputRate)
        }

        let resampled = resampler.process(chunk.samples, sampleRate: inputRate)
        guard !resampled.isEmpty else { return [] }
        sampleBuffer.append(contentsOf: resampled)

        var events: [ReceiveEvent] = []
        while sampleBuffer.count >= symbolSamples {
            let frame = Array(sampleBuffer.prefix(symbolSamples))
            sampleBuffer.removeFirst(symbolSamples)
            let rowTime = (streamStartDate ?? .now).addingTimeInterval(Double(resampledCount) / rate)
            resampledCount += Int64(symbolSamples)
            rows.append(magnitudeSpectrum(frame))
            rowDates.append(rowTime)
            events += decodeReadySlots()
        }
        return events
    }

    // MARK: - FFT

    private func magnitudeSpectrum(_ samples: [Float]) -> [Float] {
        var realp = [Float](repeating: 0, count: fftSize / 2)
        var imagp = [Float](repeating: 0, count: fftSize / 2)
        for i in 0..<(fftSize / 2) {
            realp[i] = samples[2 * i] * window[2 * i]
            imagp[i] = samples[2 * i + 1] * window[2 * i + 1]
        }
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, vDSP_Length(log2(Double(fftSize))), FFTDirection(FFT_FORWARD))
            }
        }
        var magnitudes = [Float](repeating: 0, count: numBins)
        let norm = Float(fftSize * fftSize) / 4
        magnitudes[0] = toDB(abs(realp[0]) * abs(realp[0]) / norm)
        for i in 1..<numBins {
            let power = (realp[i] * realp[i] + imagp[i] * imagp[i]) / norm
            magnitudes[i] = toDB(power)
        }
        return magnitudes
    }

    private func toDB(_ power: Float) -> Float {
        return 10 * log10(max(power, 1e-12))
    }

    // MARK: - Slot handling

    private func decodeReadySlots() -> [ReceiveEvent] {
        guard let now = rowDates.last?.timeIntervalSince1970 else { return [] }
        let readySpan = slotSeconds + 2.4
        let slotStart = floor((now - readySpan) / slotSeconds) * slotSeconds
        guard !decodedSlots.contains(slotStart) else { return [] }
        guard let first = rowDates.first, first.timeIntervalSince1970 <= slotStart - 1.6 else { return [] }
        decodedSlots.insert(slotStart)

        var window: [[Float]] = []
        for (row, date) in zip(rows, rowDates) {
            let t = date.timeIntervalSince1970
            if t >= slotStart - 1.6 && t < slotStart + readySpan {
                window.append(row)
            }
        }
        trimRows(before: slotStart - 2.0)

        let texts = decodeWindow(window)
        var events: [ReceiveEvent] = []
        for text in texts {
            events.append(.decodedText(DecodedText(mode: .ft8, receivedAt: Date(timeIntervalSince1970: slotStart), text: text)))
        }
        return events
    }

    private func trimRows(before cutoff: Double) {
        while let first = rowDates.first, first.timeIntervalSince1970 < cutoff {
            rowDates.removeFirst()
            rows.removeFirst()
        }
    }

    // MARK: - Decode a window of rows

    private func decodeWindow(_ window: [[Float]]) -> [String] {
        guard window.count >= symbolsPerMessage else { return [] }

        let candidates = findCandidates(window)
        var results: [String] = []
        var seen: Set<String> = []
        for candidate in candidates {
            if results.count >= maxCandidates { break }
            guard let text = decodeCandidate(window, candidate) else { continue }
            if !text.isEmpty && !seen.contains(text) {
                seen.insert(text)
                results.append(text)
            }
        }
        return results
    }

    private struct Candidate {
        var score: Float
        var timeOffset: Int
        var freqOffset: Int
    }

    private func findCandidates(_ window: [[Float]]) -> [Candidate] {
        let maxTimeOffset = window.count - symbolsPerMessage
        let maxFreqOffset = numBins - 8
        var heap: [Candidate] = []

        func push(_ candidate: Candidate) {
            if heap.count < maxCandidates {
                heap.append(candidate)
                heap.sort { $0.score < $1.score }
            } else if candidate.score > (heap.first?.score ?? 0) {
                heap[0] = candidate
                heap.sort { $0.score < $1.score }
            }
        }

        for timeOffset in 0...maxTimeOffset {
            for freqOffset in 0...maxFreqOffset {
                let score = syncScore(window, timeOffset: timeOffset, freqOffset: freqOffset)
                if score > 0 {
                    push(Candidate(score: score, timeOffset: timeOffset, freqOffset: freqOffset))
                }
            }
        }
        return heap.sorted { $0.score > $1.score }
    }

    private func syncScore(_ window: [[Float]], timeOffset: Int, freqOffset: Int) -> Float {
        var score: Float = 0
        var count = 0
        for m in 0..<FT8Constants.numSync {
            for k in 0..<FT8Constants.syncLength {
                let block = FT8Constants.syncOffset * m + k
                let row = timeOffset + block
                if row < 0 || row >= window.count { continue }
                let sm = Int(FT8Constants.costas[k])
                let mag = window[row][freqOffset + sm]
                if sm > 0 { score += mag - window[row][freqOffset + sm - 1]; count += 1 }
                if sm < 7 { score += mag - window[row][freqOffset + sm + 1]; count += 1 }
                if k > 0 && row > 0 { score += mag - window[row - 1][freqOffset + sm]; count += 1 }
                if k + 1 < FT8Constants.syncLength && row + 1 < window.count {
                    score += mag - window[row + 1][freqOffset + sm]; count += 1
                }
            }
        }
        return count > 0 ? score / Float(count) : 0
    }

    // MARK: - Decode a candidate

    private func decodeCandidate(_ window: [[Float]], _ candidate: Candidate) -> String? {
        var log174 = [Float](repeating: 0, count: FT8Constants.ldpcN)

        for k in 0..<FT8Constants.nd {
            let symIdx = k + (k < 29 ? 7 : 14)
            let row = candidate.timeOffset + symIdx
            let bitIdx = 3 * k
            if row < 0 || row >= window.count {
                log174[bitIdx] = 0; log174[bitIdx + 1] = 0; log174[bitIdx + 2] = 0
            } else {
                extractSymbol(window[row], freqOffset: candidate.freqOffset, logl: &log174, bitIdx: bitIdx)
            }
        }

        normalize(log174: &log174)

        var plain = [UInt8](repeating: 0, count: FT8Constants.ldpcN)
        let errors = ldpcDecode(log174, maxIters: ldpcIterations, plain: &plain)
        guard errors == 0 else { return nil }

        var a91 = [UInt8](repeating: 0, count: FT8Constants.ldpcKBytes)
        packBits(plain, numBits: FT8Constants.ldpcK, into: &a91)

        let extractedCRC = FT8Message.extractCRC(a91)
        a91[9] &= 0xF8
        a91[10] = 0
        let calculatedCRC = FT8Message.computeCRC(a91, numBits: 96 - 14)
        guard extractedCRC == calculatedCRC else { return nil }

        let payload = Array(a91.prefix(10))
        return FT8Message.decode(payload, hashes: &hashes)
    }

    private func extractSymbol(_ row: [Float], freqOffset: Int, logl: inout [Float], bitIdx: Int) {
        var s2 = [Float](repeating: 0, count: 8)
        for j in 0..<8 { s2[j] = row[freqOffset + Int(FT8Constants.gray[j])] }

        func max4(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float {
            return max(max(a, b), max(c, d))
        }
        logl[bitIdx] = max4(s2[4], s2[5], s2[6], s2[7]) - max4(s2[0], s2[1], s2[2], s2[3])
        logl[bitIdx + 1] = max4(s2[2], s2[3], s2[6], s2[7]) - max4(s2[0], s2[1], s2[4], s2[5])
        logl[bitIdx + 2] = max4(s2[1], s2[3], s2[5], s2[7]) - max4(s2[0], s2[2], s2[4], s2[6])
    }

    private func normalize(log174: inout [Float]) {
        var sum: Float = 0
        var sum2: Float = 0
        for v in log174 { sum += v; sum2 += v * v }
        let invN = 1.0 / Float(FT8Constants.ldpcN)
        let variance = (sum2 - (sum * sum * invN)) * invN
        guard variance > 1e-12 else { return }
        let factor = sqrt(24.0 / variance)
        for i in 0..<log174.count { log174[i] *= factor }
    }

    // MARK: - LDPC (belief propagation, from ldpc.c)

    private func ldpcDecode(_ codeword: [Float], maxIters: Int, plain: inout [UInt8]) -> Int {
        let nm = FT8Constants.ldpcNm
        let mn = FT8Constants.ldpcMn
        let numRows = FT8Constants.ldpcNumRows

        var tov = [[Float]](repeating: [0, 0, 0], count: FT8Constants.ldpcN)
        var toc = [[Float]](repeating: [Float](repeating: 0, count: 7), count: FT8Constants.ldpcM)
        var minErrors = FT8Constants.ldpcM

        for _ in 0..<maxIters {
            var plainSum = 0
            for n in 0..<FT8Constants.ldpcN {
                plain[n] = (codeword[n] + tov[n][0] + tov[n][1] + tov[n][2] > 0) ? 1 : 0
                plainSum += Int(plain[n])
            }
            if plainSum == 0 { break }

            let errors = ldpcCheck(plain)
            if errors < minErrors {
                minErrors = errors
                if errors == 0 { break }
            }

            for m in 0..<FT8Constants.ldpcM {
                let rowCount = Int(numRows[m])
                for nIdx in 0..<rowCount {
                    let n = Int(nm[m][nIdx]) - 1
                    var tnm = codeword[n]
                    for mIdx in 0..<3 where Int(mn[n][mIdx]) - 1 != m {
                        tnm += tov[n][mIdx]
                    }
                    toc[m][nIdx] = fastTanh(-tnm / 2)
                }
            }

            for n in 0..<FT8Constants.ldpcN {
                for mIdx in 0..<3 {
                    let m = Int(mn[n][mIdx]) - 1
                    var tmn: Float = 1
                    let rowCount = Int(numRows[m])
                    for nIdx in 0..<rowCount where Int(nm[m][nIdx]) - 1 != n {
                        tmn *= toc[m][nIdx]
                    }
                    tov[n][mIdx] = -2 * fastAtanh(tmn)
                }
            }
        }
        return minErrors
    }

    private func ldpcCheck(_ codeword: [UInt8]) -> Int {
        let nm = FT8Constants.ldpcNm
        let numRows = FT8Constants.ldpcNumRows
        var errors = 0
        for m in 0..<FT8Constants.ldpcM {
            var x: UInt8 = 0
            let rowCount = Int(numRows[m])
            for i in 0..<rowCount {
                x ^= codeword[Int(nm[m][i]) - 1]
            }
            if x != 0 { errors += 1 }
        }
        return errors
    }

    private func fastTanh(_ x: Float) -> Float {
        if x < -4.97 { return -1 }
        if x > 4.97 { return 1 }
        let x2 = x * x
        let a = x * (945.0 + x2 * (105.0 + x2))
        let b = 945.0 + x2 * (420.0 + x2 * 15.0)
        return a / b
    }

    private func fastAtanh(_ x: Float) -> Float {
        let x2 = x * x
        let a = x * (945.0 + x2 * (-735.0 + x2 * 64.0))
        let b = 945.0 + x2 * (-1050.0 + x2 * 225.0)
        return a / b
    }

    private func packBits(_ bits: [UInt8], numBits: Int, into packed: inout [UInt8]) {
        let numBytes = (numBits + 7) / 8
        for i in 0..<numBytes { packed[i] = 0 }
        var mask: UInt8 = 0x80
        var byteIdx = 0
        for i in 0..<numBits {
            if bits[i] != 0 { packed[byteIdx] |= mask }
            mask >>= 1
            if mask == 0 { mask = 0x80; byteIdx += 1 }
        }
    }
}

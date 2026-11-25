import AVFoundation
import Foundation

private final class FloatSampleRing {
    private let lock = NSLock()
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0

    init(capacity: Int) { storage = [Float](repeating: 0, count: capacity) }

    func write(_ source: UnsafePointer<Float>, count incoming: Int) {
        lock.lock()
        for offset in 0..<incoming {
            storage[writeIndex] = source[offset]
            writeIndex = (writeIndex + 1) % storage.count
            if count == storage.count { readIndex = (readIndex + 1) % storage.count }
            else { count += 1 }
        }
        lock.unlock()
    }

    func drain(maximum: Int) -> [Float] {
        lock.lock()
        let amount = min(maximum, count)
        var result = [Float](repeating: 0, count: amount)
        for index in 0..<amount {
            result[index] = storage[readIndex]
            readIndex = (readIndex + 1) % storage.count
        }
        count -= amount
        lock.unlock()
        return result
    }

    func clear() {
        lock.lock()
        readIndex = 0
        writeIndex = 0
        count = 0
        lock.unlock()
    }
}

/// 63-tap Blackman-Harris low-pass followed by linear rate conversion to 12 kHz.
/// This mirrors the common audio-to-12-kHz path used by the local MMD reference.
final class StreamingAudioResampler {
    private let targetRate: Double
    private var sourceRate: Double = 0
    private var taps: [Float] = []
    private var history = [Float](repeating: 0, count: 63)
    private var historyIndex = 0
    private var sourceIndex: Int64 = 0
    private var nextOutputIndex = 0.0
    private var previousFiltered: Float = 0

    init(targetRate: Double = 12_000) { self.targetRate = targetRate }

    func reset(sourceRate: Double) {
        self.sourceRate = sourceRate
        history = [Float](repeating: 0, count: 63)
        historyIndex = 0
        sourceIndex = 0
        nextOutputIndex = 31
        previousFiltered = 0
        taps = Self.makeTaps(sampleRate: sourceRate, cutoffHz: min(5_000, targetRate * 0.46))
    }

    func process(_ input: [Float], sampleRate: Double) -> [Float] {
        guard sampleRate > 0 else { return [] }
        if abs(sourceRate - sampleRate) > 1 { reset(sourceRate: sampleRate) }
        var output: [Float] = []
        output.reserveCapacity(Int(Double(input.count) * targetRate / sampleRate) + 4)
        let step = sampleRate / targetRate
        for sample in input {
            history[historyIndex] = sample
            historyIndex = (historyIndex + 1) % history.count
            sourceIndex += 1
            var filtered: Float = 0
            for tap in taps.indices {
                let index = (historyIndex + tap) % history.count
                filtered += history[index] * taps[tap]
            }
            while nextOutputIndex <= Double(sourceIndex) - 1 {
                let fraction = Float(nextOutputIndex - (Double(sourceIndex) - 2))
                output.append(previousFiltered + (filtered - previousFiltered) * fraction)
                nextOutputIndex += step
            }
            previousFiltered = filtered
        }
        return output
    }

    private static func makeTaps(sampleRate: Double, cutoffHz: Double) -> [Float] {
        let count = 63
        let center = Double(count - 1) / 2
        let cutoff = cutoffHz / sampleRate
        var values = [Double](repeating: 0, count: count)
        var sum = 0.0
        for index in 0..<count {
            let offset = Double(index) - center
            let sinc = offset == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * offset) / (.pi * offset)
            let position = Double(index) / Double(count - 1)
            let window = 0.35875 - 0.48829 * cos(2 * .pi * position) + 0.14128 * cos(4 * .pi * position) - 0.01168 * cos(6 * .pi * position)
            values[index] = sinc * window
            sum += values[index]
        }
        return values.map { Float($0 / sum) }
    }
}

final class RadioAudioCaptureService {
    private let engine = AVAudioEngine()
    private let ring = FloatSampleRing(capacity: 96_000)
    private let processingQueue = DispatchQueue(label: "radio.audio.capture", qos: .userInitiated)
    private var drainTimer: DispatchSourceTimer?
    private var resampler = StreamingAudioResampler()
    private var inputRate: Double = 0
    private var totalOutputSamples: Int64 = 0
    private var running = false
    private var observers: [NSObjectProtocol] = []
    var onAudio: ((AudioChunk) -> Void)?
    var onError: ((String) -> Void)?

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission(completion)
    }

    func start() throws {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioServiceError.noInput
        }
        inputRate = format.sampleRate
        ring.clear()
        resampler.reset(sourceRate: inputRate)
        totalOutputSamples = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            self.ring.write(channels[0], count: Int(buffer.frameLength))
        }
        engine.prepare()
        do {
            try engine.start()
            running = true
            startDrain()
            observeSessionChanges()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        guard running else { return }
        running = false
        drainTimer?.cancel()
        drainTimer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startDrain() {
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            let input = self.ring.drain(maximum: 4096)
            guard !input.isEmpty else { return }
            let output = self.resampler.process(input, sampleRate: self.inputRate)
            guard !output.isEmpty else { return }
            let chunk = AudioChunk(samples: output, sampleRate: 12_000, startSample: self.totalOutputSamples)
            self.totalOutputSamples += Int64(output.count)
            self.onAudio?(chunk)
        }
        drainTimer = timer
        timer.resume()
    }

    private func observeSessionChanges() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self, self.running else { return }
            self.processingQueue.async {
                self.stop()
                self.onError?("The audio route changed. Start reception again to use the new input.")
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
            guard let self, self.running,
                  let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self.processingQueue.async {
                self.stop()
                self.onError?("Audio was interrupted. Start reception again when the interruption ends.")
            }
        })
    }
}

enum AudioServiceError: LocalizedError {
    case noInput
    var errorDescription: String? {
        switch self { case .noInput: return "No microphone input is available." }
    }
}

final class RadioAudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    func play(_ samples: [Float], sampleRate: Double, completion: @escaping () -> Void) throws {
        guard !samples.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)
        if !engine.attachedNodes.contains(player) { engine.attach(player) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let destination = buffer.floatChannelData?.pointee {
                destination.update(from: source.baseAddress!, count: samples.count)
            }
        }
        engine.prepare()
        try engine.start()
        player.scheduleBuffer(buffer) { [weak self] in
            self?.player.stop()
            self?.engine.stop()
            completion()
        }
        player.play()
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}

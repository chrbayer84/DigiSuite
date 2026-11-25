import AVFoundation
import Combine
import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class RadioModemViewModel: ObservableObject {
    @Published var status: ModemStatus = .idle
    @Published var listening = false
    @Published var transmitting = false
    @Published var selectedMode: RadioModeID = .robot36
    @Published var liveImage: UIImage?
    @Published private(set) var pictureOffsetHz = 0
    @Published var waterfallRows: [[Float]] = []
    @Published var inputName = "No input"
    @Published var errorMessage: String?
    @Published var pttToneEnabled: Bool = UserDefaults.standard.bool(forKey: "pttToneEnabled") {
        didSet { UserDefaults.standard.set(pttToneEnabled, forKey: "pttToneEnabled") }
    }
    @Published var pttToneFrequency: Double = {
        let stored = UserDefaults.standard.double(forKey: "pttToneFrequency")
        return (1000...15000).contains(stored) ? stored : 3000
    }() {
        didSet { UserDefaults.standard.set(pttToneFrequency, forKey: "pttToneFrequency") }
    }

    let history = RadioHistoryStore()
    private let capture = RadioAudioCaptureService()
    private let player = RadioAudioPlayer()
    private let transmitter = Robot36Transmitter()
    private let receivePipeline = RadioReceivePipeline()
    private var activePictureID: UUID?
    private var imageBytes = Data(repeating: 0, count: 320 * 240 * 4)

    init() {
        let pipeline = receivePipeline
        capture.onAudio = { [weak self] chunk in
            let output = pipeline.process(chunk)
            DispatchQueue.main.async {
                guard let self else { return }
                for row in output.spectrumRows {
                    self.waterfallRows.insert(row.decibels, at: 0)
                    if self.waterfallRows.count > 180 { self.waterfallRows.removeLast(self.waterfallRows.count - 180) }
                }
                self.apply(output.events)
            }
        }
        capture.onError = { [weak self] message in
            DispatchQueue.main.async {
                self?.listening = false
                self?.status = .error(message)
                self?.errorMessage = message
            }
        }
        inputName = Self.activeInputName
    }

    deinit {
        capture.stop()
        player.stop()
    }

    private static var activeInputName: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "No input selected"
    }

    func startReceive() {
        guard !listening else { return }
        guard selectedMode == .robot36 else { return }
        RadioAudioCaptureService.requestPermission { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                guard allowed else {
                    self.errorMessage = "Microphone access is required to receive SSTV. Enable it in Settings."
                    self.status = .error("Microphone permission denied")
                    return
                }
                self.receivePipeline.reset()
                self.waterfallRows.removeAll()
                self.activePictureID = nil
                self.capture.start { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        switch result {
                        case .success:
                            self.inputName = Self.activeInputName
                            self.listening = true
                            self.status = .listening
                        case .failure(let error):
                            self.errorMessage = error.localizedDescription
                            self.status = .error(error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    func stopReceive() {
        capture.stop()
        receivePipeline.reset()
        listening = false
        status = .idle
    }

    func clearReceive() {
        receivePipeline.reset()
        activePictureID = nil
        liveImage = nil
        imageBytes = Data(repeating: 0, count: 320 * 240 * 4)
        waterfallRows.removeAll()
        status = listening ? .listening : .idle
    }

    func transmit(image: UIImage) {
        guard selectedMode == .robot36, !transmitting else { return }
        if listening { stopReceive() }
        guard let rgba = Self.rgbaData(image, width: 320, height: 240) else {
            errorMessage = "Could not prepare the selected image for Robot 36."
            return
        }
        transmitting = true
        status = .synchronizing
        let transmitter = self.transmitter
        let rightToneHz: Double? = pttToneEnabled ? pttToneFrequency : nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self, transmitter] in
            let samples = (try? transmitter.encode(rgba, sampleRate: 12_000, amplitude: 0.35)) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.transmitting else { return }
                guard !samples.isEmpty else {
                    self.transmitting = false
                    self.errorMessage = "Could not encode the Robot 36 image."
                    return
                }
                self.status = .receiving(mode: "Transmitting Robot 36", line: 0, totalLines: 240)
                self.player.play(left: samples, rightToneHz: rightToneHz, sampleRate: 12_000,
                                 completion: { [weak self] in
                                     DispatchQueue.main.async {
                                         self?.transmitting = false
                                         self?.status = .complete("Robot 36 audio sent")
                                     }
                                 },
                                 failure: { [weak self] error in
                                     DispatchQueue.main.async {
                                         self?.transmitting = false
                                         self?.errorMessage = error.localizedDescription
                                         self?.status = .error(error.localizedDescription)
                                     }
                                 })
            }
        }
    }

    func stopTransmit() {
        player.stop()
        transmitting = false
        status = listening ? .listening : .idle
    }

    private func apply(_ events: [ReceiveEvent]) {
        for event in events {
            switch event {
            case .status(let newStatus): status = newStatus
            case .pictureStarted(let id, _, _, _, let offset):
                activePictureID = id
                pictureOffsetHz = offset
                imageBytes = Data(repeating: 0, count: 320 * 240 * 4)
                liveImage = nil
            case .pictureRows(let id, let from, let count, let rgba):
                guard id == activePictureID else { continue }
                let start = from * 320 * 4
                let end = min(imageBytes.count, start + count * 320 * 4)
                if end > start, rgba.count >= end - start {
                    imageBytes.replaceSubrange(start..<end, with: rgba.prefix(end - start))
                    liveImage = Self.makeImage(imageBytes, width: 320, height: 240)
                }
            case .pictureFinished(let picture):
                activePictureID = nil
                history.add(.picture(picture))
            }
        }
    }

    private static func rgbaData(_ image: UIImage, width: Int, height: Int) -> Data? {
        guard let source = image.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let didDraw = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(data: rawBuffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }
        return Data(bytes)
    }

    static func makeImage(_ data: Data, width: Int, height: Int) -> UIImage? {
        guard data.count >= width * height * 4,
              let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct RadioModemRootView: View {
    @StateObject private var model = RadioModemViewModel()

    var body: some View {
        TabView {
            ReceiveTab(model: model)
                .tabItem { Label("Receive", systemImage: "waveform") }
            TransmitTab(model: model)
                .tabItem { Label("Transmit", systemImage: "antenna.radiowaves.left.and.right") }
            HistoryTab(store: model.history)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            SettingsTab(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.cyan)
        .preferredColorScheme(.dark)
        .alert("Radio Modem", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if model.listening { model.stopReceive() }
            if model.transmitting { model.stopTransmit() }
        }
    }
}

private struct ReceiveTab: View {
    @ObservedObject var model: RadioModemViewModel
    @State private var mode: RadioModeID = .robot36

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    Picker("Mode", selection: $mode) {
                        ForEach(ModemDescriptor.all) { modem in
                            Text(modem.id.title).tag(modem.id).disabled(!modem.receiveEnabled)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: mode) { _, value in model.selectedMode = value }
                    Spacer()
                    Button(model.listening ? "Stop" : "Receive") {
                        model.listening ? model.stopReceive() : model.startReceive()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.listening ? .orange : .cyan)
                    Button("Clear", systemImage: "trash") { model.clearReceive() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                }
                HStack {
                    Circle().fill(model.listening ? .green : .gray).frame(width: 8, height: 8)
                    Text(statusLabel(model.status)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Label(model.inputName, systemImage: "mic.fill")
                        .font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                    if geometry.size.width >= 680 {
                        HStack(spacing: 12) { picturePane; waterfallPane }
                    } else {
                        VStack(spacing: 12) { picturePane; waterfallPane }
                    }
                }
            }
            .padding()
            .navigationTitle("Radio Modem")
        }
    }

    private var picturePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            paneTitle("Robot 36", detail: model.liveImage == nil ? "Waiting for VIS 8" : "320 × 240 · offset \(model.pictureOffsetHz) Hz")
            ZStack {
                Color.black
                if let image = model.liveImage {
                    Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo").font(.system(size: 42)).foregroundStyle(.gray)
                        Text("Received SSTV image appears here").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var waterfallPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            paneTitle("Audio Waterfall", detail: "0–3 kHz · newest at top")
            WaterfallCanvas(rows: model.waterfallRows)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)))
                .overlay(alignment: .bottom) {
                    HStack { Text("0 Hz"); Spacer(); Text("1.5 kHz"); Spacer(); Text("3 kHz") }
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                        .padding(5).background(.black.opacity(0.45))
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func paneTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer(minLength: 8)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func statusLabel(_ status: ModemStatus) -> String {
        switch status {
        case .idle: return "Idle"
        case .listening: return "Listening for Robot 36"
        case .synchronizing: return "Synchronizing"
        case .receiving(let mode, let line, let total): return "\(mode) · line \(line)/\(total)"
        case .complete(let text): return text
        case .error(let text): return text
        }
    }
}

private struct WaterfallCanvas: View {
    let rows: [[Float]]

    var body: some View {
        Canvas { context, size in
            guard !rows.isEmpty else { context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black)); return }
            let rowHeight = size.height / CGFloat(max(1, rows.count))
            for (rowIndex, row) in rows.enumerated() {
                let binWidth = size.width / CGFloat(max(1, row.count))
                for (binIndex, value) in row.enumerated() {
                    let rgb = WaterfallPalette.color(level: value)
                    let rect = CGRect(x: CGFloat(binIndex) * binWidth, y: CGFloat(rowIndex) * rowHeight,
                                      width: binWidth + 0.5, height: rowHeight + 0.5)
                    context.fill(Path(rect), with: .color(Color(.sRGB, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z), opacity: 1)))
                }
            }
        }
        .background(.black)
    }
}

private struct TransmitTab: View {
    @ObservedObject var model: RadioModemViewModel
    @State private var selection: PhotosPickerItem?
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            Form {
                Section("Mode") {
                    Picker("Transmit mode", selection: $model.selectedMode) {
                        ForEach(ModemDescriptor.all) { modem in
                            Text(modem.id.title).tag(modem.id).disabled(!modem.transmitEnabled)
                        }
                    }
                }
                Section("Robot 36 image") {
                    PhotosPicker(selection: $selection, matching: .images) {
                        Label(image == nil ? "Choose image" : "Choose another image", systemImage: "photo")
                    }
                    if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220) }
                }
                Section("PTT tone (right channel)") {
                    Toggle("Enable PTT tone", isOn: $model.pttToneEnabled)
                    if model.pttToneEnabled {
                        VStack(alignment: .leading, spacing: 4) {
                            Slider(value: $model.pttToneFrequency, in: 1000...15000, step: 100)
                            Text("Frequency: \(Int(model.pttToneFrequency)) Hz")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("The payload is sent on the left channel; a sine tone on the right channel keys VOX PTT, e.g. with a DigiRig smartphone cable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(model.transmitting ? "Stop transmission" : "Transmit audio") {
                        if model.transmitting { model.stopTransmit() }
                        else if let image { model.transmit(image: image) }
                    }
                    .disabled(image == nil && !model.transmitting)
                    Text("Audio plays through the active iOS output route. Radio PTT is not configured.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Transmit")
            .onChange(of: selection) { _, item in
                Task {
                    guard let item else { return }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self),
                              let loaded = UIImage(data: data) else { return }
                        image = loaded
                    } catch { }
                }
            }
        }
    }
}

private struct HistoryTab: View {
    @ObservedObject var store: RadioHistoryStore

    var body: some View {
        NavigationStack {
            List {
                if store.items.isEmpty {
                    ContentUnavailableView("No history yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Decoded messages and received pictures will appear here."))
                }
                ForEach(store.items) { item in
                    switch item {
                    case .picture(let picture):
                        HStack(spacing: 12) {
                            if let thumbnail = RadioModemViewModel.makeImage(picture.rgba, width: picture.width, height: picture.height) {
                                Image(uiImage: thumbnail).resizable().scaledToFit().frame(width: 80, height: 60).background(.black)
                            }
                            VStack(alignment: .leading) {
                                Text("Robot 36 SSTV").font(.headline)
                                Text(picture.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    case .text(let message):
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.text)
                            Text("\(message.mode.title) · \(message.receivedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let selected = offsets.map { store.items[$0] }
                    for item in selected { store.delete(item) }
                }
            }
            .navigationTitle("History")
        }
    }
}

private struct SettingsTab: View {
    @ObservedObject var model: RadioModemViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Audio") {
                    LabeledContent("Input", value: model.inputName)
                    LabeledContent("Receive rate", value: "12 kHz mono")
                    Text("The app uses the active iOS audio route. Connect a headset or audio interface before starting reception.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("History") {
                    LabeledContent("Storage", value: "On this device")
                    LabeledContent("Text modem history", value: "Ready for future modes")
                }
                Section("Modems") {
                    LabeledContent("Robot 36 SSTV", value: "Receive and transmit")
                    LabeledContent("FT8 / RTTY", value: "Architecture reserved")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

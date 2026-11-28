import AVFoundation
import Combine
import CoreLocation
import PhotosUI
import SwiftUI
import UIKit

struct TextOverlayConfig: Equatable {
    var message = ""
    var color: Color = .white
    var fontName = "Menlo"
    var fontSize: Double = 14
    var style: OverlayFontStyle = .bold
    var headerPosition = CGPoint(x: 0.04, y: 0.04)

    static let fontOptions = ["Menlo", "Courier", "Courier New", "Helvetica", "Georgia"]

    func font() -> UIFont {
        let size = CGFloat(fontSize)
        let base = UIFont(name: fontName, size: size)
            ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if style == .bold || style == .boldItalic { traits.insert(.traitBold) }
        if style == .italic || style == .boldItalic { traits.insert(.traitItalic) }
        guard !traits.isEmpty, let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

enum OverlayFontStyle: String, CaseIterable {
    case regular = "Regular"
    case bold = "Bold"
    case italic = "Italic"
    case boldItalic = "Bold Italic"
}

final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var completion: ((Result<String, Error>) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestGridSquare(completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(LocationError.permissionDenied))
        @unknown default:
            finish(.failure(LocationError.permissionDenied))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(LocationError.permissionDenied))
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let grid = Maidenhead.gridSquare(latitude: location.coordinate.latitude,
                                         longitude: location.coordinate.longitude)
        finish(.success(grid))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<String, Error>) {
        completion?(result)
        completion = nil
    }
}

enum LocationError: LocalizedError {
    case permissionDenied
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Location permission is required to determine your grid square."
        }
    }
}

@MainActor
final class RadioModemViewModel: ObservableObject {
    @Published var status: ModemStatus = .idle
    @Published var listening = false
    @Published var transmitting = false
    @Published var selectedMode: RadioModeID = .robot36
    @Published var liveImage: UIImage?
    @Published private(set) var pictureOffsetHz = 0
    @Published var waterfallRows: [[Float]] = []
    @Published var decodedMessages: [DecodedText] = []
    @Published var inputName = "No input"
    @Published var errorMessage: String?
    @Published var pttToneEnabled: Bool = UserDefaults.standard.bool(forKey: "pttToneEnabled") {
        didSet { UserDefaults.standard.set(pttToneEnabled, forKey: "pttToneEnabled") }
    }
    @Published var pttToneFrequency: Double = {
        let stored = UserDefaults.standard.double(forKey: "pttToneFrequency")
        return (1000...15000).contains(stored) ? stored : 1000
    }() {
        didSet { UserDefaults.standard.set(pttToneFrequency, forKey: "pttToneFrequency") }
    }
    @Published var callsign: String = UserDefaults.standard.string(forKey: "operatorCallsign") ?? "" {
        didSet { UserDefaults.standard.set(callsign, forKey: "operatorCallsign") }
    }
    @Published var gridsquare: String = UserDefaults.standard.string(forKey: "operatorGridsquare") ?? "" {
        didSet { UserDefaults.standard.set(gridsquare, forKey: "operatorGridsquare") }
    }
    @Published var isResolvingLocation = false
    @Published var locationError: String?
    @Published var dxCallsign = ""
    @Published var report = "-05"
    @Published var txMessageNumber = 1
    @Published private(set) var selectedTab = 0

    var ft8TXMessage: String { ft8Message(for: txMessageNumber) }

    /// TX1–TX6 templates, filled with my call/grid, the DX call and the report.
    func ft8Message(for number: Int) -> String {
        let my = callsign.trimmingCharacters(in: .whitespaces)
        let myCall = my.isEmpty ? "<MYCALL>" : my
        let gridRaw = gridsquare.trimmingCharacters(in: .whitespaces)
        let grid = gridRaw.isEmpty ? "<MYGRID>" : gridRaw
        let dxRaw = dxCallsign.trimmingCharacters(in: .whitespaces)
        let dx = dxRaw.isEmpty ? "<DXCALL>" : dxRaw.uppercased()
        let rptRaw = report.trimmingCharacters(in: .whitespaces)
        let rpt = rptRaw.isEmpty ? "-05" : rptRaw
        switch number {
        case 1: return "CQ \(myCall) \(grid)"
        case 2: return "\(dx) \(myCall) \(rpt)"
        case 3: return "\(dx) \(myCall) R\(rpt)"
        case 4: return "\(dx) \(myCall) RR73"
        case 5: return "\(dx) \(myCall) 73"
        default: return "CQ DX \(myCall) \(grid)"
        }
    }

    func selectTab(_ index: Int) {
        selectedTab = index
    }

    /// Tapping a decoded message fills the DX callsign and report, then shows Transmit.
    /// The state changes and tab switch run without animation so the tab transition
    /// does not animate simultaneously with the Transmit form's layout change.
    func prepareReply(to message: DecodedText) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let dx = Self.extractDXCallsign(from: message.text, myCall: callsign) {
                dxCallsign = dx
            }
            if let snr = message.snr {
                report = String(format: "%+03d", Int32(clamping: snr))
            }
            txMessageNumber = 2
            selectedTab = 1
        }
    }

    static func extractDXCallsign(from text: String, myCall: String) -> String? {
        let tokens = text.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }
        if tokens[0] == "CQ" {
            for token in tokens.dropFirst() where isCallsignLike(token) {
                return token.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            }
            return nil
        }
        if tokens.count >= 2 {
            let sender = tokens[1]
            let chosen = (sender == myCall && !tokens[0].isEmpty) ? tokens[0] : sender
            return chosen.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        }
        return nil
    }

    private static func isCallsignLike(_ token: String) -> Bool {
        let stripped = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let chars = Array(stripped)
        guard chars.contains(where: { $0.isLetter }), chars.contains(where: { $0.isNumber }) else { return false }
        if chars.count == 4,
           chars[0] >= "A", chars[0] <= "R",
           chars[1] >= "A", chars[1] <= "R",
           chars[2].isNumber, chars[3].isNumber {
            return false  // a grid square, not a callsign
        }
        return true
    }

    let history = RadioHistoryStore()
    private let capture = RadioAudioCaptureService()
    private let player = RadioAudioPlayer()
    private let transmitter = Robot36Transmitter()
    private let ft8Transmitter = FT8Transmitter()
    private let receivePipeline = RadioReceivePipeline()
    private let locationService = LocationService()
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
                guard let self else { return }
                self.apply(self.receivePipeline.reset())
                self.listening = false
                self.status = .error(message)
                self.errorMessage = message
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
        guard selectedMode.supportsReceive else { return }
        RadioAudioCaptureService.requestPermission { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                guard allowed else {
                    self.errorMessage = "Microphone access is required to receive. Enable it in Settings."
                    self.status = .error("Microphone permission denied")
                    return
                }
                self.receivePipeline.setMode(self.selectedMode)
                self.apply(self.receivePipeline.reset())
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
        apply(receivePipeline.reset())
        listening = false
        status = .idle
    }

    func clearReceive() {
        apply(receivePipeline.reset())
        activePictureID = nil
        liveImage = nil
        imageBytes = Data(repeating: 0, count: 320 * 240 * 4)
        decodedMessages.removeAll()
        waterfallRows.removeAll()
        status = listening ? .listening : .idle
    }

    func useCurrentLocation() {
        guard !isResolvingLocation else { return }
        isResolvingLocation = true
        locationError = nil
        locationService.requestGridSquare { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isResolvingLocation = false
                switch result {
                case .success(let grid):
                    self.gridsquare = grid
                case .failure(let error):
                    self.locationError = error.localizedDescription
                }
            }
        }
    }

    func transmit(image: UIImage, overlay: TextOverlayConfig) {
        guard selectedMode == .robot36, !transmitting else { return }
        if listening { stopReceive() }
        guard let rgba = Self.overlayRGBA(base: image, config: overlay,
                                          callsign: callsign, gridsquare: gridsquare) else {
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

    func transmitFT8(message: String) {
        guard selectedMode == .ft8, !transmitting else { return }
        if listening { stopReceive() }
        transmitting = true
        status = .synchronizing
        let transmitter = self.ft8Transmitter
        let rightToneHz: Double? = pttToneEnabled ? pttToneFrequency : nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self, transmitter] in
            let samples = (try? transmitter.encode(message, sampleRate: 12_000, amplitude: 0.35)) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.transmitting else { return }
                guard !samples.isEmpty else {
                    self.transmitting = false
                    self.errorMessage = "Could not encode the FT8 message."
                    return
                }
                let now = Date().timeIntervalSince1970
                let boundary = ceil(now / 15.0) * 15.0
                let delay = max(0, boundary - now)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.transmitting else { return }
                    self.status = .receiving(mode: "Transmitting FT8", line: 0, totalLines: 0)
                    self.player.play(left: samples, rightToneHz: rightToneHz, sampleRate: 12_000,
                                     completion: { [weak self] in
                                         DispatchQueue.main.async {
                                             self?.transmitting = false
                                             self?.status = .complete("FT8 message sent")
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
                liveImage = Self.makeImage(picture.rgba, width: picture.width, height: picture.height)
                history.add(.picture(picture))
            case .decodedText(let message):
                decodedMessages.append(message)
                history.add(.text(message))
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

    /// Composes the transmit image with the configured overlay text, returning
    /// Robot 36-sized RGBA bytes.
    private static func overlayRGBA(base: UIImage, config: TextOverlayConfig,
                                    callsign rawCallsign: String, gridsquare rawGridsquare: String) -> Data? {
        let width = 320
        let height = 240
        let callsign = rawCallsign.trimmingCharacters(in: .whitespaces)
        let gridsquare = rawGridsquare.trimmingCharacters(in: .whitespaces)
        let message = config.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callsign.isEmpty || !gridsquare.isEmpty || !message.isEmpty else {
            return rgbaData(base, width: width, height: height)
        }
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let textColor = UIColor(config.color)
        let headerFont = config.font()
        let messageFont = UIFont(descriptor: config.font().fontDescriptor, size: max(9, CGFloat(config.fontSize) - 2))
        let composed = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            base.draw(in: CGRect(origin: .zero, size: size))
            let origin = CGPoint(x: config.headerPosition.x * CGFloat(width),
                                 y: config.headerPosition.y * CGFloat(height))
            var nextY = origin.y
            let lineAttrs: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: textColor]
            if !callsign.isEmpty {
                let textSize = callsign.size(withAttributes: lineAttrs)
                context.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
                context.cgContext.fill(CGRect(x: origin.x - 4, y: nextY - 2,
                                              width: textSize.width + 8, height: textSize.height + 4))
                callsign.draw(at: CGPoint(x: origin.x, y: nextY), withAttributes: lineAttrs)
                nextY += textSize.height + 4
            }
            if !gridsquare.isEmpty {
                let textSize = gridsquare.size(withAttributes: lineAttrs)
                context.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
                context.cgContext.fill(CGRect(x: origin.x - 4, y: nextY - 2,
                                              width: textSize.width + 8, height: textSize.height + 4))
                gridsquare.draw(at: CGPoint(x: origin.x, y: nextY), withAttributes: lineAttrs)
                nextY += textSize.height + 4
            }
            if !message.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: messageFont, .foregroundColor: textColor]
                let availableWidth = CGFloat(width) - max(4, origin.x)
                let bounding = CGSize(width: availableWidth, height: CGFloat(height) - nextY)
                let messageRect = message.boundingRect(with: bounding,
                                                       options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                       attributes: attrs, context: nil)
                context.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
                context.cgContext.fill(CGRect(x: origin.x - 4, y: nextY - 2,
                                              width: min(messageRect.width + 8, availableWidth),
                                              height: messageRect.height + 4))
                message.draw(with: CGRect(x: origin.x, y: nextY, width: availableWidth, height: CGFloat(height) - nextY),
                             options: [.usesLineFragmentOrigin, .usesFontLeading],
                             attributes: attrs, context: nil)
            }
        }
        return rgbaData(composed, width: width, height: height)
    }

    static func overlayPreview(base: UIImage, config: TextOverlayConfig,
                              callsign: String, gridsquare: String) -> UIImage? {
        guard let rgba = overlayRGBA(base: base, config: config,
                                    callsign: callsign, gridsquare: gridsquare) else { return nil }
        return makeImage(rgba, width: 320, height: 240)
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
        TabView(selection: Binding(
            get: { model.selectedTab },
            set: { model.selectTab($0) }
        )) {
            ReceiveTab(model: model, onSelectMessage: { model.prepareReply(to: $0) })
                .tabItem { Label("Receive", systemImage: "waveform") }
                .tag(0)
            TransmitTab(model: model)
                .tabItem { Label("Transmit", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(1)
            HistoryTab(store: model.history)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(2)
            SettingsTab(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)
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

private struct UTCClock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(context.date))
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private static func format(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02dz",
                      Int32(parts.hour ?? 0), Int32(parts.minute ?? 0), Int32(parts.second ?? 0))
    }
}

/// RX/TX button label that clearly indicates the active (listening/transmitting)
/// state: muted when idle, vivid with a white ring and glow when active.
private struct RadioButtonLabel: View {
    let text: String
    let isActive: Bool
    let color: Color
    var fillWidth: Bool = false

    var body: some View {
        Text(text)
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .frame(minWidth: fillWidth ? nil : 56, maxWidth: fillWidth ? .infinity : nil)
            .padding(.vertical, fillWidth ? 10 : 8)
            .padding(.horizontal, fillWidth ? 0 : 14)
            .background(isActive ? color : color.opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white, lineWidth: isActive ? 2 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: isActive ? color.opacity(0.8) : .clear, radius: isActive ? 6 : 0)
            // Change state instantly; animating the label under an ambient animation
            // (e.g. a tab transition) makes UIKit log layout "decomposition" warnings.
            .animation(nil, value: isActive)
    }
}

private struct ReceiveTab: View {
    @ObservedObject var model: RadioModemViewModel
    var onSelectMessage: (DecodedText) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    Picker("Mode", selection: $model.selectedMode) {
                        ForEach(ModemDescriptor.all) { modem in
                            Text(modem.id.title).tag(modem.id).disabled(!modem.receiveEnabled)
                        }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                    Button {
                        model.listening ? model.stopReceive() : model.startReceive()
                    } label: {
                        RadioButtonLabel(text: "RX", isActive: model.listening, color: .green)
                    }
                    .buttonStyle(.plain)
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
                        HStack(spacing: 12) { outputPane; waterfallPane }
                    } else {
                        VStack(spacing: 12) { outputPane; waterfallPane }
                    }
                }
            }
            .padding()
            .navigationTitle("Radio Modem")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    UTCClock()
                }
            }
        }
    }

    @ViewBuilder
    private var outputPane: some View {
        if model.selectedMode.isTextMode {
            textPane
        } else {
            picturePane
        }
    }

    private var textPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            paneTitle("Decoded", detail: model.decodedMessages.isEmpty ? "Waiting for a message" : "\(model.decodedMessages.count) message(s)")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.decodedMessages) { message in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(message.receivedAt.formatted(date: .omitted, time: .standard))
                                .font(.caption).foregroundStyle(.gray).monospacedDigit()
                            if let snr = message.snr {
                                Text("\(snr) dB")
                                    .font(.caption).foregroundStyle(.gray).monospacedDigit()
                                    .frame(minWidth: 44, alignment: .trailing)
                            }
                            Text(Self.highlighted(message.text, myCall: model.callsign))
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelectMessage(message) }
                    }
                }
                .padding(10)
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Renders the message with the operator's own callsign highlighted red (white
    /// text), as WSJT-X does for messages mentioning your call.
    static func highlighted(_ text: String, myCall: String) -> AttributedString {
        let target = myCall.trimmingCharacters(in: .whitespaces).uppercased()
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false)
        var result = AttributedString("")
        for (index, token) in tokens.enumerated() {
            var piece = AttributedString(String(token))
            let bare = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            if !target.isEmpty && bare.uppercased() == target {
                piece.backgroundColor = .red
                piece.foregroundColor = .white
            } else {
                piece.foregroundColor = .black
            }
            result.append(piece)
            if index < tokens.count - 1 {
                var space = AttributedString(" ")
                space.foregroundColor = .black
                result.append(space)
            }
        }
        return result
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
        case .listening: return "Listening for \(model.selectedMode.title)"
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
    @State private var overlay = TextOverlayConfig()
    @State private var showOverlayEditor = false

    private var preview: UIImage? {
        guard let image else { return nil }
        return RadioModemViewModel.overlayPreview(base: image, config: overlay,
                                                 callsign: model.callsign, gridsquare: model.gridsquare)
    }

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

                if model.selectedMode == .ft8 {
                    Section("FT8 message") {
                        Picker("TX message", selection: $model.txMessageNumber) {
                            ForEach(1...6, id: \.self) { number in
                                Text(model.ft8Message(for: number)).tag(number)
                            }
                        }
                        TextField("DX callsign", text: $model.dxCallsign)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        TextField("Report", text: $model.report)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text(model.ft8TXMessage)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("Transmitted at the next 15-second UTC slot. Tap a decoded message to fill the DX call and report.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Robot 36 image") {
                        PhotosPicker(selection: $selection, matching: .images) {
                            Label(image == nil ? "Choose image" : "Choose another image", systemImage: "photo")
                        }
                        if let preview {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Preview").font(.caption).foregroundStyle(.secondary)
                                Image(uiImage: preview).resizable().aspectRatio(4.0/3.0, contentMode: .fit)
                            }
                        }
                    }
                    Section {
                        Button {
                            showOverlayEditor = true
                        } label: {
                            Label("Edit overlay", systemImage: "textformat")
                        }
                        .disabled(image == nil)
                    }
                }

                Section {
                    Button {
                        if model.transmitting {
                            model.stopTransmit()
                        } else if model.selectedMode == .ft8 {
                            model.transmitFT8(message: model.ft8TXMessage)
                        } else if let image {
                            model.transmit(image: image, overlay: overlay)
                        }
                    } label: {
                        RadioButtonLabel(text: "TX", isActive: model.transmitting, color: .red, fillWidth: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.transmitting && (
                        (model.selectedMode == .robot36 && image == nil) ||
                        (model.selectedMode == .ft8 && model.callsign.trimmingCharacters(in: .whitespaces).isEmpty)
                    ))
                    Text("Audio plays through the active iOS output route. Radio PTT is not configured.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Transmit")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    UTCClock()
                }
            }
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
            .sheet(isPresented: $showOverlayEditor) {
                OverlayEditorView(config: $overlay, base: image, model: model)
            }
        }
    }
}

private struct OverlayEditorView: View {
    @Binding var config: TextOverlayConfig
    let base: UIImage?
    @ObservedObject var model: RadioModemViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextField("Callsign", text: $model.callsign)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Grid square", text: $model.gridsquare)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button {
                        model.useCurrentLocation()
                    } label: {
                        if model.isResolvingLocation {
                            Label("Locating…", systemImage: "location")
                        } else {
                            Label("Use current location", systemImage: "location")
                        }
                    }
                    .disabled(model.isResolvingLocation)
                    if let locationError = model.locationError {
                        Text(locationError).font(.caption).foregroundStyle(.red)
                    }
                    TextField("Message", text: $config.message, axis: .vertical)
                        .lineLimit(2...5)
                    Text("Callsign and grid square are shared across all modes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Appearance") {
                    ColorPicker("Color", selection: $config.color, supportsOpacity: false)
                    Picker("Font", selection: $config.fontName) {
                        ForEach(TextOverlayConfig.fontOptions, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    Picker("Style", selection: $config.style) {
                        ForEach(OverlayFontStyle.allCases, id: \.self) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    Slider(value: $config.fontSize, in: 8...48, step: 1) {
                        Text("Size \(Int(config.fontSize))")
                    } minimumValueLabel: {
                        Text("8").font(.caption)
                    } maximumValueLabel: {
                        Text("48").font(.caption)
                    }
                }
                Section("Position") {
                    if let base {
                        OverlayPreview(base: base, config: $config,
                                       callsign: model.callsign, gridsquare: model.gridsquare)
                            .frame(height: 220)
                    } else {
                        Text("Choose an image first.").foregroundStyle(.secondary)
                    }
                    Text("Drag the marker on the preview to move the callsign/grid square.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Overlay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct OverlayPreview: View {
    let base: UIImage
    @Binding var config: TextOverlayConfig
    let callsign: String
    let gridsquare: String

    var body: some View {
        let preview = RadioModemViewModel.overlayPreview(base: base, config: config,
                                                        callsign: callsign, gridsquare: gridsquare) ?? base
        return GeometryReader { geo in
            Image(uiImage: preview)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(.orange)
                        .frame(width: 18, height: 18)
                        .offset(x: config.headerPosition.x * geo.size.width - 9,
                                y: config.headerPosition.y * geo.size.height - 9)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            config.headerPosition = CGPoint(
                                x: min(1, max(0, value.location.x / geo.size.width)),
                                y: min(1, max(0, value.location.y / geo.size.height))
                            )
                        }
                )
        }
        .aspectRatio(4.0/3.0, contentMode: .fit)
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
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Robot 36 SSTV").font(.headline)
                                    if !picture.complete {
                                        Text("Partial").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(.orange.opacity(0.25)).foregroundStyle(.orange).clipShape(Capsule())
                                    }
                                }
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
                Section("Operator") {
                    TextField("Callsign", text: $model.callsign)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Grid square", text: $model.gridsquare)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button {
                        model.useCurrentLocation()
                    } label: {
                        if model.isResolvingLocation {
                            Label("Locating…", systemImage: "location")
                        } else {
                            Label("Use current location", systemImage: "location")
                        }
                    }
                    .disabled(model.isResolvingLocation)
                    if let locationError = model.locationError {
                        Text(locationError).font(.caption).foregroundStyle(.red)
                    }
                    Text("Overlaid on transmitted pictures.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Audio") {
                    LabeledContent("Input", value: model.inputName)
                    LabeledContent("Receive rate", value: "12 kHz mono")
                    Text("The app uses the active iOS audio route. Connect a headset or audio interface before starting reception.")
                        .font(.caption).foregroundStyle(.secondary)
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
                Section("History") {
                    LabeledContent("Storage", value: "On this device")
                    LabeledContent("Text modem history", value: "Decoded FT8 messages are stored locally")
                }
                Section("Modems") {
                    LabeledContent("Robot 36 SSTV", value: "Receive and transmit")
                    LabeledContent("FT8", value: "Receive and transmit")
                    LabeledContent("RTTY", value: "Architecture reserved")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

import Foundation

enum RadioModeID: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case robot36
    case ft8
    case rtty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .robot36: return "Robot 36 SSTV"
        case .ft8: return "FT8 (planned)"
        case .rtty: return "RTTY (planned)"
        }
    }

    var supportsReceive: Bool { self == .robot36 }
    var supportsTransmit: Bool { self == .robot36 }
}

struct ModemDescriptor: Identifiable, Hashable {
    let id: RadioModeID
    let outputKind: OutputKind
    let nominalSampleRate: Double
    let receiveEnabled: Bool
    let transmitEnabled: Bool

    enum OutputKind: Hashable {
        case picture
        case text
    }

    static let all: [ModemDescriptor] = [
        .init(id: .robot36, outputKind: .picture, nominalSampleRate: 12_000, receiveEnabled: true, transmitEnabled: true),
        .init(id: .ft8, outputKind: .text, nominalSampleRate: 12_000, receiveEnabled: false, transmitEnabled: false),
        .init(id: .rtty, outputKind: .text, nominalSampleRate: 12_000, receiveEnabled: false, transmitEnabled: false)
    ]
}

struct AudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let startSample: Int64
}

struct RadioPicture: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let mode: RadioModeID
    let startedAt: Date
    let width: Int
    let height: Int
    var rgba: Data
    var complete: Bool
    var frequencyOffsetHz: Int

    init(id: UUID = UUID(), mode: RadioModeID = .robot36, startedAt: Date = .now,
         width: Int = 320, height: Int = 240, rgba: Data, complete: Bool = false,
         frequencyOffsetHz: Int = 0) {
        self.id = id
        self.mode = mode
        self.startedAt = startedAt
        self.width = width
        self.height = height
        self.rgba = rgba
        self.complete = complete
        self.frequencyOffsetHz = frequencyOffsetHz
    }
}

struct DecodedText: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let mode: RadioModeID
    let receivedAt: Date
    let text: String
    var frequencyHz: Int?

    init(id: UUID = UUID(), mode: RadioModeID, receivedAt: Date = .now, text: String, frequencyHz: Int? = nil) {
        self.id = id
        self.mode = mode
        self.receivedAt = receivedAt
        self.text = text
        self.frequencyHz = frequencyHz
    }
}

enum ModemStatus: Equatable, Sendable {
    case idle
    case listening
    case synchronizing
    case receiving(mode: String, line: Int, totalLines: Int)
    case complete(String)
    case error(String)
}

enum ReceiveEvent: Sendable {
    case status(ModemStatus)
    case pictureStarted(id: UUID, title: String, width: Int, height: Int, offsetHz: Int)
    case pictureRows(id: UUID, from: Int, count: Int, rgba: Data)
    case pictureFinished(RadioPicture)
}

protocol ReceiveModem: AnyObject {
    var mode: RadioModeID { get }
    func consume(_ chunk: AudioChunk) -> [ReceiveEvent]
    func reset()
}

/// Transmitters keep payload types mode-specific while sharing the app's audio output path.
protocol TransmitModem {
    associatedtype Payload
    var mode: RadioModeID { get }
    func encode(_ payload: Payload, sampleRate: Double, amplitude: Float) throws -> [Float]
}

struct SpectrumRow: Equatable, Sendable {
    let decibels: [Float]
    let sampleTime: TimeInterval
}

enum RadioHistoryItem: Identifiable, Codable, Equatable {
    case picture(RadioPicture)
    case text(DecodedText)

    var id: UUID {
        switch self {
        case .picture(let picture): return picture.id
        case .text(let message): return message.id
        }
    }

    var date: Date {
        switch self {
        case .picture(let picture): return picture.startedAt
        case .text(let message): return message.receivedAt
        }
    }

    private enum CodingKeys: String, CodingKey { case type, picture, text }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "picture": self = .picture(try container.decode(RadioPicture.self, forKey: .picture))
        case "text": self = .text(try container.decode(DecodedText.self, forKey: .text))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown history item")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .picture(let picture):
            try container.encode("picture", forKey: .type)
            try container.encode(picture, forKey: .picture)
        case .text(let message):
            try container.encode("text", forKey: .type)
            try container.encode(message, forKey: .text)
        }
    }
}

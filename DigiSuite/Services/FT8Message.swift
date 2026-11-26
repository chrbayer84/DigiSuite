import Foundation

/// FT8 message packing/unpacking ported from GridTracker2's ft8_lib
/// (message.c, text.c, crc.c). Handles all standard message types and the
/// transitions between them (CQ, grid, signal reports, RRR/RR73/73, free text,
/// telemetry and non-standard calls). BSD-3-Clause.
enum FT8Message {
    static let payloadBytes = 10          // 77 bits
    static let maxTokens = 2063592
    static let max22 = 4194304
    static let maxGrid4 = 32400

    // MARK: - Character tables

    enum CharTable {
        case full                 // " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ+-./?"
        case alphanumSpaceSlash   // " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ/"
        case alphanumSpace        // " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        case lettersSpace         // " ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        case alphanum             // "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        case numeric              // "0123456789"
    }

    static func charn(_ c: Int, _ table: CharTable) -> Character {
        var c = c
        if table != .alphanum && table != .numeric {
            if c == 0 { return " " }
            c -= 1
        }
        if table != .lettersSpace {
            if c < 10 { return asciiChar(48 + c) }
            c -= 10
        }
        if table != .numeric {
            if c < 26 { return asciiChar(65 + c) }
            c -= 26
        }
        if table == .full {
            if c < 5 {
                let symbols = Array("+-./?")
                return symbols[c]
            }
        } else if table == .alphanumSpaceSlash {
            if c == 0 { return "/" }
        }
        return "_"
    }

    private static func asciiChar(_ code: Int) -> Character {
        return Character(UnicodeScalar(code)!)
    }

    static func nchar(_ char: Character, _ table: CharTable) -> Int {
        let c = char
        var n = 0
        if table != .alphanum && table != .numeric {
            if c == " " { return n }
            n += 1
        }
        if table != .lettersSpace {
            if c >= "0" && c <= "9" { return n + Int(c.asciiValue! - 48) }
            n += 10
        }
        if table != .numeric {
            if c >= "A" && c <= "Z" { return n + Int(c.asciiValue! - 65) }
            n += 26
        }
        if table == .full {
            let extra = Array("+-./?")
            for (i, e) in extra.enumerated() where c == e { return n + i }
        } else if table == .alphanumSpaceSlash {
            if c == "/" { return n }
        }
        return -1
    }

    // MARK: - CRC (CRC-14, polynomial 0x2757)

    static func computeCRC(_ message: [UInt8], numBits: Int) -> UInt16 {
        var remainder: UInt16 = 0
        let topBit: UInt16 = 1 << 13
        var byteIdx = 0
        for bit in 0..<numBits {
            if bit % 8 == 0 {
                remainder ^= UInt16(message[byteIdx]) << 6
                byteIdx += 1
            }
            if remainder & topBit != 0 {
                remainder = (remainder << 1) ^ FT8Constants.crcPolynomial
            } else {
                remainder <<= 1
            }
        }
        return remainder & ((topBit << 1) - 1)
    }

    static func extractCRC(_ a91: [UInt8]) -> UInt16 {
        return UInt16((a91[9] & 0x07) << 11) | UInt16(a91[10] << 3) | UInt16(a91[11] >> 5)
    }

    // MARK: - Payload field access

    static func i3(_ payload: [UInt8]) -> UInt8 {
        return (payload[9] >> 3) & 0x07
    }

    static func n3(_ payload: [UInt8]) -> UInt8 {
        return ((payload[8] << 2) & 0x04) | ((payload[9] >> 6) & 0x03)
    }

    // MARK: - Callsign hash

    static func saveCallsignHash(_ callsign: String) -> UInt32 {
        var n58: UInt64 = 0
        var i = 0
        let chars = Array(callsign)
        while i < chars.count && i < 11 {
            let j = nchar(chars[i], .alphanumSpaceSlash)
            if j < 0 { return 0 }
            n58 = 38 &* n58 &+ UInt64(j)
            i += 1
        }
        while i < 11 {
            n58 = 38 &* n58
            i += 1
        }
        let product = UInt64(47055833459) &* n58
        return UInt32((product >> 42) & 0x3FFFFF)
    }

    // MARK: - Basecall packing (28-bit standard callsign)

    static func packBasecall(_ callsign: String) -> Int32 {
        let chars = Array(callsign)
        let length = chars.count
        guard length > 2 else { return -1 }

        var c6: [Character] = [" ", " ", " ", " ", " ", " "]
        if callsign.hasPrefix("3DA0") && length > 4 && length <= 7 {
            c6 = Array("3D0" + callsign.dropFirst(4).prefix(3)).map { $0 }
            for _ in c6.count..<6 { c6.append(" ") }
        } else if callsign.hasPrefix("3X") && length >= 3 && isLetter(chars[2]) && length <= 7 {
            c6[0] = "Q"
            let rest = Array(callsign.dropFirst(2))
            for i in 0..<rest.count { c6[i + 1] = rest[i] }
        } else {
            if length >= 3 && isDigit(chars[2]) && length <= 6 {
                for i in 0..<length { c6[i] = chars[i] }
            } else if length >= 2 && isDigit(chars[1]) && length <= 5 {
                for i in 0..<length { c6[i + 1] = chars[i] }
            }
        }

        let i0 = nchar(c6[0], .alphanumSpace)
        let i1 = nchar(c6[1], .alphanum)
        let i2 = nchar(c6[2], .numeric)
        let i3 = nchar(c6[3], .lettersSpace)
        let i4 = nchar(c6[4], .lettersSpace)
        let i5 = nchar(c6[5], .lettersSpace)
        guard i0 >= 0, i1 >= 0, i2 >= 0, i3 >= 0, i4 >= 0, i5 >= 0 else { return -1 }

        var n = i0
        n = n * 36 + i1
        n = n * 10 + i2
        n = n * 27 + i3
        n = n * 27 + i4
        n = n * 27 + i5
        return Int32(n)
    }

    // MARK: - Unpacking (decode) - the core path for a receive modem

    static func unpack28(_ n28: UInt32, _ ip: UInt8, _ i3: UInt8, hashes: inout [UInt32: String]) -> String {
        var n28 = n28
        if n28 < UInt32(maxTokens) {
            if n28 <= 2 {
                return n28 == 0 ? "DE" : (n28 == 1 ? "QRZ" : "CQ")
            }
            if n28 <= 1002 {
                var s = "CQ "
                var v = Int(n28 - 3)
                var digits = [Int](repeating: 0, count: 3)
                for i in (0..<3).reversed() { digits[i] = v % 10; v /= 10 }
                for d in digits { s += String(d) }
                return s
            }
            if n28 <= 532443 {
                var n = n28 - 1003
                var aaaa: [Character] = [" ", " ", " ", " "]
                for i in (0..<4).reversed() {
                    aaaa[i] = charn(Int(n % 27), .lettersSpace)
                    n /= 27
                }
                let trimmed = String(aaaa).trimmingCharacters(in: .whitespaces)
                return "CQ " + trimmed
            }
            return ""
        }

        n28 -= UInt32(maxTokens)
        if n28 < UInt32(max22) {
            let hash = UInt32(n28)
            if let known = hashes[hash] {
                return "<" + known + ">"
            }
            return "<...>"
        }

        var n = n28 - UInt32(max22)
        var callsign: [Character] = [" ", " ", " ", " ", " ", " "]
        callsign[5] = charn(Int(n % 27), .lettersSpace); n /= 27
        callsign[4] = charn(Int(n % 27), .lettersSpace); n /= 27
        callsign[3] = charn(Int(n % 27), .lettersSpace); n /= 27
        callsign[2] = charn(Int(n % 10), .numeric); n /= 10
        callsign[1] = charn(Int(n % 36), .alphanum); n /= 36
        callsign[0] = charn(Int(n % 37), .alphanumSpace)

        var result: String
        let cs = String(callsign)
        if cs.hasPrefix("3D0") && cs.count > 3 && cs[cs.index(cs.startIndex, offsetBy: 3)] != " " {
            result = "3DA0" + String(cs.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if cs.hasPrefix("Q") && cs.count > 1 && isLetter(cs[cs.index(after: cs.startIndex)]) {
            result = "3X" + String(cs.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else {
            result = cs.trimmingCharacters(in: .whitespaces)
        }

        if result.count < 3 { return "" }
        if ip != 0 {
            if i3 == 1 { result += "/R" } else if i3 == 2 { result += "/P" }
        }
        hashes[saveCallsignHash(result)] = result
        return result
    }

    static func unpack58(_ n58: UInt64, hashes: inout [UInt32: String]) -> String {
        var n = n58
        var c11: [Character] = Array(repeating: " ", count: 11)
        for i in (0..<11).reversed() {
            c11[i] = charn(Int(n % 38), .alphanumSpaceSlash)
            n /= 38
        }
        let result = String(c11).trimmingCharacters(in: .whitespaces)
        if result.count >= 3 {
            hashes[saveCallsignHash(result)] = result
        }
        return result
    }

    static func unpackGrid(_ igrid4: UInt16, _ ir: UInt8) -> String {
        if igrid4 <= UInt16(maxGrid4) {
            var prefix = ""
            if ir > 0 { prefix = "R " }
            var n = Int(igrid4)
            let d3 = n % 10; n /= 10
            let d2 = n % 10; n /= 10
            let d1 = n % 18; n /= 18
            let d0 = n % 18
            return prefix + letter(65 + d0) + letter(65 + d1) + "\(d2)\(d3)"
        } else {
            let irpt = Int(igrid4) - maxGrid4
            switch irpt {
            case 1: return ""
            case 2: return "RRR"
            case 3: return "RR73"
            case 4: return "73"
            default:
                let report = irpt - 35
                let sign = report < 0 ? "-" : "+"
                let magnitude = Swift.abs(report)
                return (ir > 0 ? "R" : "") + sign + String(format: "%02d", Int32(magnitude))
            }
        }
    }

    private static func letter(_ code: Int) -> String {
        return String(UnicodeScalar(code)!)
    }

    // MARK: - Decode payload -> human-readable message

    static func decode(_ payload: [UInt8], hashes: inout [UInt32: String]) -> String {
        let type = i3(payload)
        switch type {
        case 0:
            let nt = n3(payload)
            if nt == 0 { return decodeFree(payload) }
            if nt == 5 { return decodeTelemetry(payload) }
            return ""   // DXpedition / EU VHF / ARRL FD / contesting not yet unpacked
        case 1, 2:
            return decodeStandard(payload, hashes: &hashes)
        case 4:
            return decodeNonstandard(payload, hashes: &hashes)
        default:
            return ""
        }
    }

    static func decodeStandard(_ payload: [UInt8], hashes: inout [UInt32: String]) -> String {
        var n29a: UInt32 = (UInt32(payload[0]) << 21)
        n29a |= UInt32(payload[1]) << 13
        n29a |= UInt32(payload[2]) << 5
        n29a |= UInt32(payload[3]) >> 3
        var n29b: UInt32 = UInt32(payload[3] & 0x07) << 26
        n29b |= UInt32(payload[4]) << 18
        n29b |= UInt32(payload[5]) << 10
        n29b |= UInt32(payload[6]) << 2
        n29b |= UInt32(payload[7]) >> 6
        let ir = (payload[7] & 0x20) >> 5
        var igrid4: UInt16 = UInt16(payload[7] & 0x1F) << 10
        igrid4 |= UInt16(payload[8]) << 2
        igrid4 |= UInt16(payload[9]) >> 6
        let i3v = i3(payload)

        let call1 = unpack28(n29a >> 1, UInt8(n29a & 1), i3v, hashes: &hashes)
        let call2 = unpack28(n29b >> 1, UInt8(n29b & 1), i3v, hashes: &hashes)
        let extra = unpackGrid(igrid4, ir)

        var parts = [call1, call2].filter { !$0.isEmpty }
        if !extra.isEmpty { parts.append(extra) }
        return parts.joined(separator: " ")
    }

    static func decodeNonstandard(_ payload: [UInt8], hashes: inout [UInt32: String]) -> String {
        var n12: UInt16 = UInt16(payload[0]) << 4
        n12 |= UInt16(payload[1]) >> 4
        var n58: UInt64 = UInt64(payload[1] & 0x0F) << 54
        n58 |= UInt64(payload[2]) << 46
        n58 |= UInt64(payload[3]) << 38
        n58 |= UInt64(payload[4]) << 30
        n58 |= UInt64(payload[5]) << 22
        n58 |= UInt64(payload[6]) << 14
        n58 |= UInt64(payload[7]) << 6
        n58 |= UInt64(payload[8]) >> 2
        let iflip = (payload[8] >> 1) & 0x01
        let nrpt = ((payload[8] & 0x01) << 1) | (payload[9] >> 7)
        let icq = (payload[9] >> 6) & 0x01

        let decodedCall = unpack58(n58, hashes: &hashes)
        let hashedCall: String
        let hash12 = UInt32(n12)
        if let known = hashes[hash12] {
            hashedCall = "<" + known + ">"
        } else {
            hashedCall = "<...>"
        }

        let call1 = iflip == 0 ? hashedCall : decodedCall
        let call2 = iflip == 0 ? decodedCall : hashedCall

        if icq == 0 {
            var extra = ""
            if nrpt == 1 { extra = "RRR" } else if nrpt == 2 { extra = "RR73" } else if nrpt == 3 { extra = "73" }
            var parts = [call1, call2]
            if !extra.isEmpty { parts.append(extra) }
            return parts.joined(separator: " ")
        } else {
            return "CQ " + call2
        }
    }

    static func decodeFree(_ payload: [UInt8]) -> String {
        var b71 = [UInt8](repeating: 0, count: 9)
        decodeTelemetryBits(payload, &b71)
        var result: [Character] = []
        for _ in 0..<13 {
            var rem: UInt16 = 0
            for i in 0..<9 {
                rem = (rem << 8) | UInt16(b71[i])
                b71[i] = UInt8(rem / 42)
                rem %= 42
            }
            result.append(charn(Int(rem), .full))
        }
        return String(result).trimmingCharacters(in: .whitespaces)
    }

    static func decodeTelemetry(_ payload: [UInt8]) -> String {
        var b71 = [UInt8](repeating: 0, count: 9)
        decodeTelemetryBits(payload, &b71)
        let hex = b71.map { String(format: "%02X", UInt32($0)) }.joined()
        return hex
    }

    private static func decodeTelemetryBits(_ payload: [UInt8], _ telemetry: inout [UInt8]) {
        var carry: UInt8 = 0
        for i in 0..<9 {
            telemetry[i] = (carry << 7) | (payload[i] >> 1)
            carry = payload[i] & 0x01
        }
    }

    private static func isDigit(_ c: Character) -> Bool {
        return c >= "0" && c <= "9"
    }

    private static func isLetter(_ c: Character) -> Bool {
        return (c >= "A" && c <= "Z") || (c >= "a" && c <= "z")
    }
}

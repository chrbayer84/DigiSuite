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
        return (UInt16(a91[9] & 0x07) << 11) | (UInt16(a91[10]) << 3) | UInt16(a91[11] >> 5)
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

    // MARK: - Encode text -> payload

    static func encode(_ text: String) -> [UInt8]? {
        let normalized = text.uppercased()
        var callTo = ""
        var callDe = ""
        var extra = ""
        var position: String

        if normalized.hasPrefix("CQ ") {
            position = String(normalized.dropFirst(3))
            if parseCQModifier(normalized) != nil {
                let arg = nextToken(&position)
                callTo = "CQ " + arg
            } else {
                callTo = "CQ"
            }
        } else {
            position = normalized
            callTo = nextToken(&position)
        }
        callDe = nextToken(&position)
        extra = nextToken(&position)

        if position.trimmingCharacters(in: .whitespaces).isEmpty {
            if let payload = encodeStandard(callTo, callDe, extra) { return payload }
            if let payload = encodeNonstandard(callTo, callDe, extra) { return payload }
        }
        return encodeFree(normalized)
    }

    private static func nextToken(_ position: inout String) -> String {
        let trimmed = position.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            position = ""
            return ""
        }
        if let space = trimmed.firstIndex(of: " ") {
            let token = String(trimmed[..<space])
            position = String(trimmed[trimmed.index(after: space)...])
            return token
        }
        let token = trimmed
        position = ""
        return token
    }

    private static func parseCQModifier(_ string: String) -> Int? {
        let chars = Array(string)
        guard chars.count > 3 else { return nil }
        var numDigits = 0
        var numLetters = 0
        var m = 0
        for i in 3..<8 {
            guard i < chars.count else { break }
            let c = chars[i]
            if c == " " { break }
            if isDigit(c) { numDigits += 1 }
            else if isLetter(c) {
                numLetters += 1
                m = 27 * m + Int(c.asciiValue! - 65 + 1)
            } else {
                return nil
            }
        }
        if numDigits == 3 && numLetters == 0 {
            var value = 0
            for i in 3..<6 where i < chars.count && isDigit(chars[i]) {
                value = value * 10 + Int(chars[i].asciiValue! - 48)
            }
            return value
        }
        if numDigits == 0 && numLetters > 0 && numLetters <= 4 {
            return 1000 + m
        }
        return nil
    }

    static func pack28(_ callsign: String) -> (UInt32, UInt8)? {
        if callsign == "DE" { return (0, 0) }
        if callsign == "QRZ" { return (1, 0) }
        if callsign == "CQ" { return (2, 0) }
        let length = callsign.count
        if callsign.hasPrefix("CQ ") && length < 8 {
            guard let v = parseCQModifier(callsign) else { return nil }
            return (UInt32(3 + v), 0)
        }
        var ip: UInt8 = 0
        var base = callsign
        if callsign.hasSuffix("/P") || callsign.hasSuffix("/R") {
            ip = 1
            base = String(callsign.dropLast(2))
        }
        let n28 = packBasecall(base)
        if n28 >= 0 {
            return (UInt32(maxTokens) + UInt32(max22) + UInt32(n28), ip)
        }
        if length >= 3 && length <= 11 {
            return (UInt32(maxTokens) + saveCallsignHash(callsign), 0)
        }
        return nil
    }

    static func pack58(_ callsign: String) -> UInt64? {
        var src = callsign
        if src.hasPrefix("<") { src = String(src.dropFirst()) }
        var result: UInt64 = 0
        var length = 0
        for c in src {
            if c == "<" || length >= 11 { break }
            let j = nchar(c, .alphanumSpaceSlash)
            guard j >= 0 else { return nil }
            result = result * 38 + UInt64(j)
            length += 1
        }
        return result
    }

    static func packGrid(_ grid: String) -> UInt16 {
        if grid.isEmpty { return UInt16(maxGrid4) + 1 }
        if grid == "RRR" { return UInt16(maxGrid4) + 2 }
        if grid == "RR73" { return UInt16(maxGrid4) + 3 }
        if grid == "73" { return UInt16(maxGrid4) + 4 }
        let chars = Array(grid)
        if chars.count >= 4,
           chars[0] >= "A" && chars[0] <= "R",
           chars[1] >= "A" && chars[1] <= "R",
           isDigit(chars[2]), isDigit(chars[3]) {
            var g = UInt16(chars[0].asciiValue! - 65)
            g = g * 18 + UInt16(chars[1].asciiValue! - 65)
            g = g * 10 + UInt16(chars[2].asciiValue! - 48)
            g = g * 10 + UInt16(chars[3].asciiValue! - 48)
            return g
        }
        let isR = chars.first == "R"
        let dd = isR ? ddToInt(String(chars.dropFirst())) : ddToInt(grid)
        let report = max(0, min(300, 35 + dd))
        if isR {
            return (UInt16(maxGrid4) + UInt16(report)) | 0x8000
        }
        return UInt16(maxGrid4) + UInt16(report)
    }

    private static func ddToInt(_ str: String) -> Int {
        let chars = Array(str)
        var negative = false
        var i = 0
        if chars.first == "-" { negative = true; i = 1 }
        else if chars.first == "+" { i = 1 }
        var result = 0
        while i < chars.count {
            guard isDigit(chars[i]) else { break }
            result = result * 10 + Int(chars[i].asciiValue! - 48)
            i += 1
        }
        return negative ? -result : result
    }

    static func encodeStandard(_ callTo: String, _ callDe: String, _ extra: String) -> [UInt8]? {
        guard let (n28a, ipa) = pack28(callTo),
              let (n28b, ipb) = pack28(callDe) else { return nil }

        var i3: UInt8 = 1
        if callTo.hasSuffix("/P") || callDe.hasSuffix("/P") {
            i3 = 2
            if callTo.hasSuffix("/R") || callDe.hasSuffix("/R") { return nil }
        }

        let isCQ = callTo == "CQ" || callTo.hasPrefix("CQ ")
        if isCQ, let slash = callDe.firstIndex(of: "/") {
            let suffix = String(callDe[slash...])
            if callDe.distance(from: callDe.startIndex, to: slash) >= 2 && suffix != "/P" && suffix != "/R" {
                return nil  // nonstandard call: use type 4
            }
        }

        let igrid4 = packGrid(extra)
        var n29a = (n28a << 1) | UInt32(ipa)
        var n29b = (n28b << 1) | UInt32(ipb)
        if callTo.hasSuffix("/R") {
            n29a |= 1
        } else if callTo.hasSuffix("/P") {
            n29a |= 1
            i3 = 2
        }

        var payload = [UInt8](repeating: 0, count: 10)
        payload[0] = UInt8(truncatingIfNeeded: n29a >> 21)
        payload[1] = UInt8(truncatingIfNeeded: n29a >> 13)
        payload[2] = UInt8(truncatingIfNeeded: n29a >> 5)
        payload[3] = UInt8(truncatingIfNeeded: n29a << 3) | UInt8(truncatingIfNeeded: n29b >> 26)
        payload[4] = UInt8(truncatingIfNeeded: n29b >> 18)
        payload[5] = UInt8(truncatingIfNeeded: n29b >> 10)
        payload[6] = UInt8(truncatingIfNeeded: n29b >> 2)
        payload[7] = UInt8(truncatingIfNeeded: n29b << 6) | UInt8(truncatingIfNeeded: igrid4 >> 10)
        payload[8] = UInt8(truncatingIfNeeded: igrid4 >> 2)
        payload[9] = UInt8(truncatingIfNeeded: igrid4 << 6) | UInt8(i3 << 3)
        return payload
    }

    static func encodeNonstandard(_ callTo: String, _ callDe: String, _ extra: String) -> [UInt8]? {
        let i3: UInt8 = 4
        let icq: UInt8 = (callTo == "CQ" || callTo.hasPrefix("CQ ")) ? 1 : 0
        if icq == 0 && callTo.count < 3 { return nil }
        if callDe.count < 3 { return nil }

        var iflip: UInt8
        var n12: UInt16
        let call58: String
        if icq == 0 {
            let deChars = Array(callDe)
            iflip = (deChars.first == "<" && deChars.last == ">") ? 1 : 0
            let call12 = iflip == 0 ? callTo : callDe
            call58 = iflip == 0 ? callDe : callTo
            n12 = UInt16(saveCallsignHash(call12) >> 10)
        } else {
            iflip = 0
            n12 = 0
            call58 = callDe
        }
        guard let n58 = pack58(call58) else { return nil }
        let nrpt: UInt8
        if icq != 0 { nrpt = 0 }
        else if extra == "RRR" { nrpt = 1 }
        else if extra == "RR73" { nrpt = 2 }
        else if extra == "73" { nrpt = 3 }
        else { nrpt = 0 }

        var payload = [UInt8](repeating: 0, count: 10)
        payload[0] = UInt8(truncatingIfNeeded: n12 >> 4)
        payload[1] = UInt8(truncatingIfNeeded: UInt16(n12) << 4) | UInt8(truncatingIfNeeded: n58 >> 54)
        payload[2] = UInt8(truncatingIfNeeded: n58 >> 46)
        payload[3] = UInt8(truncatingIfNeeded: n58 >> 38)
        payload[4] = UInt8(truncatingIfNeeded: n58 >> 30)
        payload[5] = UInt8(truncatingIfNeeded: n58 >> 22)
        payload[6] = UInt8(truncatingIfNeeded: n58 >> 14)
        payload[7] = UInt8(truncatingIfNeeded: n58 >> 6)
        payload[8] = UInt8(truncatingIfNeeded: n58 << 2) | UInt8(iflip << 1) | UInt8(nrpt >> 1)
        payload[9] = UInt8(nrpt << 7) | UInt8(icq << 6) | UInt8(i3 << 3)
        return payload
    }

    static func encodeFree(_ text: String) -> [UInt8]? {
        let chars = Array(text)
        guard chars.count <= 13 else { return nil }
        var b71 = [UInt8](repeating: 0, count: 9)
        for idx in 0..<13 {
            let c: Character = idx < chars.count ? chars[idx] : " "
            let cid = nchar(c, .full)
            guard cid >= 0 else { return nil }
            var rem: UInt16 = UInt16(cid)
            for i in (0..<9).reversed() {
                rem += UInt16(b71[i]) * 42
                b71[i] = UInt8(rem & 0xFF)
                rem >>= 8
            }
        }
        var payload = [UInt8](repeating: 0, count: 10)
        var carry: UInt8 = 0
        for i in (0..<9).reversed() {
            payload[i] = (b71[i] << 1) | (carry >> 7)
            carry = b71[i] & 0x80
        }
        payload[9] = 0
        return payload
    }
}

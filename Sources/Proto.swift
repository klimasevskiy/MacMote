import Foundation

// Minimal protobuf encoder/decoder — enough for the Android TV Remote v2 protocol.

struct PB {
    var data = Data()

    private mutating func raw(_ v: UInt64) {
        var v = v
        while v >= 0x80 { data.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        data.append(UInt8(v))
    }

    mutating func int(_ field: Int, _ v: Int) {
        raw(UInt64(field << 3))
        raw(UInt64(bitPattern: Int64(v)))
    }

    mutating func bytes(_ field: Int, _ b: Data) {
        raw(UInt64(field << 3 | 2))
        raw(UInt64(b.count))
        data.append(b)
    }

    mutating func string(_ field: Int, _ s: String) { bytes(field, Data(s.utf8)) }

    mutating func msg(_ field: Int, _ build: (inout PB) -> Void) {
        var p = PB()
        build(&p)
        bytes(field, p.data)
    }

    static func build(_ build: (inout PB) -> Void) -> Data {
        var p = PB()
        build(&p)
        return p.data
    }

    static func varint(_ v: Int) -> Data {
        var p = PB()
        p.raw(UInt64(v))
        return p.data
    }
}

struct PBMsg {
    enum Value { case varint(UInt64), bytes(Data) }
    private(set) var fields: [Int: [Value]] = [:]

    init?(_ data: Data) {
        let b = [UInt8](data)
        var i = 0
        func readVarint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < b.count {
                let byte = b[i]; i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < b.count {
            guard let key = readVarint() else { return nil }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = readVarint() else { return nil }
                fields[field, default: []].append(.varint(v))
            case 2:
                guard let len = readVarint(), i + Int(len) <= b.count else { return nil }
                fields[field, default: []].append(.bytes(Data(b[i..<i + Int(len)])))
                i += Int(len)
            case 5: i += 4
            case 1: i += 8
            default: return nil
            }
        }
    }

    func has(_ f: Int) -> Bool { fields[f] != nil }

    func int(_ f: Int) -> Int? {
        if case .varint(let v)? = fields[f]?.first { return Int(truncatingIfNeeded: v) }
        return nil
    }

    func data(_ f: Int) -> Data? {
        if case .bytes(let d)? = fields[f]?.first { return d }
        return nil
    }

    func string(_ f: Int) -> String? { data(f).flatMap { String(data: $0, encoding: .utf8) } }

    func sub(_ f: Int) -> PBMsg? { data(f).flatMap(PBMsg.init) }
}

/// Splits a byte stream into varint-length-prefixed messages.
struct Framer {
    private var buf = [UInt8]()

    mutating func push(_ d: Data) -> [Data] {
        buf.append(contentsOf: d)
        var out = [Data]()
        while true {
            var len = 0, shift = 0, i = 0, complete = false
            while i < buf.count {
                let byte = buf[i]; i += 1
                len |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { complete = true; break }
                shift += 7
            }
            guard complete, buf.count >= i + len else { break }
            out.append(Data(buf[i..<i + len]))
            buf.removeFirst(i + len)
        }
        return out
    }
}

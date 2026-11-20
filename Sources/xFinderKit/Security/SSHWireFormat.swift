import Foundation

/// Minimal SSH wire-format reader/writer (RFC 4251 strings, uint32, mpint).
public struct SSHReader {
    public private(set) var data: [UInt8]
    public private(set) var offset = 0

    public init<D: DataProtocol>(_ data: D) { self.data = Array(data) }

    public var remaining: Int { data.count - offset }
    public var isAtEnd: Bool { offset >= data.count }

    public mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw SSHKeyError.malformed("truncated integer") }
        let v = data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return v
    }

    public mutating func readBytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, remaining >= n else { throw SSHKeyError.malformed("truncated data") }
        let out = Array(data[offset..<offset + n])
        offset += n
        return out
    }

    public mutating func readString() throws -> [UInt8] {
        let n = Int(try readUInt32())
        return try readBytes(n)
    }

    public mutating func readUTF8() throws -> String {
        guard let s = String(bytes: try readString(), encoding: .utf8) else { throw SSHKeyError.malformed("invalid string") }
        return s
    }

    /// Reads an mpint, returning the unsigned magnitude without leading zeros.
    public mutating func readMPInt() throws -> [UInt8] {
        var b = try readString()
        while b.first == 0 { b.removeFirst() }
        return b
    }
}

public struct SSHWriter {
    public private(set) var bytes: [UInt8] = []
    public init() {}

    public mutating func writeUInt32(_ v: UInt32) {
        bytes += [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    }

    public mutating func writeString<D: Collection>(_ d: D) where D.Element == UInt8 {
        writeUInt32(UInt32(d.count))
        bytes += d
    }

    public mutating func writeString(_ s: String) { writeString(Array(s.utf8)) }

    /// Writes an unsigned big-endian magnitude as an mpint.
    public mutating func writeMPInt(_ magnitude: [UInt8]) {
        var m = magnitude
        while m.first == 0 { m.removeFirst() }
        if let f = m.first, f & 0x80 != 0 { m.insert(0, at: 0) }
        writeString(m)
    }

    public var data: Data { Data(bytes) }
}

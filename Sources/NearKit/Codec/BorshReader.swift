import BigInt
import Foundation

/// Borsh decoder, used to read transactions a dApp hands the wallet for signing.
struct BorshReader {
    private let buffer: [UInt8]
    private var position = 0

    init(_ data: Data) {
        buffer = [UInt8](data)
    }

    var remaining: Int {
        buffer.count - position
    }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else {
            throw CodecError.unexpectedEnd
        }
        defer { position += 1 }
        return buffer[position]
    }

    func peekU8() throws -> UInt8 {
        guard remaining >= 1 else {
            throw CodecError.unexpectedEnd
        }
        return buffer[position]
    }

    mutating func u32() throws -> UInt32 {
        try littleEndian(4)
    }

    mutating func u64() throws -> UInt64 {
        try littleEndian(8)
    }

    mutating func u128() throws -> BigUInt {
        try BigUInt(Data(fixedBytes(16).reversed()))
    }

    mutating func fixedBytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else {
            throw CodecError.unexpectedEnd
        }
        defer { position += count }
        return Data(buffer[position ..< position + count])
    }

    mutating func bytes() throws -> Data {
        let count = try Int(u32())
        guard count <= remaining else {
            throw CodecError.lengthExceedsData
        }
        return try fixedBytes(count)
    }

    /// Strict UTF-8: invalid sequences are an error, not replacement characters.
    mutating func string() throws -> String {
        let data = try bytes()
        let string = String(decoding: data, as: UTF8.self)
        guard Data(string.utf8) == data else {
            throw CodecError.invalidUtf8
        }
        return string
    }

    mutating func vec<T>(_ read: (inout BorshReader) throws -> T) throws -> [T] {
        let count = try Int(u32())
        // every element takes at least one byte, which bounds a hostile length prefix
        guard count <= remaining else {
            throw CodecError.lengthExceedsData
        }
        var items = [T]()
        items.reserveCapacity(count)
        for _ in 0 ..< count {
            try items.append(read(&self))
        }
        return items
    }

    mutating func option<T>(_ read: (inout BorshReader) throws -> T) throws -> T? {
        switch try u8() {
        case 0: return nil
        case 1: return try read(&self)
        case let tag: throw CodecError.invalidOptionTag(tag)
        }
    }

    func finish() throws {
        guard remaining == 0 else {
            throw CodecError.trailingBytes
        }
    }

    private mutating func littleEndian<T: FixedWidthInteger & UnsignedInteger>(_ size: Int) throws -> T {
        let data = try fixedBytes(size)
        return data.reversed().reduce(T.zero) { $0 << 8 | T($1) }
    }
}

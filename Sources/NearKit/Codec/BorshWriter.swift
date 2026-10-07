import BigInt
import Foundation

/// Borsh encoder for the subset of types NEAR transactions use. Integers are little-endian.
struct BorshWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) {
        data.append(value)
    }

    mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func u64(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func u128(_ value: BigUInt) throws {
        let bigEndian = value.serialize()
        guard bigEndian.count <= 16 else {
            throw CodecError.outOfRange
        }
        data.append(contentsOf: bigEndian.reversed())
        data.append(Data(count: 16 - bigEndian.count))
    }

    mutating func fixedBytes(_ value: Data) {
        data.append(value)
    }

    /// Length-prefixed byte vector (`Vec<u8>`).
    mutating func bytes(_ value: Data) throws {
        try length(value.count)
        data.append(value)
    }

    mutating func string(_ value: String) throws {
        try bytes(Data(value.utf8))
    }

    mutating func vec<T>(_ items: [T], _ write: (inout BorshWriter, T) throws -> Void) throws {
        try length(items.count)
        for item in items {
            try write(&self, item)
        }
    }

    mutating func option<T>(_ value: T?, _ write: (inout BorshWriter, T) throws -> Void) rethrows {
        if let value {
            u8(1)
            try write(&self, value)
        } else {
            u8(0)
        }
    }

    private mutating func length(_ count: Int) throws {
        guard let value = UInt32(exactly: count) else {
            throw CodecError.outOfRange
        }
        u32(value)
    }
}

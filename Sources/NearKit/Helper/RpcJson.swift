import BigInt
import Foundation

/// Strict readers for nearcore JSON. Integers the protocol types as u64 arrive as JSON numbers and
/// are read with `UInt64(exactly:)`; yocto amounts (u128) arrive as decimal strings. Anything else
/// is `InvalidResponse`, never a truncation or a trap.
typealias RpcJson = [String: Any]

extension [String: Any] {
    func string(_ key: String) -> String? {
        self[key] as? String
    }

    func requireString(_ key: String) throws -> String {
        guard let value = string(key) else {
            throw InvalidResponse("missing field '\(key)'")
        }
        return value
    }

    func object(_ key: String) -> RpcJson? {
        self[key] as? RpcJson
    }

    func requireObject(_ key: String) throws -> RpcJson {
        guard let value = object(key) else {
            throw InvalidResponse("missing object '\(key)'")
        }
        return value
    }

    func array(_ key: String) -> [Any]? {
        self[key] as? [Any]
    }

    /// A JSON number field. JSON booleans are NSNumber too (and `0`/`1` even cast to `Bool`),
    /// so they are told apart by their CoreFoundation type.
    func uint64(_ key: String) throws -> UInt64? {
        guard let raw = self[key], !(raw is NSNull) else {
            return nil
        }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let value = UInt64(exactly: number) else {
            throw InvalidResponse("field '\(key)' is not an unsigned integer")
        }
        return value
    }

    func requireUInt64(_ key: String) throws -> UInt64 {
        guard let value = try uint64(key) else {
            throw InvalidResponse("missing field '\(key)'")
        }
        return value
    }

    /// A u128 amount, which nearcore sends as a decimal string.
    func bigUInt(_ key: String) throws -> BigUInt? {
        guard let raw = self[key], !(raw is NSNull) else {
            return nil
        }
        guard let string = raw as? String, !string.isEmpty, string.allSatisfy(\.isASCIIDigit), let value = BigUInt(string) else {
            throw InvalidResponse("field '\(key)' is not an amount string")
        }
        return value
    }

    func requireBigUInt(_ key: String) throws -> BigUInt {
        guard let value = try bigUInt(key) else {
            throw InvalidResponse("missing field '\(key)'")
        }
        return value
    }
}

/// Lenient readers for indexer and node output that is displayed rather than spent: like the Android
/// kit's Gson helpers they take a JSON number or a numeric string, and give nil instead of failing.
extension [String: Any] {
    /// A string, or the text of a number.
    func lenientString(_ key: String) -> String? {
        RpcJson.lenientString(self[key])
    }

    func lenientUInt64(_ key: String) -> UInt64? {
        let raw = self[key]
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return UInt64(exactly: number)
        }
        return (raw as? String).flatMap { UInt64($0) }
    }

    func lenientInt(_ key: String) -> Int? {
        lenientUInt64(key).flatMap { Int(exactly: $0) }
    }

    func lenientBigUInt(_ key: String) -> BigUInt? {
        RpcJson.lenientBigUInt(self[key])
    }

    /// A height, which nearcore sends as a u64 number; heights are `Int` in the kit's API.
    func requireHeight(_ key: String) throws -> Int {
        guard let value = Int(exactly: try requireUInt64(key)) else {
            throw InvalidResponse("field '\(key)' is out of range")
        }
        return value
    }
}

extension RpcJson {
    static func lenientString(_ raw: Any?) -> String? {
        if let string = raw as? String {
            return string
        }
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
        return nil
    }

    static func lenientBigUInt(_ raw: Any?) -> BigUInt? {
        guard let string = lenientString(raw), !string.isEmpty, string.allSatisfy(\.isASCIIDigit) else {
            return nil
        }
        return BigUInt(string)
    }

    /// The JSON text of a value (an error payload, a failure), for display and substring checks.
    static func text(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses JSON text into an object; nil for anything else.
    static func object(text: String) -> RpcJson? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? RpcJson
    }
}

extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}

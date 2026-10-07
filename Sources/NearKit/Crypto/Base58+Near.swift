import Foundation
import HsCryptoKit

/// `HsCryptoKit.Base58.decode` returns empty data for a character outside the alphabet instead of
/// failing, so a non-empty input that decodes to nothing is rejected here.
extension Base58 {
    static func strictDecode(_ string: String) throws -> Data {
        let data = decode(string)
        guard !data.isEmpty || string.isEmpty else {
            throw CodecError.invalidBase58
        }
        return data
    }

    static func strictDecode(_ string: String, count: Int) throws -> Data {
        let data = try strictDecode(string)
        guard data.count == count else {
            throw CodecError.invalidLength(expected: count, actual: data.count)
        }
        return data
    }
}

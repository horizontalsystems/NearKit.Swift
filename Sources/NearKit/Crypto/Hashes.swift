import Foundation
import HsCryptoKit

enum Hashes {
    static func sha256(_ data: Data) -> Data {
        Crypto.sha256(data)
    }
}

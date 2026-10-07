import Foundation
import XCTest

enum Fixtures {
    static func json(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    static func objects(_ json: [String: Any], _ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(json[key] as? [[String: Any]])
    }
}

extension [String: Any] {
    func text(_ key: String) throws -> String {
        try XCTUnwrap(self[key] as? String, "missing '\(key)'")
    }
}

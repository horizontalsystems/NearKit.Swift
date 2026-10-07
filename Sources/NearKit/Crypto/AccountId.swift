import Foundation

/// NEAR account id rules (https://nomicon.io/DataStructures/Account): 2-64 characters, lowercase
/// alphanumeric parts separated by `.`, `-` or `_`, with no leading, trailing or doubled separators.
///
/// The patterns spell `[a-z0-9]` instead of `\d`, which in ICU matches every Unicode digit, and are
/// anchored with `\A`/`\z` because `$` also matches before a trailing newline.
public enum AccountId {
    public enum Kind {
        case named
        case nearImplicit
        case ethImplicit
        case deterministic
    }

    public static let lengthRange = 2 ... 64

    private static let valid = regex(#"\A(([a-z0-9]+[-_])*[a-z0-9]+\.)*([a-z0-9]+[-_])*[a-z0-9]+\z"#)
    private static let nearImplicit = regex(#"\A[0-9a-f]{64}\z"#)
    private static let ethImplicit = regex(#"\A0x[0-9a-f]{40}\z"#)
    private static let deterministic = regex(#"\A0s[0-9a-f]{40}\z"#)

    public static func isValid(_ accountId: String) -> Bool {
        lengthRange.contains(accountId.utf8.count) && matches(valid, accountId)
    }

    /// Nil for an invalid id.
    public static func kind(_ accountId: String) -> Kind? {
        guard isValid(accountId) else {
            return nil
        }
        if matches(nearImplicit, accountId) {
            return .nearImplicit
        }
        if matches(ethImplicit, accountId) {
            return .ethImplicit
        }
        if matches(deterministic, accountId) {
            return .deterministic
        }
        return .named
    }

    /// Implicit accounts come into existence when they first receive NEAR. A named account must be
    /// created before anything can be sent to it, so a transfer to a missing named account fails.
    public static func isImplicit(_ accountId: String) -> Bool {
        switch kind(accountId) {
        case .nearImplicit, .ethImplicit: return true
        default: return false
        }
    }

    public static func validate(_ accountId: String) throws {
        guard isValid(accountId) else {
            throw AccountIdError.invalid(accountId)
        }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }
}

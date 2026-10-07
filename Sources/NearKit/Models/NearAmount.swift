import BigInt
import Foundation

/// NEAR has 24 decimals; amounts travel as yoctoNEAR (u128) and never fit a `UInt64`.
public enum NearAmount {
    public static let decimals = 24

    public static func toNear(yocto: BigUInt) -> Decimal {
        guard let significand = Decimal(string: yocto.description, locale: posixLocale) else {
            return 0
        }
        return Decimal(sign: .plus, exponent: -decimals, significand: significand)
    }

    /// Nil when `near` is negative or has more than 24 decimal places.
    public static func toYocto(near: Decimal) -> BigUInt? {
        guard !near.isSignMinus || near.isZero else {
            return nil
        }
        var scaled = Decimal(sign: .plus, exponent: decimals, significand: near)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else {
            return nil
        }
        return BigUInt(NSDecimalNumber(decimal: rounded).stringValue)
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")
}

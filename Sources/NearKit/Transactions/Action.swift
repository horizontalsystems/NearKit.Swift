import BigInt
import Foundation

/// Transaction actions, in Borsh enum order. `tag` is the variant index nearcore uses; the order
/// is part of the wire format and must not change.
public enum Action: Equatable {
    case createAccount
    case deployContract(code: Data)
    case functionCall(methodName: String, args: Data, gas: UInt64, deposit: BigUInt)
    case transfer(deposit: BigUInt)
    case stake(stake: BigUInt, publicKey: PublicKey)
    case addKey(publicKey: PublicKey, accessKey: AccessKey)
    case deleteKey(publicKey: PublicKey)
    case deleteAccount(beneficiaryId: String)

    // Delegate (8), DeployGlobalContract (9), UseGlobalContract (10) and later variants are not
    // built by the kit; decoding a transaction that contains one fails with unsupportedAction.

    public var tag: UInt8 {
        switch self {
        case .createAccount: return 0
        case .deployContract: return 1
        case .functionCall: return 2
        case .transfer: return 3
        case .stake: return 4
        case .addKey: return 5
        case .deleteKey: return 6
        case .deleteAccount: return 7
        }
    }
}

public struct AccessKey: Equatable {
    public let nonce: UInt64
    public let permission: AccessKeyPermission

    public init(nonce: UInt64, permission: AccessKeyPermission) {
        self.nonce = nonce
        self.permission = permission
    }
}

public enum AccessKeyPermission: Equatable {
    /// `allowance`: yoctoNEAR the key may spend on gas; nil for unlimited.
    case functionCall(allowance: BigUInt?, receiverId: String, methodNames: [String])
    case fullAccess
}

extension Action {
    func write(to writer: inout BorshWriter) throws {
        writer.u8(tag)
        switch self {
        case .createAccount:
            break
        case let .deployContract(code):
            try writer.bytes(code)
        case let .functionCall(methodName, args, gas, deposit):
            try writer.string(methodName)
            try writer.bytes(args)
            writer.u64(gas)
            try writer.u128(deposit)
        case let .transfer(deposit):
            try writer.u128(deposit)
        case let .stake(stake, publicKey):
            try writer.u128(stake)
            writer.publicKey(publicKey)
        case let .addKey(publicKey, accessKey):
            writer.publicKey(publicKey)
            writer.u64(accessKey.nonce)
            switch accessKey.permission {
            case let .functionCall(allowance, receiverId, methodNames):
                writer.u8(0)
                try writer.option(allowance) { try $0.u128($1) }
                try writer.string(receiverId)
                try writer.vec(methodNames) { try $0.string($1) }
            case .fullAccess:
                writer.u8(1)
            }
        case let .deleteKey(publicKey):
            writer.publicKey(publicKey)
        case let .deleteAccount(beneficiaryId):
            try writer.string(beneficiaryId)
        }
    }

    static func read(from reader: inout BorshReader) throws -> Action {
        switch try reader.u8() {
        case 0:
            return .createAccount
        case 1:
            return try .deployContract(code: reader.bytes())
        case 2:
            return try .functionCall(methodName: reader.string(), args: reader.bytes(), gas: reader.u64(), deposit: reader.u128())
        case 3:
            return try .transfer(deposit: reader.u128())
        case 4:
            return try .stake(stake: reader.u128(), publicKey: reader.publicKey())
        case 5:
            let publicKey = try reader.publicKey()
            let nonce = try reader.u64()
            let permission: AccessKeyPermission
            switch try reader.u8() {
            case 0:
                permission = try .functionCall(
                    allowance: reader.option { try $0.u128() },
                    receiverId: reader.string(),
                    methodNames: reader.vec { try $0.string() }
                )
            case 1:
                permission = .fullAccess
            case let value:
                throw CodecError.invalidAccessKeyPermission(value)
            }
            return .addKey(publicKey: publicKey, accessKey: AccessKey(nonce: nonce, permission: permission))
        case 6:
            return try .deleteKey(publicKey: reader.publicKey())
        case 7:
            return try .deleteAccount(beneficiaryId: reader.string())
        case let tag:
            throw CodecError.unsupportedAction(tag)
        }
    }
}

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

// pattern: Functional Core

/// SHA-256 digest with exactly 32 bytes and a canonical lowercase-hex codec.
public struct RendererSHA256Digest: Codable, Hashable, Sendable {
    public static let byteCount = 32
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else { throw RendererDigestError.invalidByteCount(bytes.count) }
        self.bytes = bytes
    }

    public init(hex: String) throws {
        guard hex.count == Self.byteCount * 2 else { throw RendererDigestError.invalidHex(hex) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.byteCount)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            let pair = hex[index..<next]
            guard pair.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }),
                  let byte = UInt8(pair, radix: 16) else {
                throw RendererDigestError.invalidHex(hex)
            }
            bytes.append(byte)
            index = next
        }
        try self.init(bytes: bytes)
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    public init(from decoder: any Decoder) throws {
        try self.init(hex: try String(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

public enum RendererDigestError: Error, Equatable, Sendable {
    case invalidByteCount(Int)
    case invalidHex(String)
}

/// Cross-platform SHA-256 entry point. macOS uses CryptoKit and Linux uses
/// the compatible Crypto module supplied by swift-crypto.
public enum RendererSHA256 {
    public static func digest(_ data: Data) -> RendererSHA256Digest {
        let bytes: [UInt8]
        #if canImport(CryptoKit)
        bytes = Array(SHA256.hash(data: data))
        #elseif canImport(Crypto)
        bytes = Array(SHA256.hash(data: data))
        #else
        #error("RendererSHA256 requires CryptoKit or Crypto")
        #endif
        // SHA-256 has a fixed output width. This is a programming invariant,
        // not caller input, so fail loudly if the platform implementation breaks it.
        do {
            return try RendererSHA256Digest(bytes: bytes)
        } catch {
            preconditionFailure("SHA-256 platform primitive produced an invalid digest: \(error)")
        }
    }
}

import Foundation
import Crypto
import _CryptoExtras
import NIOCore
import NIOSSH

/// RSA signature algorithm variants for SSH user authentication.
public protocol RSASHAVariant {
    static var algorithmName: String { get }
    static func sign(_ key: _RSA.Signing.PrivateKey, _ data: Data) throws -> Data
    static func verify(_ key: _RSA.Signing.PublicKey, _ signature: Data, _ data: Data) -> Bool
}

public enum RSASHA512: RSASHAVariant {
    public static let algorithmName = "rsa-sha2-512"
    public static func sign(_ key: _RSA.Signing.PrivateKey, _ data: Data) throws -> Data {
        try key.signature(for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation
    }
    public static func verify(_ key: _RSA.Signing.PublicKey, _ signature: Data, _ data: Data) -> Bool {
        key.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: signature), for: SHA512.hash(data: data),
                             padding: .insecurePKCS1v1_5)
    }
}

public enum RSASHA256: RSASHAVariant {
    public static let algorithmName = "rsa-sha2-256"
    public static func sign(_ key: _RSA.Signing.PrivateKey, _ data: Data) throws -> Data {
        try key.signature(for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation
    }
    public static func verify(_ key: _RSA.Signing.PublicKey, _ signature: Data, _ data: Data) -> Bool {
        key.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: signature), for: SHA256.hash(data: data),
                             padding: .insecurePKCS1v1_5)
    }
}

/// Legacy `ssh-rsa` (SHA-1) for servers older than OpenSSH 7.2.
public enum RSASHA1: RSASHAVariant {
    public static let algorithmName = "ssh-rsa"
    public static func sign(_ key: _RSA.Signing.PrivateKey, _ data: Data) throws -> Data {
        try key.signature(for: Insecure.SHA1.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation
    }
    public static func verify(_ key: _RSA.Signing.PublicKey, _ signature: Data, _ data: Data) -> Bool {
        key.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: signature), for: Insecure.SHA1.hash(data: data),
                             padding: .insecurePKCS1v1_5)
    }
}

/// RSA signature blob (`string algorithm, string signature`).
public struct RSASSHSignature<V: RSASHAVariant>: NIOSSHSignatureProtocol {
    public static var signaturePrefix: String { V.algorithmName }
    public let rawRepresentation: Data

    public init(rawRepresentation: Data) { self.rawRepresentation = rawRepresentation }

    public func write(to buffer: inout ByteBuffer) -> Int {
        var n = buffer.writeInteger(UInt32(rawRepresentation.count))
        n += buffer.writeBytes(rawRepresentation)
        return n
    }

    public static func read(from buffer: inout ByteBuffer) throws -> RSASSHSignature<V> {
        guard let len = buffer.readInteger(as: UInt32.self), let bytes = buffer.readBytes(length: Int(len)) else {
            throw SSHKeyError.malformed("RSA signature")
        }
        return RSASSHSignature(rawRepresentation: Data(bytes))
    }
}

/// RSA public key whose algorithm name is `V.algorithmName` while its key blob
/// keeps the `ssh-rsa` type (RFC 8332). Relies on the vendored NIOSSH patch.
public final class RSASSHPublicKey<V: RSASHAVariant>: NIOSSHPublicKeyProtocol, NIOSSHPublicKeyBlobPrefixProviding {
    public static var publicKeyPrefix: String { V.algorithmName }
    public var keyBlobPrefix: String { "ssh-rsa" }

    let n: [UInt8]
    let e: [UInt8]

    public init(n: [UInt8], e: [UInt8]) {
        self.n = n
        self.e = e
    }

    public var rawRepresentation: Data {
        var w = SSHWriter()
        w.writeMPInt(e)
        w.writeMPInt(n)
        return w.data
    }

    public func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let sig = signature as? RSASSHSignature<V>,
              let key = try? _RSA.Signing.PublicKey(n: n, e: e) else { return false }
        return V.verify(key, sig.rawRepresentation, Data(data))
    }

    public func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeBytes(rawRepresentation)
    }

    public static func read(from buffer: inout ByteBuffer) throws -> RSASSHPublicKey<V> {
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { throw SSHKeyError.malformed("RSA key") }
        var r = SSHReader(bytes)
        let e = try r.readMPInt()
        let n = try r.readMPInt()
        return RSASSHPublicKey(n: n, e: e)
    }
}

public final class RSASSHPrivateKey<V: RSASHAVariant>: NIOSSHPrivateKeyProtocol {
    public static var keyPrefix: String { V.algorithmName }

    let key: _RSA.Signing.PrivateKey
    let _publicKey: RSASSHPublicKey<V>

    public init(key: _RSA.Signing.PrivateKey, n: [UInt8], e: [UInt8]) {
        self.key = key
        self._publicKey = RSASSHPublicKey(n: n, e: e)
    }

    public var publicKey: NIOSSHPublicKeyProtocol { _publicKey }

    public func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        RSASSHSignature<V>(rawRepresentation: try V.sign(key, Data(data)))
    }
}

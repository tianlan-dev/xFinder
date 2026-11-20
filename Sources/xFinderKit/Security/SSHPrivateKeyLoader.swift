import Foundation
import Crypto
import _CryptoExtras
import CommonCrypto
import CBcryptPBKDF
import NIOSSH

public enum SSHKeyError: Error, LocalizedError, Equatable {
    case fileUnreadable(String)
    case unsupportedFormat(String)
    case unsupportedKeyType(String)
    case unsupportedCipher(String)
    case passphraseRequired
    case wrongPassphrase
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .fileUnreadable(let p): return "Cannot read the key file \(p)."
        case .unsupportedFormat(let m): return "Unsupported private key format: \(m)"
        case .unsupportedKeyType(let t): return "Unsupported key type \(t)."
        case .unsupportedCipher(let c): return "Unsupported key encryption \(c)."
        case .passphraseRequired: return "The key is protected by a passphrase."
        case .wrongPassphrase: return "The passphrase is incorrect."
        case .malformed(let m): return "The key file is damaged (\(m))."
        }
    }
}

/// Key algorithm of a parsed private key.
public enum SSHKeyType: String, Sendable, Hashable {
    case ed25519 = "ssh-ed25519"
    case rsa = "ssh-rsa"
    case ecdsaP256 = "ecdsa-sha2-nistp256"
    case ecdsaP384 = "ecdsa-sha2-nistp384"
    case ecdsaP521 = "ecdsa-sha2-nistp521"

    public var displayName: String {
        switch self {
        case .ed25519: return "ED25519"
        case .rsa: return "RSA"
        case .ecdsaP256: return "ECDSA P-256"
        case .ecdsaP384: return "ECDSA P-384"
        case .ecdsaP521: return "ECDSA P-521"
        }
    }
}

/// Metadata readable without the passphrase.
public struct SSHKeyInfo: Sendable, Hashable {
    public var type: SSHKeyType?
    public var typeName: String
    /// `SHA256:…` fingerprint of the public key.
    public var fingerprint: String?
    public var isEncrypted: Bool
    public var comment: String?
    public var bits: Int?
}

/// A decrypted private key ready for authentication.
public struct LoadedPrivateKey: @unchecked Sendable {
    public enum Material {
        case ed25519(Curve25519.Signing.PrivateKey)
        case p256(P256.Signing.PrivateKey)
        case p384(P384.Signing.PrivateKey)
        case p521(P521.Signing.PrivateKey)
        case rsa(_RSA.Signing.PrivateKey, n: [UInt8], e: [UInt8])
    }

    public let type: SSHKeyType
    public let material: Material
    public let publicKeyBlob: [UInt8]
    public let comment: String

    public var fingerprint: String { SSHFingerprint.sha256(publicKeyBlob) }

    /// NIOSSH private keys to offer, in preference order. RSA keys are offered as
    /// rsa-sha2-512, rsa-sha2-256 and finally legacy ssh-rsa.
    public var nioKeys: [NIOSSHPrivateKey] {
        switch material {
        case .ed25519(let k): return [NIOSSHPrivateKey(ed25519Key: k)]
        case .p256(let k): return [NIOSSHPrivateKey(p256Key: k)]
        case .p384(let k): return [NIOSSHPrivateKey(p384Key: k)]
        case .p521(let k): return [NIOSSHPrivateKey(p521Key: k)]
        case .rsa(let k, let n, let e):
            return [
                NIOSSHPrivateKey(custom: RSASSHPrivateKey<RSASHA512>(key: k, n: n, e: e)),
                NIOSSHPrivateKey(custom: RSASSHPrivateKey<RSASHA256>(key: k, n: n, e: e)),
                NIOSSHPrivateKey(custom: RSASSHPrivateKey<RSASHA1>(key: k, n: n, e: e)),
            ]
        }
    }
}

public enum SSHFingerprint {
    /// OpenSSH-style `SHA256:<base64 without padding>`.
    public static func sha256<D: DataProtocol>(_ blob: D) -> String {
        let digest = Data(SHA256.hash(data: Data(blob)))
        let b64 = digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + b64
    }

    /// Fingerprint of a NIOSSH public key (host keys).
    public static func sha256(_ key: NIOSSHPublicKey) -> String {
        let text = String(openSSHPublicKey: key)
        let parts = text.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "SHA256:?" }
        return sha256(blob)
    }

    public static func keyType(_ key: NIOSSHPublicKey) -> String {
        String(String(openSSHPublicKey: key).split(separator: " ").first ?? "")
    }
}

/// Parses OpenSSH (`openssh-key-v1`) and unencrypted PEM private keys.
public enum SSHPrivateKeyLoader {
    static let opensshMagic = Array("openssh-key-v1\0".utf8)

    public static func load(path: String, passphrase: String?) throws -> LoadedPrivateKey {
        let p = (path as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { throw SSHKeyError.fileUnreadable(path) }
        return try parse(text, passphrase: passphrase)
    }

    public static func info(path: String) throws -> SSHKeyInfo {
        let p = (path as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { throw SSHKeyError.fileUnreadable(path) }
        return try info(text)
    }

    public static func info(_ text: String) throws -> SSHKeyInfo {
        if text.contains("BEGIN OPENSSH PRIVATE KEY") {
            let c = try OpenSSHContainer(pem: text)
            var r = SSHReader(c.publicBlob)
            let typeName = (try? r.readUTF8()) ?? "unknown"
            let type = SSHKeyType(rawValue: typeName)
            var bits: Int?
            if type == .rsa { _ = try? r.readMPInt(); bits = (try? r.readMPInt()).map { magnitudeBits($0) } }
            var comment: String?
            if !c.isEncrypted, let k = try? parse(text, passphrase: nil) { comment = k.comment.isEmpty ? nil : k.comment }
            return SSHKeyInfo(type: type, typeName: typeName, fingerprint: SSHFingerprint.sha256(c.publicBlob),
                              isEncrypted: c.isEncrypted, comment: comment, bits: bits ?? defaultBits(type))
        }
        if text.contains("ENCRYPTED") && text.contains("BEGIN") {
            let type: SSHKeyType? = text.contains("RSA") ? .rsa : nil
            return SSHKeyInfo(type: type, typeName: type?.rawValue ?? "PEM", fingerprint: nil, isEncrypted: true,
                              comment: nil, bits: nil)
        }
        let k = try parse(text, passphrase: nil)
        var bits: Int?
        if case .rsa(_, let n, _) = k.material { bits = magnitudeBits(n) }
        return SSHKeyInfo(type: k.type, typeName: k.type.rawValue, fingerprint: k.fingerprint, isEncrypted: false,
                          comment: nil, bits: bits ?? defaultBits(k.type))
    }

    static func magnitudeBits(_ m: [UInt8]) -> Int {
        guard let first = m.first else { return 0 }
        return (m.count - 1) * 8 + (8 - first.leadingZeroBitCount)
    }

    static func defaultBits(_ t: SSHKeyType?) -> Int? {
        switch t {
        case .ed25519: return 256
        case .ecdsaP256: return 256
        case .ecdsaP384: return 384
        case .ecdsaP521: return 521
        default: return nil
        }
    }

    public static func parse(_ text: String, passphrase: String?) throws -> LoadedPrivateKey {
        if text.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSH(text, passphrase: passphrase)
        }
        if text.contains("Proc-Type: 4,ENCRYPTED") || text.contains("BEGIN ENCRYPTED PRIVATE KEY") {
            throw SSHKeyError.unsupportedFormat("encrypted PEM keys are not supported; convert with `ssh-keygen -p -f <key>`")
        }
        if text.contains("BEGIN RSA PRIVATE KEY") || text.contains("BEGIN PRIVATE KEY") {
            if let k = try? _RSA.Signing.PrivateKey(unsafePEMRepresentation: text) {
                return try rsaFromCryptoKey(k)
            }
            if let k = try? P256.Signing.PrivateKey(pemRepresentation: text) { return ecdsa(.p256(k)) }
            if let k = try? P384.Signing.PrivateKey(pemRepresentation: text) { return ecdsa(.p384(k)) }
            if let k = try? P521.Signing.PrivateKey(pemRepresentation: text) { return ecdsa(.p521(k)) }
            throw SSHKeyError.unsupportedFormat("unrecognized PEM key")
        }
        if text.contains("BEGIN EC PRIVATE KEY") {
            if let k = try? P256.Signing.PrivateKey(pemRepresentation: text) { return ecdsa(.p256(k)) }
            if let k = try? P384.Signing.PrivateKey(pemRepresentation: text) { return ecdsa(.p384(k)) }
            if let k = try? P521.Signing.PrivateKey(pemRepresentation: text) { return ecdsa(.p521(k)) }
            throw SSHKeyError.unsupportedFormat("unrecognized EC key")
        }
        if text.contains("PuTTY-User-Key-File") {
            throw SSHKeyError.unsupportedFormat("PuTTY keys are not supported; export as OpenSSH from PuTTYgen")
        }
        throw SSHKeyError.unsupportedFormat("not a private key file")
    }

    // MARK: OpenSSH container

    struct OpenSSHContainer {
        var cipher: String
        var kdf: String
        var kdfOptions: [UInt8]
        var publicBlob: [UInt8]
        var privateSection: [UInt8]
        /// Bytes after the private section (AES-GCM tag).
        var trailer: [UInt8]

        var isEncrypted: Bool { cipher != "none" }

        init(pem: String) throws {
            let lines = pem.components(separatedBy: .newlines)
            guard let start = lines.firstIndex(where: { $0.contains("BEGIN OPENSSH PRIVATE KEY") }),
                  let end = lines.firstIndex(where: { $0.contains("END OPENSSH PRIVATE KEY") }), end > start else {
                throw SSHKeyError.malformed("missing PEM armor")
            }
            let b64 = lines[(start + 1)..<end].joined().trimmingCharacters(in: .whitespaces)
            guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                throw SSHKeyError.malformed("invalid base64")
            }
            let bytes = Array(data)
            guard bytes.starts(with: SSHPrivateKeyLoader.opensshMagic) else { throw SSHKeyError.malformed("bad magic") }
            var r = SSHReader(bytes[SSHPrivateKeyLoader.opensshMagic.count...])
            cipher = try r.readUTF8()
            kdf = try r.readUTF8()
            kdfOptions = try r.readString()
            let count = try r.readUInt32()
            guard count == 1 else { throw SSHKeyError.unsupportedFormat("files with \(count) keys") }
            publicBlob = try r.readString()
            privateSection = try r.readString()
            trailer = try r.readBytes(r.remaining)
        }
    }

    static func cipherParameters(_ name: String) throws -> (keyLen: Int, ivLen: Int, mode: String) {
        switch name {
        case "aes128-ctr": return (16, 16, "ctr")
        case "aes192-ctr": return (24, 16, "ctr")
        case "aes256-ctr": return (32, 16, "ctr")
        case "aes128-cbc": return (16, 16, "cbc")
        case "aes192-cbc": return (24, 16, "cbc")
        case "aes256-cbc": return (32, 16, "cbc")
        case "aes128-gcm@openssh.com": return (16, 12, "gcm")
        case "aes256-gcm@openssh.com": return (32, 12, "gcm")
        default: throw SSHKeyError.unsupportedCipher(name)
        }
    }

    static func parseOpenSSH(_ text: String, passphrase: String?) throws -> LoadedPrivateKey {
        let c = try OpenSSHContainer(pem: text)
        var plain = c.privateSection
        if c.isEncrypted {
            guard let passphrase, !passphrase.isEmpty else { throw SSHKeyError.passphraseRequired }
            guard c.kdf == "bcrypt" else { throw SSHKeyError.unsupportedFormat("KDF \(c.kdf)") }
            let params = try cipherParameters(c.cipher)
            var o = SSHReader(c.kdfOptions)
            let salt = try o.readString()
            let rounds = try o.readUInt32()
            var derived = [UInt8](repeating: 0, count: params.keyLen + params.ivLen)
            let pass = Array(passphrase.utf8)
            let rc = xf_bcrypt_pbkdf(pass, pass.count, salt, salt.count, &derived, derived.count, rounds)
            guard rc == 0 else { throw SSHKeyError.malformed("bcrypt_pbkdf failed") }
            let key = Array(derived[0..<params.keyLen])
            let iv = Array(derived[params.keyLen...])
            switch params.mode {
            case "ctr": plain = try aes(key: key, iv: iv, data: c.privateSection, mode: CCMode(kCCModeCTR))
            case "cbc": plain = try aes(key: key, iv: iv, data: c.privateSection, mode: CCMode(kCCModeCBC))
            case "gcm":
                guard c.trailer.count >= 16 else { throw SSHKeyError.malformed("missing GCM tag") }
                do {
                    let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: c.privateSection,
                                                    tag: c.trailer.prefix(16))
                    plain = Array(try AES.GCM.open(box, using: SymmetricKey(data: key)))
                } catch { throw SSHKeyError.wrongPassphrase }
            default: throw SSHKeyError.unsupportedCipher(c.cipher)
            }
        }
        var r = SSHReader(plain)
        let check1 = try r.readUInt32()
        let check2 = try r.readUInt32()
        guard check1 == check2 else {
            throw c.isEncrypted ? SSHKeyError.wrongPassphrase : SSHKeyError.malformed("check bytes mismatch")
        }
        let typeName = try r.readUTF8()
        guard let type = SSHKeyType(rawValue: typeName) else { throw SSHKeyError.unsupportedKeyType(typeName) }
        switch type {
        case .ed25519:
            _ = try r.readString() // public key
            let priv = try r.readString()
            guard priv.count == 64 else { throw SSHKeyError.malformed("ed25519 key length") }
            let comment = (try? r.readUTF8()) ?? ""
            let k = try Curve25519.Signing.PrivateKey(rawRepresentation: priv[0..<32])
            return LoadedPrivateKey(type: .ed25519, material: .ed25519(k), publicKeyBlob: c.publicBlob, comment: comment)
        case .rsa:
            let n = try r.readMPInt()
            let e = try r.readMPInt()
            let d = try r.readMPInt()
            _ = try r.readMPInt() // iqmp
            let p = try r.readMPInt()
            let q = try r.readMPInt()
            let comment = (try? r.readUTF8()) ?? ""
            let k = try _RSA.Signing.PrivateKey(n: n, e: e, d: d, p: p, q: q)
            return LoadedPrivateKey(type: .rsa, material: .rsa(k, n: n, e: e), publicKeyBlob: c.publicBlob, comment: comment)
        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            _ = try r.readString() // curve name
            _ = try r.readString() // Q
            let dRaw = try r.readMPInt()
            let comment = (try? r.readUTF8()) ?? ""
            let material: LoadedPrivateKey.Material
            switch type {
            case .ecdsaP256: material = .p256(try P256.Signing.PrivateKey(rawRepresentation: leftPad(dRaw, 32)))
            case .ecdsaP384: material = .p384(try P384.Signing.PrivateKey(rawRepresentation: leftPad(dRaw, 48)))
            default: material = .p521(try P521.Signing.PrivateKey(rawRepresentation: leftPad(dRaw, 66)))
            }
            return LoadedPrivateKey(type: type, material: material, publicKeyBlob: c.publicBlob, comment: comment)
        }
    }

    static func leftPad(_ b: [UInt8], _ n: Int) -> [UInt8] {
        b.count >= n ? Array(b.suffix(n)) : [UInt8](repeating: 0, count: n - b.count) + b
    }

    static func aes(key: [UInt8], iv: [UInt8], data: [UInt8], mode: CCMode) throws -> [UInt8] {
        var cryptor: CCCryptorRef?
        var status = CCCryptorCreateWithMode(CCOperation(kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES),
                                             CCPadding(ccNoPadding), iv, key, key.count, nil, 0, 0,
                                             mode == CCMode(kCCModeCTR) ? CCModeOptions(kCCModeOptionCTR_BE) : 0,
                                             &cryptor)
        guard status == kCCSuccess, let cryptor else { throw SSHKeyError.malformed("cipher setup failed") }
        defer { CCCryptorRelease(cryptor) }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        status = CCCryptorUpdate(cryptor, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw SSHKeyError.malformed("decryption failed") }
        return Array(out.prefix(moved))
    }

    // MARK: PEM helpers

    static func ed25519(_ k: Curve25519.Signing.PrivateKey, comment: String) -> LoadedPrivateKey {
        var w = SSHWriter()
        w.writeString(SSHKeyType.ed25519.rawValue)
        w.writeString(Array(k.publicKey.rawRepresentation))
        return LoadedPrivateKey(type: .ed25519, material: .ed25519(k), publicKeyBlob: w.bytes, comment: comment)
    }

    static func ecdsa(_ m: LoadedPrivateKey.Material) -> LoadedPrivateKey {
        var w = SSHWriter()
        let type: SSHKeyType
        let curve: String
        let q: [UInt8]
        switch m {
        case .p256(let k): type = .ecdsaP256; curve = "nistp256"; q = Array(k.publicKey.x963Representation)
        case .p384(let k): type = .ecdsaP384; curve = "nistp384"; q = Array(k.publicKey.x963Representation)
        case .p521(let k): type = .ecdsaP521; curve = "nistp521"; q = Array(k.publicKey.x963Representation)
        default: fatalError("not ECDSA")
        }
        w.writeString(type.rawValue)
        w.writeString(curve)
        w.writeString(q)
        return LoadedPrivateKey(type: type, material: m, publicKeyBlob: w.bytes, comment: "")
    }

    static func rsaFromCryptoKey(_ k: _RSA.Signing.PrivateKey) throws -> LoadedPrivateKey {
        let prims = try k.publicKey.getKeyPrimitives()
        let n = Array(prims.modulus).drop { $0 == 0 }
        let e = Array(prims.publicExponent).drop { $0 == 0 }
        var w = SSHWriter()
        w.writeString(SSHKeyType.rsa.rawValue)
        w.writeMPInt(Array(e))
        w.writeMPInt(Array(n))
        return LoadedPrivateKey(type: .rsa, material: .rsa(k, n: Array(n), e: Array(e)), publicKeyBlob: w.bytes, comment: "")
    }
}

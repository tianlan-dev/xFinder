import XCTest
import Crypto
import _CryptoExtras
@testable import xFinderKit

final class KeyParsingTests: XCTestCase {
    static let passphrase = "fixture-pass"

    func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return url.path
    }

    /// Fingerprints from `ssh-keygen -lf` (Fixtures/fingerprints.txt).
    func expected() throws -> [String: (bits: Int, fingerprint: String)] {
        let text = try String(contentsOfFile: try fixture("fingerprints.txt"), encoding: .utf8)
        var out: [String: (Int, String)] = [:]
        for line in text.split(separator: "\n") {
            let p = line.split(separator: " ")
            out[String(p[0])] = (Int(p[1])!, String(p[2]))
        }
        return out
    }

    func testFingerprintsMatchSSHKeygen() throws {
        let types: [String: SSHKeyType] = ["ed25519": .ed25519, "ed25519_encrypted": .ed25519, "rsa": .rsa,
                                           "rsa_pem": .rsa, "ecdsa_p256": .ecdsaP256,
                                           "ecdsa_p384_encrypted": .ecdsaP384, "ecdsa_p521": .ecdsaP521]
        for (name, e) in try expected() {
            let path = try fixture(name)
            let encrypted = name.contains("encrypted")
            let key = try SSHPrivateKeyLoader.load(path: path, passphrase: encrypted ? Self.passphrase : nil)
            XCTAssertEqual(key.fingerprint, e.fingerprint, name)
            XCTAssertEqual(key.type, types[name], name)
            let info = try SSHPrivateKeyLoader.info(path: path)
            XCTAssertEqual(info.isEncrypted, encrypted, name)
            XCTAssertEqual(info.type, types[name], name)
            XCTAssertEqual(info.bits, e.bits, name)
            if let fp = info.fingerprint { XCTAssertEqual(fp, e.fingerprint, name) }
        }
    }

    func testWrongOrMissingPassphrase() throws {
        let path = try fixture("ed25519_encrypted")
        XCTAssertThrowsError(try SSHPrivateKeyLoader.load(path: path, passphrase: nil))
        XCTAssertThrowsError(try SSHPrivateKeyLoader.load(path: path, passphrase: "wrong"))
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try SSHPrivateKeyLoader.parse("not a key", passphrase: nil))
        XCTAssertThrowsError(try SSHPrivateKeyLoader.info("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----"))
    }

    func testRSASignaturesVerify() throws {
        for name in ["rsa", "rsa_pem"] {
            let key = try SSHPrivateKeyLoader.load(path: try fixture(name), passphrase: nil)
            guard case .rsa(let priv, _, _) = key.material else { return XCTFail("not RSA") }
            let data = Data("session data to sign".utf8)
            for variant in [RSASHA512.self, RSASHA256.self, RSASHA1.self] as [RSASHAVariant.Type] {
                let sig = try variant.sign(priv, data)
                XCTAssertEqual(sig.count, 256)
                XCTAssertTrue(variant.verify(priv.publicKey, sig, data), "\(name) \(variant)")
                XCTAssertFalse(variant.verify(priv.publicKey, sig, Data("tampered".utf8)))
            }
            XCTAssertEqual(key.nioKeys.count, 3)
        }
    }
}

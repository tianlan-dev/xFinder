import Foundation
import Citadel
import NIOCore
import NIOSSH
import Crypto

/// Opens an authenticated SSH connection (shared by SFTP and SCP/shell).
enum SSHConnector {
    static var algorithms: SSHAlgorithms {
        var a = SSHAlgorithms()
        a.keyExchangeAlgorithms = .add([DiffieHellmanGroup14Sha256.self])
        a.publicKeyAlgorihtms = .add([(Insecure.RSA.PublicKey.self, Insecure.RSA.Signature.self)])
        return a
    }

    /// Connects, verifies the host key and signs in. Returns the client and the
    /// credentials that worked (reused by transfer connections).
    static func connect(config: ConnectionConfig, environment: ConnectionEnvironment,
                        cached: CachedCredentials?) async throws -> (SSHClient, CachedCredentials?) {
        let authenticator = SSHAuthenticator(config: config, environment: environment, cached: cached)
        let validator = HostKeyValidator(host: config.host, port: config.port, environment: environment)
        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: config.host,
                port: config.port,
                authenticationMethod: .custom(authenticator),
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                algorithms: algorithms,
                connectTimeout: .seconds(SFTPFileSystem.connectTimeout))
        } catch {
            if validator.rejected.value { throw RemoteError.hostKeyRejected }
            if authenticator.cancelled.value { throw RemoteError.cancelledByUser }
            if authenticator.started.value { throw authenticator.failure.value ?? RemoteError.authenticationFailed("") }
            throw mapConnectError(error)
        }
        await authenticator.commitSuccess()
        return (client, authenticator.successfulCredentials)
    }

    static func mapConnectError(_ error: Error) -> RemoteError {
        if let r = error as? RemoteError { return r }
        let text = String(describing: error)
        if text.contains("connectTimeout") || text.contains("timeout") || text.contains("Timeout") { return .timeout }
        if let ioe = error as? IOError { return .connectionFailed(ioe.description) }
        if text.contains("NIOConnectionError") || text.contains("connectionRefused") || text.contains("ECONNREFUSED") {
            return .connectionFailed("The server refused the connection.")
        }
        if text.contains("unknownHost") || text.contains("resolution") {
            return .connectionFailed("The server address could not be resolved.")
        }
        return .connectionFailed(text)
    }
}

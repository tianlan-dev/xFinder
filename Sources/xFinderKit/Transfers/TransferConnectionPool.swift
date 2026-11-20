import Foundation

/// Dedicated connections for the transfer queue, separate from the browser tabs.
/// Idle connections are reused per server and closed after `idleTimeout`.
public actor TransferConnectionPool {
    public typealias Factory = @Sendable () async throws -> RemoteFileSystem

    private struct Idle {
        var fs: RemoteFileSystem
        var since: Date
    }

    private var factories: [String: Factory] = [:]
    private var idle: [String: [Idle]] = [:]
    private var sweepTask: Task<Void, Never>?
    public let idleTimeout: TimeInterval

    public init(idleTimeout: TimeInterval = 60) {
        self.idleTimeout = idleTimeout
    }

    /// Registers (or replaces) how to open a new connection to `endpointID`.
    public func register(_ endpointID: String, factory: @escaping Factory) {
        factories[endpointID] = factory
    }

    public func isRegistered(_ endpointID: String) -> Bool { factories[endpointID] != nil }

    public func acquire(_ endpointID: String) async throws -> RemoteFileSystem {
        while var list = idle[endpointID], !list.isEmpty {
            let entry = list.removeLast()
            idle[endpointID] = list
            if entry.fs.isConnected { return entry.fs }
        }
        guard let factory = factories[endpointID] else {
            throw RemoteError.notConnected
        }
        return try await factory()
    }

    /// Returns a connection. Broken connections (`reusable == false`) are closed.
    public func release(_ endpointID: String, _ fs: RemoteFileSystem, reusable: Bool = true) {
        guard reusable, fs.isConnected else {
            Task { await fs.disconnect() }
            return
        }
        idle[endpointID, default: []].append(Idle(fs: fs, since: Date()))
        scheduleSweep()
    }

    public var idleCount: Int { idle.values.reduce(0) { $0 + $1.count } }

    private func scheduleSweep() {
        guard sweepTask == nil else { return }
        let interval = max(1, idleTimeout / 2)
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                if await self.sweep() { return }
            }
        }
    }

    /// Closes connections idle for too long. Returns true when nothing is left.
    private func sweep() -> Bool {
        let cutoff = Date().addingTimeInterval(-idleTimeout)
        for (key, list) in idle {
            let (old, keep) = (list.filter { $0.since < cutoff }, list.filter { $0.since >= cutoff })
            idle[key] = keep
            for e in old { Task { await e.fs.disconnect() } }
        }
        idle = idle.filter { !$0.value.isEmpty }
        if idle.isEmpty {
            sweepTask = nil
            return true
        }
        return false
    }

    public func closeAll() async {
        let all = idle.values.flatMap { $0 }
        idle = [:]
        sweepTask?.cancel()
        sweepTask = nil
        for e in all { await e.fs.disconnect() }
    }
}

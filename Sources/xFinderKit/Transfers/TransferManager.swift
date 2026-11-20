import Foundation
import Combine

/// The transfer queue: batches expand into per-file items after scanning, the
/// oldest batch is served first and at most `maxConcurrent` items run at once.
@MainActor
public final class TransferManager: ObservableObject {
    @Published public private(set) var batches: [TransferBatch] = []

    public var maxConcurrent: Int = 3 {
        didSet { maxConcurrent = min(8, max(1, maxConcurrent)); pump() }
    }
    public var conflictPolicy: ConflictPolicy = .ask
    /// Asks the user about an existing destination. Without a handler conflicts are skipped.
    public var conflictHandler: (@MainActor (TransferConflict) async -> ConflictAnswer)?
    /// Called when an item finishes (e.g. to refresh listings).
    public var onItemFinished: (@MainActor (TransferItem) -> Void)?

    public let pool: TransferConnectionPool
    public let stagingRoot: URL
    /// Speed smoothing factor (exponential moving average) and sample interval.
    let smoothing = 0.3
    let sampleInterval: TimeInterval = 0.5

    private var timer: Timer?
    private var prompting = false
    private var promptWaiters: [CheckedContinuation<Void, Never>] = []
    private var serverCopyUnavailable: Set<String> = []

    public init(pool: TransferConnectionPool = TransferConnectionPool(), stagingRoot: URL) {
        self.pool = pool
        self.stagingRoot = stagingRoot
    }

    // MARK: Queries

    public var allItems: [TransferItem] { batches.flatMap(\.items) }

    public var hasActiveTransfers: Bool {
        batches.contains { $0.isScanning && !$0.isCancelled } || allItems.contains { $0.state.isPending }
    }

    public var runningCount: Int { allItems.filter { $0.state == .running }.count }

    public var totalSpeed: Double {
        allItems.filter { $0.state == .running }.reduce(0) { $0 + $1.bytesPerSecond }
    }

    public var summary: String {
        let items = allItems
        let running = items.filter { $0.state == .running }.count
        let queued = items.filter { $0.state == .queued }.count
        let paused = items.filter { $0.state == .paused }.count
        let failed = items.filter { if case .failed = $0.state { return true }; return false }.count
        let scanning = batches.filter { $0.isScanning && !$0.isCancelled }.count
        if running == 0 && queued == 0 && scanning == 0 {
            if failed > 0 { return failed == 1 ? "1 transfer failed" : "\(failed) transfers failed" }
            if paused > 0 { return "\(paused) paused" }
            return items.isEmpty ? "No transfers" : "All transfers finished"
        }
        var parts: [String] = []
        if running > 0 { parts.append("\(running) transferring") }
        if queued > 0 { parts.append("\(queued) waiting") }
        if scanning > 0 { parts.append("preparing \(scanning)") }
        if running > 0 {
            parts.append(TransferFormat.speed(totalSpeed))
            let remaining = items.filter { $0.state.isPending }.reduce(UInt64(0)) {
                $0 + (($1.totalBytes ?? 0) > $1.transferredBytes ? ($1.totalBytes ?? 0) - $1.transferredBytes : 0)
            }
            if totalSpeed > 1, remaining > 0 { parts.append(TransferFormat.duration(Double(remaining) / totalSpeed) + " left") }
        }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }

    // MARK: Enqueue

    @discardableResult
    public func enqueue(_ request: TransferRequest) throws -> TransferBatch {
        let batch: TransferBatch
        switch request {
        case .upload(let urls, let endpoint, let directory):
            guard !urls.isEmpty else { throw TransferRequestError.nothingToTransfer }
            batch = TransferBatch(title: urls.count == 1 ? "Upload “\(urls[0].lastPathComponent)” to \(endpoint.label)"
                                                         : "Upload \(urls.count) items to \(endpoint.label)", isCopy: false)
            batch.scanTask = Task { [weak self] in await self?.scanUpload(batch, urls, endpoint, directory) }
        case .download(let items, let endpoint, let directory):
            guard !items.isEmpty else { throw TransferRequestError.nothingToTransfer }
            batch = TransferBatch(title: items.count == 1 ? "Download “\(items[0].name)” from \(endpoint.label)"
                                                          : "Download \(items.count) items from \(endpoint.label)", isCopy: false)
            batch.scanTask = Task { [weak self] in await self?.scanDownload(batch, items, endpoint, directory) }
        case .copy(let items, let from, let to, let directory, let duplicate):
            guard !items.isEmpty else { throw TransferRequestError.nothingToTransfer }
            if from.id == to.id {
                for item in items where item.isDirectoryLike && item.type != .symlink
                    && RemotePath.isSameOrDescendant(directory, of: item.path) {
                    throw TransferRequestError.copyIntoItself(item.name)
                }
            }
            let verb = duplicate ? "Duplicate" : "Copy"
            batch = TransferBatch(title: items.count == 1 ? "\(verb) “\(items[0].name)” to \(to.label)"
                                                          : "\(verb) \(items.count) items to \(to.label)", isCopy: true)
            batch.scanTask = Task { [weak self] in await self?.scanCopy(batch, items, from, to, directory, duplicate) }
        }
        batches.append(batch)
        startTimer()
        return batch
    }

    // MARK: Controls

    public func pause(_ item: TransferItem) {
        switch item.state {
        case .queued: item.state = .paused
        case .running:
            item.stopReason = .paused
            item.task?.cancel()
        default: return
        }
        changed()
    }

    public func resume(_ item: TransferItem) {
        guard item.state == .paused else { return }
        item.state = .queued
        changed()
        pump()
    }

    public func cancel(_ item: TransferItem) {
        switch item.state {
        case .queued, .paused:
            item.state = .cancelled
            item.finishedAt = Date()
            Task { await cleanupTemporary(item) }
            if let b = batch(of: item) { batchMaybeFinished(b) }
        case .running:
            item.stopReason = .cancelled
            item.task?.cancel()
        default: return
        }
        changed()
        pump()
    }

    public func retry(_ item: TransferItem) {
        switch item.state {
        case .failed, .cancelled: break
        default: return
        }
        if let b = batch(of: item), b.isCancelled { b.isCancelled = false }
        item.state = .queued
        item.finishedAt = nil
        item.bytesPerSecond = 0
        changed()
        startTimer()
        pump()
    }

    public func cancel(_ batch: TransferBatch) {
        batch.isCancelled = true
        batch.scanTask?.cancel()
        for item in batch.items where !item.state.isFinished { cancel(item) }
        batchMaybeFinished(batch)
        changed()
    }

    public func pauseAll() {
        for item in allItems where item.state.isPending { pause(item) }
    }

    public func resumeAll() {
        for item in allItems where item.state == .paused { item.state = .queued }
        changed()
        pump()
    }

    public func clearFinished() {
        for b in batches where !b.isFinished {
            b.items.removeAll { $0.state.isFinished }
        }
        batches.removeAll { $0.isFinished }
        changed()
    }

    func batch(of item: TransferItem) -> TransferBatch? { batches.first { $0.id == item.batchID } }

    private func changed() { objectWillChange.send() }

    // MARK: Scheduling

    public func pump() {
        var running = runningCount
        guard running < maxConcurrent else { return }
        for batch in batches where !batch.isCancelled {
            for item in batch.items where item.state == .queued && item.task == nil {
                start(item, in: batch)
                running += 1
                if running >= maxConcurrent { return }
            }
        }
    }

    private func start(_ item: TransferItem, in batch: TransferBatch) {
        item.state = .running
        item.stopReason = nil
        item.bytesPerSecond = 0
        changed()
        startTimer()
        item.task = Task { [weak self] in
            guard let self else { return }
            var outcome: TransferState
            do {
                outcome = try await self.run(item, batch)
            } catch {
                if let reason = item.stopReason { outcome = reason }
                else if error is CancellationError { outcome = .cancelled }
                else { outcome = .failed(Self.describe(error)) }
            }
            item.task = nil
            item.stopReason = nil
            if outcome == .cancelled { await self.cleanupTemporary(item) }
            if outcome == .completed, let total = item.totalBytes { item.progressBox.value = total; item.transferredBytes = total }
            item.state = outcome
            item.bytesPerSecond = 0
            if outcome.isFinished {
                item.finishedAt = Date()
                self.onItemFinished?(item)
            }
            self.batchMaybeFinished(batch)
            self.changed()
            self.pump()
        }
    }

    private func batchMaybeFinished(_ batch: TransferBatch) {
        guard batch.isFinished, let dir = batch.stagingDirectory else { return }
        try? FileManager.default.removeItem(at: dir)
        batch.stagingDirectory = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func tick() {
        var any = false
        for item in allItems where item.state == .running {
            any = true
            let now = item.progressBox.value
            let delta = now >= item.lastSample ? Double(now - item.lastSample) : 0
            item.lastSample = now
            let instant = delta / sampleInterval
            item.bytesPerSecond = item.bytesPerSecond == 0 ? instant : item.bytesPerSecond * (1 - smoothing) + instant * smoothing
            if item.transferredBytes != now { item.transferredBytes = now }
        }
        if any { changed() }
        if !any && !hasActiveTransfers {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: Scanning

    private func add(_ item: TransferItem, to batch: TransferBatch) {
        batch.items.append(item)
        changed()
        pump()
    }

    private func finishScan(_ batch: TransferBatch, error: Error?) {
        if let error, !(error is CancellationError), !batch.isCancelled {
            batch.scanError = Self.describe(error)
        }
        batch.isScanning = false
        batchMaybeFinished(batch)
        changed()
        pump()
    }

    private func scanUpload(_ batch: TransferBatch, _ urls: [URL], _ endpoint: RemoteEndpoint, _ directory: String) async {
        do {
            try await withConnection(endpoint) { conn in
                for url in urls {
                    try Task.checkCancellation()
                    try await self.addLocal(url, into: directory, endpoint, batch, conn)
                }
            }
            finishScan(batch, error: nil)
        } catch {
            finishScan(batch, error: error)
        }
    }

    private func addLocal(_ url: URL, into remoteDirectory: String, _ endpoint: RemoteEndpoint,
                          _ batch: TransferBatch, _ conn: RemoteFileSystem) async throws {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if values.isSymbolicLink == true { return }
        let remotePath = RemotePath.join(remoteDirectory, url.lastPathComponent)
        if values.isDirectory == true {
            if let existing = await conn.exists(remotePath) {
                guard existing.isDirectoryLike else { throw RemoteError.alreadyExists(remotePath) }
            } else {
                try await conn.createDirectory(remotePath)
            }
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                .sorted { NaturalSort.less($0.lastPathComponent, $1.lastPathComponent) }
            for child in children {
                try await addLocal(child, into: remotePath, endpoint, batch, conn)
            }
        } else {
            let info = Self.localInfo(url) ?? TransferSourceInfo(size: nil, modificationDate: nil, permissions: nil)
            add(TransferItem(batchID: batch.id, kind: .upload, source: .local(url),
                             destination: .remote(endpoint, remotePath), sourceInfo: info), to: batch)
        }
    }

    private func scanDownload(_ batch: TransferBatch, _ items: [RemoteItem], _ endpoint: RemoteEndpoint, _ directory: URL) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await withConnection(endpoint) { conn in
                for item in items {
                    try Task.checkCancellation()
                    try await self.addRemoteForDownload(item, into: directory, endpoint, batch, conn)
                }
            }
            finishScan(batch, error: nil)
        } catch {
            finishScan(batch, error: error)
        }
    }

    private func addRemoteForDownload(_ item: RemoteItem, into directory: URL, _ endpoint: RemoteEndpoint,
                                      _ batch: TransferBatch, _ conn: RemoteFileSystem) async throws {
        try Task.checkCancellation()
        if item.type == .symlink || item.type == .other { return }
        let local = directory.appendingPathComponent(Self.localSafeName(item.name), isDirectory: item.isDirectory)
        if item.isDirectory {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir) {
                guard isDir.boolValue else { throw RemoteError.alreadyExists(local.path) }
            } else {
                do { try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true) }
                catch { throw RemoteError.localIO(error.localizedDescription) }
            }
            let children = try await conn.list(item.path).sorted { NaturalSort.less($0.name, $1.name) }
            for child in children {
                try await addRemoteForDownload(child, into: local, endpoint, batch, conn)
            }
        } else {
            add(TransferItem(batchID: batch.id, kind: .download, source: .remote(endpoint, item.path),
                             destination: .local(local), sourceInfo: Self.remoteInfo(item)), to: batch)
        }
    }

    private func scanCopy(_ batch: TransferBatch, _ items: [RemoteItem], _ from: RemoteEndpoint, _ to: RemoteEndpoint,
                          _ directory: String, _ duplicate: Bool) async {
        let sameServer = from.id == to.id
        let useServerCopy = sameServer && from.capabilities.contains(.serverCopy) && !serverCopyUnavailable.contains(from.id)
        do {
            try await withConnection(to) { destConn in
                var existingNames: Set<String>? = nil
                for item in items {
                    try Task.checkCancellation()
                    if item.type == .symlink || item.type == .other { continue }
                    var name = item.name
                    // Pasting into the item's own folder behaves like Duplicate.
                    if duplicate || (sameServer && RemotePath.parent(item.path) == RemotePath.normalize(directory)) {
                        if existingNames == nil { existingNames = Set(try await destConn.list(directory).map(\.name)) }
                        name = TransferNaming.duplicateName(item.name, isDirectory: item.isDirectory, existing: existingNames!)
                        existingNames!.insert(name)
                    }
                    let destPath = RemotePath.join(directory, name)
                    if useServerCopy {
                        self.add(TransferItem(batchID: batch.id, kind: .serverCopy, source: .remote(from, item.path),
                                              destination: .remote(to, destPath), sourceInfo: Self.remoteInfo(item)), to: batch)
                    } else if sameServer {
                        try await self.addRemoteForCopy(item, to: destPath, from, to, batch, srcConn: destConn, destConn: destConn)
                    } else {
                        try await self.withConnection(from) { srcConn in
                            try await self.addRemoteForCopy(item, to: destPath, from, to, batch, srcConn: srcConn, destConn: destConn)
                        }
                    }
                }
            }
            finishScan(batch, error: nil)
        } catch {
            finishScan(batch, error: error)
        }
    }

    private func addRemoteForCopy(_ item: RemoteItem, to destPath: String, _ from: RemoteEndpoint, _ to: RemoteEndpoint,
                                  _ batch: TransferBatch, srcConn: RemoteFileSystem, destConn: RemoteFileSystem) async throws {
        try Task.checkCancellation()
        if item.type == .symlink || item.type == .other { return }
        if item.isDirectory {
            if let existing = await destConn.exists(destPath) {
                guard existing.isDirectoryLike else { throw RemoteError.alreadyExists(destPath) }
            } else {
                try await destConn.createDirectory(destPath)
            }
            let children = try await srcConn.list(item.path).sorted { NaturalSort.less($0.name, $1.name) }
            for child in children {
                try await addRemoteForCopy(child, to: RemotePath.join(destPath, child.name), from, to, batch,
                                           srcConn: srcConn, destConn: destConn)
            }
        } else {
            add(TransferItem(batchID: batch.id, kind: .copy, source: .remote(from, item.path),
                             destination: .remote(to, destPath), sourceInfo: Self.remoteInfo(item)), to: batch)
        }
    }

    // MARK: Running

    private func run(_ item: TransferItem, _ batch: TransferBatch) async throws -> TransferState {
        switch item.kind {
        case .upload: return try await runUpload(item, batch)
        case .download: return try await runDownload(item, batch)
        case .copy: return try await runStagedCopy(item, batch)
        case .serverCopy: return try await runServerCopy(item, batch)
        }
    }

    enum Resolution: Equatable {
        case proceed(name: String, replacing: Bool, resumeFrom: UInt64)
        case skip
        case stop
    }

    /// Decides what to do when the destination exists.
    func resolve(_ item: TransferItem, _ batch: TransferBatch, existing: TransferSourceInfo?, canResume: Bool,
                 existingNames: () async -> Set<String>) async -> Resolution {
        let name = item.destination.name
        guard let existing else { return .proceed(name: name, replacing: false, resumeFrom: 0) }
        var decision: ConflictDecision
        if let d = item.resolvedDecision ?? batch.applyToAll {
            decision = d
        } else {
            switch conflictPolicy {
            case .overwrite: decision = .replace
            case .skip: decision = .skip
            case .keepBoth: decision = .keepBoth
            case .overwriteIfNewer:
                if let s = item.sourceInfo.modificationDate, let d = existing.modificationDate {
                    decision = s.timeIntervalSince(d) > 1 ? .replace : .skip
                } else {
                    decision = .replace
                }
            case .ask:
                let resumable = canResume && !batch.isCopy && (existing.size ?? 0) < (item.sourceInfo.size ?? 0)
                let conflict = TransferConflict(name: name, destination: item.destination.displayPath,
                                                sourceSize: item.sourceInfo.size, sourceDate: item.sourceInfo.modificationDate,
                                                destinationSize: existing.size, destinationDate: existing.modificationDate,
                                                canResume: resumable, isCopy: batch.isCopy)
                let answer = await askConflict(conflict, batch)
                if answer.applyToAll { batch.applyToAll = answer.decision }
                decision = answer.decision
            }
        }
        item.resolvedDecision = decision
        if decision == .resume {
            let smaller = (existing.size ?? 0) < (item.sourceInfo.size ?? 0)
            if !(canResume && smaller) { decision = .replace }
        }
        switch decision {
        case .replace: return .proceed(name: name, replacing: true, resumeFrom: 0)
        case .resume: return .proceed(name: name, replacing: true, resumeFrom: existing.size ?? 0)
        case .keepBoth:
            let names = await existingNames()
            return .proceed(name: TransferNaming.keepBothName(name, isDirectory: item.sourceInfo.isDirectory, existing: names),
                            replacing: false, resumeFrom: 0)
        case .skip: return .skip
        case .stop: return .stop
        }
    }

    private func askConflict(_ conflict: TransferConflict, _ batch: TransferBatch) async -> ConflictAnswer {
        while prompting {
            await withCheckedContinuation { promptWaiters.append($0) }
        }
        if let d = batch.applyToAll { return ConflictAnswer(d, applyToAll: true) }
        if batch.isCancelled { return ConflictAnswer(.stop) }
        prompting = true
        defer {
            prompting = false
            if !promptWaiters.isEmpty { promptWaiters.removeFirst().resume() }
        }
        guard let handler = conflictHandler else { return ConflictAnswer(.skip) }
        return await handler(conflict)
    }

    private func stopBatch(_ batch: TransferBatch, except item: TransferItem) {
        batch.isCancelled = true
        batch.scanTask?.cancel()
        for other in batch.items where other.id != item.id && !other.state.isFinished { cancel(other) }
    }

    private func runUpload(_ item: TransferItem, _ batch: TransferBatch) async throws -> TransferState {
        guard case .local(let localURL) = item.source, case .remote(let endpoint, _) = item.destination else {
            throw RemoteError.protocolError("Invalid upload")
        }
        return try await withConnection(endpoint) { conn in
            guard let plan = try await self.planRemoteWrite(item, batch, conn, endpoint) else {
                return item.state == .cancelled || batch.isCancelled ? .cancelled : .skipped("")
            }
            try await self.writeRemote(item, from: localURL, plan: plan, conn: conn, endpoint: endpoint, progressBase: 0)
            return .completed
        }
    }

    struct RemoteWritePlan {
        var destination: String
        var temporary: String
        var replacing: Bool
        var replacedPermissions: UInt32?
        var offset: UInt64
    }

    /// Conflict handling and temporary-file setup for writing to a server.
    /// Returns nil when the item is skipped or the batch was stopped.
    private func planRemoteWrite(_ item: TransferItem, _ batch: TransferBatch, _ conn: RemoteFileSystem,
                                 _ endpoint: RemoteEndpoint, allowResume: Bool = true) async throws -> RemoteWritePlan? {
        let caps = endpoint.capabilities
        let atomic = caps.contains(.atomicUpload)
        var destPath = item.destination.path
        // Continue a paused upload from its temporary file.
        if allowResume, !atomic, caps.canResumeUpload, let temp = item.temporaryPath,
           let t = await conn.exists(temp), let size = t.size, size > 0 {
            let existing = await conn.exists(destPath)
            return RemoteWritePlan(destination: destPath, temporary: temp, replacing: existing != nil,
                                   replacedPermissions: existing?.permissions, offset: size)
        }
        let existing = await conn.exists(destPath)
        if let e = existing, e.isDirectoryLike { throw RemoteError.alreadyExists(destPath) }
        let parent = RemotePath.parent(destPath)
        let resolution = await resolve(item, batch, existing: existing.map(Self.remoteInfo),
                                       canResume: allowResume && caps.canResumeUpload && !atomic) {
            Set((try? await conn.list(parent))?.map(\.name) ?? [])
        }
        switch resolution {
        case .skip: return nil
        case .stop:
            stopBatch(batch, except: item)
            return nil
        case .proceed(let name, let replacing, let resumeFrom):
            destPath = RemotePath.join(parent, name)
            if name != item.destination.name { item.destination = .remote(endpoint, destPath) }
            let temp = atomic ? destPath : RemotePath.join(parent, TransferNaming.remoteTemporaryName(name))
            item.temporaryPath = atomic ? nil : temp
            var plan = RemoteWritePlan(destination: destPath, temporary: temp, replacing: replacing,
                                       replacedPermissions: replacing ? existing?.permissions : nil, offset: 0)
            if !atomic, await conn.exists(temp) != nil { try? await conn.delete(temp, isDirectory: false) }
            if resumeFrom > 0, !atomic {
                try await conn.rename(destPath, to: temp)
                plan.replacing = false
                plan.offset = resumeFrom
            }
            return plan
        }
    }

    private func writeRemote(_ item: TransferItem, from localURL: URL, plan: RemoteWritePlan, conn: RemoteFileSystem,
                             endpoint: RemoteEndpoint, progressBase: UInt64) async throws {
        let caps = endpoint.capabilities
        let box = item.progressBox
        box.value = progressBase + plan.offset
        item.lastSample = box.value
        item.transferredBytes = box.value
        try await conn.upload(localURL, to: plan.temporary, offset: plan.offset) { box.value = progressBase + $0 }
        if plan.temporary != plan.destination {
            do {
                try await conn.rename(plan.temporary, to: plan.destination)
            } catch {
                guard await conn.exists(plan.destination) != nil else { throw error }
                try await conn.delete(plan.destination, isDirectory: false)
                try await conn.rename(plan.temporary, to: plan.destination)
            }
        }
        item.temporaryPath = nil
        if caps.contains(.chmod), let p = plan.replacedPermissions ?? item.sourceInfo.permissions {
            try? await conn.setPermissions(plan.destination, mode: p & 0o7777)
        }
        if let d = item.sourceInfo.modificationDate {
            try? await conn.setModificationDate(plan.destination, date: d)
        }
    }

    private func runDownload(_ item: TransferItem, _ batch: TransferBatch) async throws -> TransferState {
        guard case .remote(let endpoint, let remotePath) = item.source, case .local(var destURL) = item.destination else {
            throw RemoteError.protocolError("Invalid download")
        }
        let fm = FileManager.default
        let caps = endpoint.capabilities
        var offset: UInt64 = 0
        var tempURL: URL
        if caps.canResumeDownload, let temp = item.temporaryPath, let size = Self.localInfo(URL(fileURLWithPath: temp))?.size, size > 0 {
            tempURL = URL(fileURLWithPath: temp)
            offset = size
        } else {
            let existing = Self.localInfo(destURL)
            if let e = existing, e.isDirectory { throw RemoteError.alreadyExists(destURL.path) }
            let dir = destURL.deletingLastPathComponent()
            let resolution = await resolve(item, batch, existing: existing, canResume: caps.canResumeDownload) {
                Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            }
            switch resolution {
            case .skip: return .skipped("")
            case .stop:
                stopBatch(batch, except: item)
                return .cancelled
            case .proceed(let name, _, let resumeFrom):
                destURL = dir.appendingPathComponent(name)
                if name != item.destination.name { item.destination = .local(destURL) }
                tempURL = dir.appendingPathComponent(TransferNaming.localTemporaryName(name))
                item.temporaryPath = tempURL.path
                try? fm.removeItem(at: tempURL)
                if resumeFrom > 0 {
                    do { try fm.moveItem(at: destURL, to: tempURL) } catch { throw RemoteError.localIO(error.localizedDescription) }
                    offset = resumeFrom
                }
            }
        }
        let box = item.progressBox
        box.value = offset
        item.lastSample = offset
        item.transferredBytes = offset
        try await withConnection(endpoint) { conn in
            try await conn.download(remotePath, to: tempURL, offset: offset) { box.value = $0 }
        }
        do {
            if fm.fileExists(atPath: destURL.path) {
                _ = try fm.replaceItemAt(destURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: destURL)
            }
        } catch {
            throw RemoteError.localIO(error.localizedDescription)
        }
        item.temporaryPath = nil
        if let d = item.sourceInfo.modificationDate {
            try? fm.setAttributes([.modificationDate: d], ofItemAtPath: destURL.path)
        }
        return .completed
    }

    private func runStagedCopy(_ item: TransferItem, _ batch: TransferBatch) async throws -> TransferState {
        guard case .remote(let from, let srcPath) = item.source, case .remote(let to, _) = item.destination else {
            throw RemoteError.protocolError("Invalid copy")
        }
        // Resolve the conflict first so the user is not asked after a long download.
        let plan: RemoteWritePlan? = try await withConnection(to) { conn in
            try await self.planRemoteWrite(item, batch, conn, to, allowResume: false)
        }
        guard let plan else { return batch.isCancelled ? .cancelled : .skipped("") }

        let fm = FileManager.default
        let staging: URL
        if let s = batch.stagingDirectory { staging = s } else {
            staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            batch.stagingDirectory = staging
        }
        let itemDir = staging.appendingPathComponent(item.id.uuidString, isDirectory: true)
        do { try fm.createDirectory(at: itemDir, withIntermediateDirectories: true) }
        catch { throw RemoteError.localIO(error.localizedDescription) }
        let staged = itemDir.appendingPathComponent("data")
        item.stagingURL = itemDir
        let box = item.progressBox
        box.value = 0
        item.lastSample = 0
        try await withConnection(from) { conn in
            try await conn.download(srcPath, to: staged, offset: 0) { box.value = $0 }
        }
        let size = item.sourceInfo.size ?? (Self.localInfo(staged)?.size ?? 0)
        try await withConnection(to) { conn in
            try await self.writeRemote(item, from: staged, plan: plan, conn: conn, endpoint: to, progressBase: size)
        }
        try? fm.removeItem(at: itemDir)
        item.stagingURL = nil
        return .completed
    }

    private func runServerCopy(_ item: TransferItem, _ batch: TransferBatch) async throws -> TransferState {
        guard case .remote(let from, let srcPath) = item.source, case .remote(let to, _) = item.destination else {
            throw RemoteError.protocolError("Invalid copy")
        }
        return try await withConnection(to) { conn in
            var destPath = item.destination.path
            let existing = await conn.exists(destPath)
            let parent = RemotePath.parent(destPath)
            let resolution = await self.resolve(item, batch, existing: existing.map(Self.remoteInfo), canResume: false) {
                Set((try? await conn.list(parent))?.map(\.name) ?? [])
            }
            switch resolution {
            case .skip: return .skipped("")
            case .stop:
                self.stopBatch(batch, except: item)
                return .cancelled
            case .proceed(let name, let replacing, _):
                destPath = RemotePath.join(parent, name)
                if name != item.destination.name { item.destination = .remote(to, destPath) }
                if replacing, let e = existing {
                    try await conn.delete(destPath, isDirectory: e.isDirectoryLike)
                }
            }
            do {
                try await conn.copyItem(srcPath, to: destPath)
                return .completed
            } catch RemoteError.unsupported {
                // Fall back to download-then-upload for this server from now on.
                self.serverCopyUnavailable.insert(from.id)
                let source = try await conn.stat(srcPath)
                try await self.addRemoteForCopy(source, to: destPath, from, to, batch, srcConn: conn, destConn: conn)
                return .skipped("Server-side copy is not available; copying through this Mac")
            }
        }
    }

    private func cleanupTemporary(_ item: TransferItem) async {
        if let staging = item.stagingURL {
            try? FileManager.default.removeItem(at: staging)
            item.stagingURL = nil
        }
        guard let temp = item.temporaryPath else { return }
        item.temporaryPath = nil
        switch item.kind {
        case .download:
            try? FileManager.default.removeItem(atPath: temp)
        case .upload, .copy:
            guard let endpoint = item.destination.endpoint else { return }
            try? await withConnection(endpoint) { conn in
                try await conn.delete(temp, isDirectory: false)
            }
        case .serverCopy:
            break
        }
    }

    // MARK: Helpers

    /// Borrows a pooled connection for the duration of `body`.
    func withConnection<T>(_ endpoint: RemoteEndpoint, _ body: (RemoteFileSystem) async throws -> T) async throws -> T {
        let conn = try await pool.acquire(endpoint.id)
        do {
            let result = try await body(conn)
            await pool.release(endpoint.id, conn, reusable: true)
            return result
        } catch {
            let broken = error is CancellationError || (error as? RemoteError)?.isConnectivity == true
            await pool.release(endpoint.id, conn, reusable: !broken)
            throw error
        }
    }

    static func remoteInfo(_ item: RemoteItem) -> TransferSourceInfo {
        TransferSourceInfo(size: item.size, modificationDate: item.modificationDate, permissions: item.permissions,
                           isDirectory: item.isDirectoryLike)
    }

    static func localInfo(_ url: URL) -> TransferSourceInfo? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let type = attrs[.type] as? FileAttributeType
        return TransferSourceInfo(size: (attrs[.size] as? NSNumber)?.uint64Value,
                                  modificationDate: attrs[.modificationDate] as? Date,
                                  permissions: (attrs[.posixPermissions] as? NSNumber).map { $0.uint32Value & 0o7777 },
                                  isDirectory: type == .typeDirectory)
    }

    /// Remote names may contain "/" (e.g. S3 keys are split already) or ":"; keep them valid locally.
    static func localSafeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: ":")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "_" : cleaned
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return "\(error)"
    }
}

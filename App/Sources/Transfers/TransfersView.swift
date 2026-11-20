import SwiftUI
import xFinderKit

/// Transfers window: batches with per-file progress and controls.
struct TransfersView: View {
    @EnvironmentObject var transfers: TransferCenter
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(transfers.summary).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Pause All") { transfers.manager.pauseAll() }
                Button("Resume All") { transfers.manager.resumeAll() }
                Button("Clear Finished") { transfers.manager.clearFinished() }
            }
            .padding(10)
            Divider()
            EditSessionsSection()
            if transfers.manager.batches.isEmpty {
                Text("No transfers").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(transfers.manager.batches.reversed()) { batch in
                        BatchSection(batch: batch)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 560, minHeight: 320)
    }
}

struct BatchSection: View {
    @ObservedObject var batch: TransferBatch
    @EnvironmentObject var transfers: TransferCenter
    @State private var expanded = true

    var body: some View {
        Section {
            if expanded {
                ForEach(batch.items) { item in TransferRow(item: item) }
            }
        } header: {
            HStack {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                Text(batch.title).font(.headline).lineLimit(1)
                if batch.isScanning && !batch.isCancelled {
                    ProgressView().controlSize(.small)
                    Text("Preparing… \(batch.items.count) files").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(batchStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !batch.isFinished {
                    Button("Cancel") { transfers.manager.cancel(batch) }.buttonStyle(.borderless)
                }
            }
        } footer: {
            if let err = batch.scanError {
                Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
            }
        }
    }

    var batchStatus: String {
        let done = batch.items.filter { $0.state == .completed }.count
        return "\(done) of \(batch.items.count) done"
    }
}

struct TransferRow: View {
    @ObservedObject var item: TransferItem
    @EnvironmentObject var transfers: TransferCenter

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1)
                Text("\(item.source.displayPath) → \(item.destination.displayPath)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if item.state == .running || item.state == .paused {
                    if let f = item.fractionCompleted {
                        ProgressView(value: f)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(stateColor).lineLimit(2)
            }
            Spacer()
            controls
        }
        .padding(.vertical, 2)
    }

    var icon: String {
        switch item.kind {
        case .upload: return "arrow.up.circle"
        case .download: return "arrow.down.circle"
        case .copy, .serverCopy: return "doc.on.doc"
        }
    }

    var stateColor: Color {
        switch item.state {
        case .failed: return .red
        case .completed: return .green
        default: return .secondary
        }
    }

    var detail: String {
        var parts: [String] = []
        switch item.state {
        case .running, .paused:
            if let total = item.totalBytes {
                parts.append("\(TransferFormat.bytes(item.transferredBytes)) of \(TransferFormat.bytes(total))")
            }
            if item.state == .running, item.bytesPerSecond > 0 { parts.append(TransferFormat.speed(item.bytesPerSecond)) }
            if let r = item.remainingSeconds { parts.append(TransferFormat.duration(r) + " left") }
            if item.state == .paused { parts.append("Paused") }
        default:
            parts.append(item.state.label)
            if item.state == .completed, let s = item.sourceInfo.size, item.kind != .serverCopy { parts.append(TransferFormat.bytes(s)) }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder var controls: some View {
        HStack(spacing: 6) {
            switch item.state {
            case .running, .queued:
                iconButton("pause.circle", "Pause") { transfers.manager.pause(item) }
                iconButton("xmark.circle", "Cancel") { transfers.manager.cancel(item) }
            case .paused:
                iconButton("play.circle", "Resume") { transfers.manager.resume(item) }
                iconButton("xmark.circle", "Cancel") { transfers.manager.cancel(item) }
            case .failed, .cancelled:
                iconButton("arrow.clockwise.circle", "Retry") { transfers.manager.retry(item) }
            default:
                EmptyView()
            }
        }
    }

    func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).imageScale(.large) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

/// Summary line at the bottom of the main window.
struct TransferStatusBar: View {
    @EnvironmentObject var transfers: TransferCenter
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack {
            Image(systemName: "arrow.up.arrow.down")
            Text(transfers.summary).lineLimit(1)
            Spacer()
            Button("Transfers") { openWindow(id: "transfers") }.buttonStyle(.borderless)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
    }
}

import SwiftUI
import UniformTypeIdentifiers
import xFinderKit

/// Horizontal tab strip with status dots, drag reordering and a context menu.
struct SessionTabBar: View {
    @EnvironmentObject var tabs: SessionTabs

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs.sessions) { s in
                        SessionTabItem(session: s, isSelected: s.id == tabs.current?.id)
                        Divider().padding(.vertical, 6)
                    }
                }
            }
            Button {
                tabs.newTab(after: tabs.current)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Tab (⌘T)")
            .padding(.horizontal, 8)
        }
        .frame(height: 32)
        .background(.bar)
    }
}

struct SessionTabItem: View {
    @ObservedObject var session: ConnectionSession
    let isSelected: Bool
    @EnvironmentObject var tabs: SessionTabs
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var switchTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                tabs.close(session)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(hovering || isSelected ? 1 : 0.4)
            .help("Close Tab (⌘W)")
            if session.status != .idle {
                Circle()
                    .fill(session.status.color)
                    .frame(width: 7, height: 7)
                    .help(session.status.label)
            }
            Text(session.title)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: 180)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(hovering && !isSelected ? Color.primary.opacity(0.05) : .clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Color.accentColor : .clear)
                .frame(height: 2)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(dropTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { tabs.select(session) }
        .draggable(session.id.uuidString)
        .dropDestination(for: String.self) { ids, _ in
            guard let s = ids.first, let id = UUID(uuidString: s) else { return false }
            tabs.move(from: id, to: session.id)
            return true
        }
        // Hovering a dragged remote file over a tab for 0.4 s switches to it.
        .onDrop(of: [RemoteDragPayload.type], isTargeted: Binding(get: { dropTargeted }, set: { targeted in
            dropTargeted = targeted
            switchTask?.cancel()
            if targeted {
                switchTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if !Task.isCancelled { tabs.select(session) }
                }
            }
        })) { _ in false }
        .contextMenu {
            Button("New Tab") { tabs.newTab(after: session) }
            Button("Duplicate Tab") { tabs.duplicate(session) }
            Divider()
            Button("Close Tab") { tabs.close(session) }
            Button("Close Other Tabs") { tabs.closeOthers(session) }
                .disabled(tabs.sessions.count < 2)
        }
        .help(session.site.map { "\($0.protocolType.shortName) \($0.host)" } ?? "Quick Connect")
    }
}

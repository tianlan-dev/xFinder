import SwiftUI
import Combine
import xFinderKit

/// The tabs of the main window.
@MainActor
final class SessionTabs: ObservableObject {
    unowned let app: AppModel
    @Published private(set) var sessions: [ConnectionSession] = []
    @Published var selectedID: UUID? { didSet { observeCurrent() } }
    private var currentObserver: AnyCancellable?

    /// Republishes changes of the selected session so menus update.
    private func observeCurrent() {
        currentObserver = current?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    init(app: AppModel) {
        self.app = app
        let first = ConnectionSession(app: app)
        sessions = [first]
        selectedID = first.id
        observeCurrent()
        app.prompts.onPromptForOrigin = { [weak self] origin in
            // A background tab needs authentication: bring it to the front.
            if self?.sessions.contains(where: { $0.id == origin }) == true { self?.selectedID = origin }
        }
    }

    var current: ConnectionSession? { sessions.first { $0.id == selectedID } ?? sessions.first }

    func select(_ s: ConnectionSession) { selectedID = s.id }

    @discardableResult
    func newTab(after: ConnectionSession? = nil, site: Site? = nil) -> ConnectionSession {
        let s = ConnectionSession(app: app, site: nil)
        if let after, let i = sessions.firstIndex(where: { $0.id == after.id }) {
            sessions.insert(s, at: i + 1)
        } else {
            sessions.append(s)
        }
        selectedID = s.id
        if let site { s.open(site) }
        return s
    }

    /// Opens a favorite: reuse the current tab if it is empty, else open a new one after it.
    func open(_ site: Site) {
        if let c = current, c.isEmpty {
            c.open(site)
        } else {
            newTab(after: current, site: site)
        }
    }

    func openAll(_ sites: [Site]) {
        for s in sites { open(s) }
    }

    func duplicate(_ s: ConnectionSession) {
        let n = newTab(after: s)
        n.showHidden = s.showHidden
        if let site = s.site {
            n.site = site
            n.isQuickConnect = s.isQuickConnect
            n.connect(restorePath: s.currentPath)
        }
    }

    /// Closing the last tab leaves an empty Quick Connect tab; the window stays.
    func close(_ s: ConnectionSession) {
        s.close()
        guard let i = sessions.firstIndex(where: { $0.id == s.id }) else { return }
        sessions.remove(at: i)
        if sessions.isEmpty {
            let fresh = ConnectionSession(app: app)
            sessions = [fresh]
            selectedID = fresh.id
        } else if selectedID == s.id {
            selectedID = sessions[min(i, sessions.count - 1)].id
        }
    }

    func closeOthers(_ s: ConnectionSession) {
        for other in sessions where other.id != s.id { other.close() }
        sessions = [s]
        selectedID = s.id
    }

    func closeCurrent() { if let c = current { close(c) } }

    func selectNext(_ delta: Int) {
        guard let c = current, let i = sessions.firstIndex(where: { $0.id == c.id }), !sessions.isEmpty else { return }
        let n = (i + delta + sessions.count) % sessions.count
        selectedID = sessions[n].id
    }

    func select(index: Int) {
        guard index >= 0 else { return }
        if index < sessions.count { selectedID = sessions[index].id }
    }

    func move(from source: UUID, to target: UUID) {
        guard let from = sessions.firstIndex(where: { $0.id == source }),
              let to = sessions.firstIndex(where: { $0.id == target }), from != to else { return }
        let s = sessions.remove(at: from)
        sessions.insert(s, at: to)
    }

    func session(for id: UUID) -> ConnectionSession? { sessions.first { $0.id == id } }
}

import SwiftUI
import AppKit
import xFinderKit

/// Checks GitHub Releases and installs updates in place with one click.
@MainActor
final class UpdateController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case verifying
        case relaunching
        case failed(String)
    }

    unowned let app: AppModel
    @Published private(set) var isChecking = false
    @Published private(set) var status: String?
    @Published private(set) var offered: AvailableUpdate?
    @Published private(set) var phase: Phase = .idle
    private var scheduled = false
    private var panel: NSPanel?
    private var installTask: Task<Void, Never>?

    let feed = UpdateFeed()

    init(app: AppModel) { self.app = app }

    var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }
    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

    var installer: UpdateInstaller {
        UpdateInstaller(appURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.skylan.xFinder")
    }

    /// True when installing will ask for an administrator password (e.g. /Applications owned by root).
    var needsAdmin: Bool { !installer.canReplaceWithoutAdmin() }

    /// About 5 seconds after launch, at most once per 24 hours.
    func scheduleAutomaticCheck() {
        guard !scheduled else { return }
        scheduled = true
        #if DEBUG
        // End-to-end testing hook: `-XFAutoInstallUpdate YES` checks and installs without prompting.
        if UserDefaults.standard.bool(forKey: "XFAutoInstallUpdate") {
            Task { await check(userInitiated: true, autoInstall: true) }
            return
        }
        #endif
        Task {
            try? await Task.sleep(nanoseconds: UInt64(UpdateCatalog.launchDelay * 1_000_000_000))
            guard app.settings.updates.automaticallyCheck,
                  UpdateCatalog.isCheckDue(lastCheck: app.settings.updates.lastCheck) else { return }
            await check(userInitiated: false)
        }
    }

    func checkNow(userInitiated: Bool) {
        Task { await check(userInitiated: userInitiated) }
    }

    private func check(userInitiated: Bool, autoInstall: Bool = false) async {
        guard !isChecking else { return }
        if offered != nil, panel != nil { panel?.makeKeyAndOrderFront(nil); return }
        isChecking = true
        status = "Checking…"
        defer { isChecking = false }
        do {
            let release = try await feed.fetchLatest()
            app.settings.updates.lastCheck = Date()
            let skipped = userInitiated ? nil : app.settings.updates.skippedVersion
            guard let release, let update = UpdateCatalog.availableUpdate(release, currentVersion: currentVersion,
                                                                          skippedVersion: skipped) else {
                status = "xFinder \(currentVersion) is up to date."
                if userInitiated && !autoInstall { alert("You’re up to date", "xFinder \(currentVersion) is the newest version.") }
                return
            }
            status = "Version \(update.version) is available."
            offered = update
            phase = .idle
            showPanel()
            if autoInstall { install() }
        } catch {
            status = "Update check failed."
            if userInitiated { alert("Update check failed", Self.describe(error)) }
        }
    }

    // MARK: Panel

    private func showPanel() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            p.title = "Software Update"
            p.isReleasedWhenClosed = false
            // Panels hide while the app is inactive by default; an automatic check
            // usually finishes while another app is frontmost, so keep it visible.
            p.hidesOnDeactivate = false
            p.level = .floating
            p.contentView = NSHostingView(rootView: UpdatePanelView(updates: self))
            p.center()
            panel = p
        }
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    func later() { closePanel() }

    func skip() {
        if let v = offered?.version { app.settings.updates.skippedVersion = v.description }
        closePanel()
    }

    func openReleasePage() {
        NSWorkspace.shared.open(offered?.release.htmlURL ?? feed.releasesPage)
    }

    private func closePanel() {
        installTask?.cancel()
        installTask = nil
        panel?.close()
        panel = nil
        offered = nil
        phase = .idle
    }

    // MARK: Install

    func install() {
        guard let update = offered, installTask == nil else { return }
        let installer = installer
        phase = .downloading(0)
        installTask = Task {
            do {
                let prepared = try await installer.prepare(update) { p in
                    Task { @MainActor in
                        guard case .downloading = self.phase else { return }
                        self.phase = p >= 1 ? .verifying : .downloading(p)
                    }
                }
                try Task.checkCancellation()
                phase = .relaunching
                try installer.launchSwapHelper(prepared)
                app.skipQuitConfirmation = true
                NSApp.terminate(nil)
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(Self.describe(error))
            }
            installTask = nil
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }
}

/// The "new version available" window: version, release notes, progress and actions.
struct UpdatePanelView: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        if let u = updates.offered {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A new version of xFinder is available!").font(.headline)
                        Text("xFinder \(u.version.description) is available — you have \(updates.currentVersion). Would you like to update now?")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Release Notes:").font(.subheadline.bold())
                ScrollView {
                    Text(notes(u)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
                progress(u)
                buttons
            }
            .padding(20)
            .frame(minWidth: 480, minHeight: 360)
        }
    }

    private func notes(_ u: AvailableUpdate) -> AttributedString {
        let text = u.notes.isEmpty ? "No release notes." : u.notes
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    @ViewBuilder private func progress(_ u: AvailableUpdate) -> some View {
        switch updates.phase {
        case .idle:
            if updates.needsAdmin {
                Text("xFinder’s folder is not writable, so macOS will ask for an administrator password after xFinder quits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p)
                Text("Downloading… \(TransferFormat.bytes(UInt64(Double(u.zip.size) * p))) of \(TransferFormat.bytes(u.zip.size))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .verifying:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView().progressViewStyle(.linear)
                Text("Verifying and unpacking…").font(.caption).foregroundStyle(.secondary)
            }
        case .relaunching:
            Text("Installing and relaunching…").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text("The update could not be installed: \(message) The installed app was not changed.")
                .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var busy: Bool {
        switch updates.phase {
        case .downloading, .verifying, .relaunching: return true
        default: return false
        }
    }

    private var buttons: some View {
        HStack {
            Button("Skip This Version") { updates.skip() }.disabled(busy)
            Spacer()
            if case .failed = updates.phase {
                Button("Open Releases Page") { updates.openReleasePage() }
            }
            Button(busy ? "Cancel" : "Remind Me Later") { updates.later() }
                .keyboardShortcut(.cancelAction)
                .disabled(updates.phase == .relaunching)
            Button(isFailed ? "Try Again" : "Update") { updates.install() }
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
        }
    }

    private var isFailed: Bool { if case .failed = updates.phase { return true } else { return false } }
}

/// Settings ▸ General ▸ Updates.
struct UpdatesSettingsSection: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var updates: UpdateController

    var body: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: $app.settings.updates.automaticallyCheck)
            HStack {
                Button("Check Now") { updates.checkNow(userInitiated: true) }.disabled(updates.isChecking)
                if updates.isChecking { ProgressView().controlSize(.small) }
                Spacer()
                Text("Version \(updates.currentVersion) (\(updates.currentBuild))").foregroundStyle(.secondary)
            }
            if let s = updates.status {
                Text(s).font(.caption).foregroundStyle(.secondary)
            }
            if let last = app.settings.updates.lastCheck {
                Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            Footnote("Updates come from the GitHub Releases page of tianlan-dev/xFinder. Clicking Update downloads the new version, checks its SHA-256, replaces this copy of xFinder and relaunches it.")
        }
    }
}

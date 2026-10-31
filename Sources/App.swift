import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

struct CueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // The menubar item lives in AppDelegate. The empty Settings scene drops its ⌘, command too.
    var body: some Scene { Settings { EmptyView() }.commands { CommandGroup(replacing: .appSettings) {} } }
}

/// Owns the menubar item and its popover. SwiftUI's MenuBarExtra can't open from code, which the
/// global hotkey needs; an NSStatusItem with an NSPopover can.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = Model()
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var hotKey: HotKey?
    private var count: AnyCancellable?
    private var closedAt = Date.distantPast
    /// A 1-point stand-in for the icon while the menubar is hidden.
    private let anchor: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: true)
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return w
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Cue")
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(clicked)
        self.item = item

        let host = NSHostingController(rootView: PopoverView().environmentObject(model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        count = model.$sessions.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let button = self.item?.button else { return }
                let n = self.model.waiting
                button.title = n > 0 ? " \(n)" : ""
            }
        }
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)) { [weak self] in self?.toggle() }
    }

    @objc private func clicked() {
        // A click on the icon closes the transient popover first, then lands here: don't reopen it.
        if Date().timeIntervalSince(closedAt) > 0.3 { toggle() }
    }

    func popoverDidClose(_ notification: Notification) {
        closedAt = Date()
        anchor.orderOut(nil)
    }

    func toggle() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item?.button, let bar = button.window else { return }
        model.resort()
        // An app without a Dock icon has to activate itself, or the text areas won't take keys.
        NSApp.activate(ignoringOtherApps: true)
        // A hidden menubar (a full-screen app, or auto-hide) leaves the icon above the screen, and NSPopover
        // closes the moment it resizes against an offscreen anchor. Point at the screen's top edge instead.
        let screen = NSScreen.screens.first { $0.frame.minX <= bar.frame.midX && bar.frame.midX < $0.frame.maxX } ?? NSScreen.main
        if let screen, bar.frame.minY >= screen.frame.maxY - 1, let view = anchor.contentView {
            anchor.setFrame(NSRect(x: bar.frame.midX, y: screen.frame.maxY - 1, width: 1, height: 1), display: false)
            anchor.orderFrontRegardless()
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }
}

@MainActor
final class Model: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published var drafts: [String: String] = [:]
    @Published private(set) var notes: [String: String] = [:]
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var hooksInstalled = false
    @Published private(set) var order: [String] = []
    private var pending: [String: Pending] = [:]
    private var probing: Set<String> = []
    private var timer: Timer?
    /// osascript and codex calls block, so they run one at a time here, off the main thread and off Swift's task pool.
    private let worker = DispatchQueue(label: "cue.worker")

    /// A sent prompt waiting for proof: `last_prompt_at` for Claude and Codex, a receipt for Amp.
    private struct Pending {
        let sessionId: String, at: Double, deadline: Double, text: String
        var inboxId: String?
    }

    var waiting: Int { sessions.filter { $0.status != "working" && $0.deliverable }.count }

    /// Sorted once per popover open, so a row never moves under your cursor.
    var rows: [Session] {
        sessions.sorted { (order.firstIndex(of: $0.sessionId) ?? .max) < (order.firstIndex(of: $1.sessionId) ?? .max) }
    }

    init() {
        reload()
        resort()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        var live: [Session] = []
        for var s in Store.all() {
            if Self.expired(s) {
                // Claude exited without SessionEnd (tab closed, crash), or a session went quiet for good.
                // Re-check under the lock, so a resumed session that just rewrote this file keeps it.
                _ = try? Store.locked { if let fresh = Store.read(s.sessionId), Self.expired(fresh) { Store.delete(s.sessionId) } }
                continue
            }
            if !Self.alive(s) { continue }  // hidden, not deleted: an Amp window that stopped beating may resume
            if s.isClaude, s.status != "idle", s.interrupted { s = setIdle(s) { $0.status != "idle" && $0.interrupted } }
            live.append(s)
        }
        if live != sessions { sessions = live }
        settlePending()
    }

    /// Amp files outlive a stopped heartbeat by an hour, so the app never races a plugin that resumes.
    static func expired(_ s: Session) -> Bool {
        s.agent == "amp" ? Date().timeIntervalSince1970 - (s.heartbeat ?? 0) > 3600 : !alive(s)
    }

    static func alive(_ s: Session) -> Bool {
        let now = Date().timeIntervalSince1970
        switch s.agent {
        case "amp":
            return now - (s.heartbeat ?? 0) < 30  // the plugin stopped: Amp quit or switched threads
        case "codex":
            // Codex sends SessionEnd once a thread sits unopened for 30 minutes. A day without any
            // change covers a SessionEnd lost to a crash or reboot.
            return now - max(s.updatedAt, s.transcriptModified ?? 0) < 86_400
        default:
            guard let pid = s.pid, let start = s.pidStart else { return true }  // PID unknown: keep until SessionEnd
            return Proc(pid).map { abs($0.start - start) < 0.01 } ?? false
        }
    }

    /// Runs when the popover opens.
    func resort() {
        let rank = ["needs_you": 0, "idle": 1, "working": 2]
        order = sessions.sorted {
            let (a, b) = (rank[$0.status] ?? 3, rank[$1.status] ?? 3)
            if a != b { return a < b }
            return a == 1 ? $0.updatedAt < $1.updatedAt : $0.project < $1.project
        }.map(\.sessionId)
        hooksInstalled = Self.hooksPresent()
        recheckStale()
    }

    /// Whether you can type a prompt in this row right now.
    func canType(_ s: Session) -> Bool {
        s.deliverable && !busy.contains(s.rowKey) && (!s.isClaude || s.status != "needs_you")
    }

    /// A row quiet at working for 15 s gets one look at its screen.
    private func recheckStale() {
        let now = Date().timeIntervalSince1970
        for s in sessions where s.isClaude && s.deliverable && s.status == "working" && !probing.contains(s.sessionId)
            && now - max(s.updatedAt, s.transcriptModified ?? 0) > 15 {
            probing.insert(s.sessionId)
            worker.async {
                let idle = Delivery.looksIdle(s)
                DispatchQueue.main.async {
                    self.probing.remove(s.sessionId)
                    guard idle else { return }
                    _ = self.setIdle(s) { $0.status == "working" && $0.updatedAt == s.updatedAt }
                    self.reload()
                }
            }
        }
    }

    func name(_ s: Session) -> String {
        let clash = sessions.filter { $0.project == s.project && $0.agent == s.agent }.count > 1
        return "\(s.agentName) · \(s.project)" + (clash ? " · \(s.sessionId.prefix(s.agent == "amp" ? 6 : 4))" : "")
    }

    func send(_ s: Session) {
        let key = s.rowKey, text = drafts[key, default: ""]
        busy.insert(key)
        notes[key] = "Sending…"
        worker.async {
            let outcome = Delivery.send(sessionId: s.sessionId, text: text)
            DispatchQueue.main.async { self.finish(s, key: key, text: text, outcome: outcome) }
        }
    }

    func open(_ s: Session) {
        guard let sid = s.itermSessionId else { return }
        let key = s.rowKey
        worker.async {
            let error = Delivery.open(itermSessionId: sid)
            DispatchQueue.main.async { self.notes[key] = error }
        }
    }

    private func finish(_ s: Session, key: String, text: String, outcome: Outcome) {
        switch outcome {
        case .refused(let why):
            busy.remove(key)
            notes[key] = why
        case .failed(let why):
            busy.remove(key)
            copy(text)
            notes[key] = "\(why). Prompt copied to clipboard."
        case .sent(let at):
            if Delivery.skipsConfirmation(text) {
                busy.remove(key)
                drafts[key] = ""
                notes[key] = "Sent"
            } else {
                // The 5 s wait starts once typing ends; a long prompt takes seconds to type.
                pending[key] = Pending(sessionId: s.sessionId, at: at, deadline: Date().timeIntervalSince1970 + 5, text: text)
            }
        case .accepted(let note):
            busy.remove(key)
            drafts[key] = ""
            notes[key] = note
        case .inbox(let id):
            let now = Date().timeIntervalSince1970
            pending[key] = Pending(sessionId: s.sessionId, at: now, deadline: now + 5, text: text, inboxId: id)
        }
    }

    private func settlePending() {
        let now = Date().timeIntervalSince1970
        for (key, p) in pending {
            if let id = p.inboxId {
                switch Inbox.settle(thread: p.sessionId, id: id, waited: now - p.at) {
                case .delivered:
                    drafts[key] = ""
                    notes[key] = nil
                case .failed(let why):
                    copy(p.text)
                    notes[key] = "\(why). Prompt copied to clipboard."
                case .withdrawn:
                    copy(p.text)
                    notes[key] = "Amp didn't pick it up. Prompt copied to clipboard."
                case .unconfirmed:
                    copy(p.text)
                    notes[key] = "Not confirmed. Prompt copied to clipboard."
                case nil:
                    continue
                }
            } else if Delivery.confirmed(p.sessionId, at: p.at) {
                drafts[key] = ""
                notes[key] = nil
            } else if now > p.deadline {
                copy(p.text)
                notes[key] = "Not confirmed. Prompt copied to clipboard."
            } else {
                continue
            }
            pending[key] = nil
            busy.remove(key)
        }
    }

    /// Esc or a denied permission leaves no Stop event, so the app sets idle itself when `stillTrue`
    /// holds for the file as it reads under the lock.
    private func setIdle(_ s: Session, if stillTrue: (Session) -> Bool) -> Session {
        (try? Store.locked { () -> Session in
            guard var fresh = Store.read(s.sessionId) else { return s }
            guard stillTrue(fresh) else { return fresh }
            fresh.status = "idle"
            fresh.updatedAt = Date().timeIntervalSince1970
            try Store.write(fresh)
            return fresh
        }) ?? s
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// True when any agent is wired to this app: Claude Code or Codex hooks, or the Amp plugin.
    static func hooksPresent() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let exe = Bundle.main.executablePath else { return false }
        let wired = [".claude/settings.json", ".codex/hooks.json"].contains {
            (try? String(contentsOf: home.appendingPathComponent($0), encoding: .utf8))?.contains(exe) == true
        }
        return wired || FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/amp/plugins/cue.ts").path)
    }
}

struct PopoverView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No agent sessions yet").font(.headline)
                    Text(model.hooksInstalled
                         ? "A Claude Code, Codex or Amp session appears after its next prompt or reply."
                         : "No agent is wired to Cue yet. Run ./install.sh in the cue folder.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(16)
            } else if model.rows.count <= 3 {
                rowList
            } else {
                // ponytail: fixed height past 3 rows; a measured height would need a GeometryReader dance.
                ScrollView { rowList }.frame(height: 600)
            }
            Divider()
            HStack {
                Label(model.hooksInstalled ? "Hooks installed" : "Hooks missing",
                      systemImage: model.hooksInstalled ? "checkmark.circle" : "exclamationmark.triangle")
                Spacer()
                Text("⌃⌥Space opens Cue")
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 380)
        // Each open puts the cursor in the first row you can type in: after sorting, the longest wait.
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didShowNotification)) { _ in
            focused = model.rows.first(where: model.canType)?.sessionId
        }
    }

    @FocusState private var focused: String?

    private var rowList: some View {
        VStack(spacing: 0) {
            ForEach(model.rows, id: \.sessionId) { s in
                RowView(session: s, focus: $focused)
                Divider()
            }
        }
    }
}

struct RowView: View {
    @EnvironmentObject var model: Model
    let session: Session
    var focus: FocusState<String?>.Binding

    var body: some View {
        let key = session.rowKey
        let target = session.deliverable
        // Codex and Amp hold a prompt until the running turn ends; typing into Claude's tab needs it idle.
        let queues = !session.isClaude
        let canType = model.canType(session)
        let editing = focus.wrappedValue == session.sessionId
        let draft = Binding(get: { model.drafts[key, default: ""] }, set: { model.drafts[key] = $0 })
        let canSend = canType && (queues || session.status == "idle") && !Delivery.sanitize(draft.wrappedValue).isEmpty

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.name(session)).font(.headline).lineLimit(1)
                Spacer()
                StatusBadge(status: target ? session.status : "none", since: session.updatedAt)
            }
            if let message = session.lastMessage, !message.isEmpty {
                Text(message.split(whereSeparator: \.isNewline).joined(separator: " "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            PromptEditor(text: draft, placeholder: placeholder(target), enabled: canType)
                .focused(focus, equals: session.sessionId)
            HStack(spacing: 6) {
                if canType { Text("⌘↩ to send").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                // Only the row being typed in owns ⌘Return, so rows never compete for the shortcut.
                Button("Send") { model.send(session) }
                    .disabled(!canSend)
                    .keyboardShortcut(editing ? KeyboardShortcut(.return, modifiers: .command) : nil)
                if session.agent != "codex" {  // Codex hooks run in its daemon, so the tab is unknown
                    Button("Open") { model.open(session) }.disabled(session.itermSessionId == nil)
                }
            }
            if let note = model.notes[key] {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func placeholder(_ target: Bool) -> String {
        if !target { return "Not in iTerm2" }
        if session.isClaude { return session.status == "needs_you" ? "Answer in terminal" : "Next prompt" }
        return session.status == "idle" ? "Next prompt" : "Queue a prompt"
    }
}

/// A four-line text area for the next prompt; longer prompts scroll inside it.
/// Return adds a line break; the row's Send button takes ⌘Return.
struct PromptEditor: View {
    @Binding var text: String
    let placeholder: String
    let enabled: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .frame(height: 76)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)  // TextEditor's 5 pt line padding plus ours
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.6)
    }
}

struct StatusBadge: View {
    let status: String
    let since: Double

    var body: some View {
        let (label, color): (String, Color) = switch status {
        case "idle": ("Idle", .green)
        case "needs_you": ("Needs you", .orange)
        case "working": ("Working", .blue)
        default: ("Not in iTerm2", .gray)
        }
        TimelineView(.periodic(from: .now, by: 1)) { _ in Text("\(label) · \(ago)") }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.6)))
    }

    private var ago: String {
        let s = max(0, Int(Date().timeIntervalSince1970 - since))
        return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h"
    }
}

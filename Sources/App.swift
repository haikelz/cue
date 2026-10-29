import AppKit
import SwiftUI

struct RelayApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            Image(systemName: "terminal")
            if model.waiting > 0 { Text("\(model.waiting)") }
        }
        .menuBarExtraStyle(.window)
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
    private var pending: [String: (sessionId: String, at: Double, deadline: Double, text: String)] = [:]
    private var probing: Set<String> = []
    private var timer: Timer?
    /// osascript calls block, so they run one at a time here, off the main thread and off Swift's task pool.
    private let worker = DispatchQueue(label: "claude-relay.osascript")

    var waiting: Int { sessions.filter { $0.status != "working" && $0.itermSessionId != nil }.count }

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
            if !Self.alive(s) {
                // Claude exited without SessionEnd (tab closed, crash). Re-check under the lock, so a
                // resumed session that just rewrote this file keeps it.
                _ = try? Store.locked { if let fresh = Store.read(s.sessionId), !Self.alive(fresh) { Store.delete(s.sessionId) } }
                continue
            }
            if s.status != "idle", s.interrupted { s = setIdle(s) { $0.status != "idle" && $0.interrupted } }
            live.append(s)
        }
        if live != sessions { sessions = live }
        settlePending()
    }

    static func alive(_ s: Session) -> Bool {
        guard let pid = s.claudePid, let start = s.claudeStart else { return true }  // PID unknown: keep until SessionEnd
        return Proc(pid).map { abs($0.start - start) < 0.01 } ?? false
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

    /// A row quiet at working for 15 s gets one look at its screen.
    private func recheckStale() {
        let now = Date().timeIntervalSince1970
        for s in sessions where s.status == "working" && !probing.contains(s.sessionId)
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
        sessions.filter { $0.project == s.project }.count > 1 ? "\(s.project) · \(s.sessionId.prefix(4))" : s.project
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
                pending[key] = (s.sessionId, at, Date().timeIntervalSince1970 + 5, text)
            }
        }
    }

    private func settlePending() {
        let now = Date().timeIntervalSince1970
        for (key, p) in pending {
            if Delivery.confirmed(p.sessionId, at: p.at) {
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

    static func hooksPresent() -> Bool {
        let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let exe = Bundle.main.executablePath, let text = try? String(contentsOf: settings, encoding: .utf8) else { return false }
        return text.contains(exe)
    }
}

struct PopoverView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No Claude Code sessions yet").font(.headline)
                    Text(model.hooksInstalled
                         ? "A session appears after its next prompt or reply."
                         : "Hooks are missing from ~/.claude/settings.json. Run ./install.sh in the claude-relay folder.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(16)
            } else if model.rows.count <= 4 {
                rowList
            } else {
                // ponytail: fixed height past 4 rows; a measured height would need a GeometryReader dance.
                ScrollView { rowList }.frame(height: 560)
            }
            Divider()
            HStack {
                Label(model.hooksInstalled ? "Hooks installed" : "Hooks missing",
                      systemImage: model.hooksInstalled ? "checkmark.circle" : "exclamationmark.triangle")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 380)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.resort() }
    }

    private var rowList: some View {
        VStack(spacing: 0) {
            ForEach(model.rows, id: \.sessionId) { s in
                RowView(session: s)
                Divider()
            }
        }
    }
}

struct RowView: View {
    @EnvironmentObject var model: Model
    let session: Session

    var body: some View {
        let key = session.rowKey
        let target = session.itermSessionId != nil
        let canType = target && session.status != "needs_you" && !model.busy.contains(key)
        let draft = Binding(get: { model.drafts[key, default: ""] }, set: { model.drafts[key] = $0 })
        let canSend = canType && session.status == "idle" && !Delivery.sanitize(draft.wrappedValue).isEmpty

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
            HStack(alignment: .top, spacing: 6) {
                TextField(placeholder(target), text: draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!canType)
                    .onSubmit { if canSend { model.send(session) } }
                Button("Send") { model.send(session) }.disabled(!canSend)
                Button("Open") { model.open(session) }.disabled(!target)
            }
            if let note = model.notes[key] {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func placeholder(_ target: Bool) -> String {
        !target ? "Not in iTerm2" : session.status == "needs_you" ? "Answer in terminal" : "Next prompt"
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

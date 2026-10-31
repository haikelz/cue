import AppKit
import CueCore
import Observation

/// One row's UI state. Kept by the row's key, so a Claude draft follows its tab or pane across /clear.
struct RowState {
    var draft = ""
    var note: String?
    var sending = false
    var pending: Pending?
}

/// A sent prompt waiting for proof: `last_prompt_at` for Claude, a receipt for Amp.
struct Pending {
    let sessionId: String, at: Double, deadline: Double, text: String
    var inboxId: String?
}

/// What the popover shows and does: the sessions in their sorted order, each row's draft and note,
/// and sending.
@MainActor @Observable
final class AppModel {
    let monitor: SessionMonitor
    private(set) var rowStates: [String: RowState] = [:]
    private(set) var order: [String] = []
    @ObservationIgnored private let worker = Worker("cue.worker")

    var sessions: [Session] { monitor.sessions }

    var waiting: Int { sessions.filter { $0.status != .working && $0.deliverable }.count }

    /// The popover header's count, such as "2 waiting · 1 working".
    var summary: String {
        let working = sessions.filter { $0.status == .working }.count
        return [waiting > 0 ? "\(waiting) waiting" : nil, working > 0 ? "\(working) working" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Sorted once per popover open, so a row never moves under your cursor.
    var rows: [Session] {
        sessions.sorted { (order.firstIndex(of: $0.sessionId) ?? .max) < (order.firstIndex(of: $1.sessionId) ?? .max) }
    }

    init() {
        monitor = SessionMonitor(worker: worker)
        resort()
        // Every second: reread the session files and settle prompts waiting for proof.
        Task { [weak self] in
            while let self, !Task.isCancelled {
                monitor.reload()
                settlePending()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func row(_ key: String) -> RowState { rowStates[key, default: RowState()] }

    func setDraft(_ text: String, for key: String) { rowStates[key, default: RowState()].draft = text }

    /// Runs when the popover opens.
    func resort() {
        order = sessions.sorted {
            if $0.status != $1.status { return $0.status.rank < $1.status.rank }
            return $0.status == .idle ? $0.updatedAt < $1.updatedAt : $0.project < $1.project
        }.map(\.sessionId)
        monitor.refresh()
    }

    /// Whether you can type a prompt in this row right now.
    func canType(_ s: Session) -> Bool {
        s.deliverable && !row(s.rowKey).sending && (s.agent.queuesWhileBusy || s.status != .needsYou)
    }

    func name(_ s: Session) -> String {
        let clash = sessions.filter { $0.project == s.project && $0.agent == s.agent }.count > 1
        return "\(s.agent.name) · \(s.project)" + (clash ? " · \(s.sessionId.prefix(s.agent.idPrefix))" : "")
    }

    func send(_ s: Session) {
        let key = s.rowKey, text = row(key).draft
        rowStates[key, default: RowState()].sending = true
        rowStates[key]?.note = "Sending…"
        Task {
            let outcome = await worker.run { Delivery.send(sessionId: s.sessionId, text: text) }
            finish(s, key: key, text: text, outcome: outcome)
        }
    }

    func open(_ s: Session) {
        let key = s.rowKey
        Task {
            let result = await worker.run { Result { () throws(DeliveryError) in try Delivery.open(s) } }
            switch result {
            case .success(let apps):
                rowStates[key, default: RowState()].note = Self.activate(apps) ? nil : "Couldn't find the terminal app showing this tmux session"
            case .failure(let error):
                rowStates[key, default: RowState()].note = error.message
            }
        }
    }

    /// Brings forward the first of `apps` that is a GUI app. Nothing to do counts as done.
    private static func activate(_ apps: [AppRef]) -> Bool {
        guard !apps.isEmpty else { return true }
        for app in apps {
            let running = switch app {
            case .pid(let pid): NSRunningApplication(processIdentifier: pid)
            case .bundle(let id): NSRunningApplication.runningApplications(withBundleIdentifier: id).first
            }
            if let running, running.activationPolicy == .regular {
                running.activate()  // macOS may decline: the app was found all the same
                return true
            }
        }
        return false
    }

    private func finish(_ s: Session, key: String, text: String, outcome: Outcome) {
        var r = row(key)
        switch outcome {
        case .refused(let why):
            r.sending = false
            r.note = why
        case .failed(let why):
            r.sending = false
            copy(text)
            r.note = "\(why). Prompt copied to clipboard."
        case .sent(let at):
            if Delivery.skipsConfirmation(text) {
                r.sending = false
                r.draft = ""
                r.note = "Sent"
            } else {
                // The 5 s wait starts once typing ends; a long prompt takes seconds to type.
                r.pending = Pending(sessionId: s.sessionId, at: at, deadline: Date().timeIntervalSince1970 + 5, text: text)
            }
        case .accepted(let note):
            r.sending = false
            r.draft = ""
            r.note = note
        case .inbox(let id):
            let now = Date().timeIntervalSince1970
            r.pending = Pending(sessionId: s.sessionId, at: now, deadline: now + 5, text: text, inboxId: id)
        }
        rowStates[key] = r
    }

    private func settlePending() {
        let now = Date().timeIntervalSince1970
        for (key, state) in rowStates {
            guard let p = state.pending else { continue }
            var r = state
            if let id = p.inboxId {
                switch Inbox.settle(thread: p.sessionId, id: id, waited: now - p.at) {
                case .delivered:
                    r.draft = ""
                    r.note = nil
                case .failed(let why):
                    copy(p.text)
                    r.note = "\(why). Prompt copied to clipboard."
                case .withdrawn:
                    copy(p.text)
                    r.note = "Amp didn't pick it up. Prompt copied to clipboard."
                case .unconfirmed:
                    copy(p.text)
                    r.note = "Not confirmed. Prompt copied to clipboard."
                case nil:
                    continue
                }
            } else if Delivery.confirmed(p.sessionId, at: p.at) {
                r.draft = ""
                r.note = nil
            } else if now > p.deadline {
                copy(p.text)
                r.note = "Not confirmed. Prompt copied to clipboard."
            } else {
                continue
            }
            r.pending = nil
            r.sending = false
            rowStates[key] = r
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

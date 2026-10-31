import CueCore
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
        // Cue's mark from the bundle, drawn as a template so it follows the menubar's light or dark look.
        // A build run from .build/ has no bundle resources and shows the SF Symbol instead.
        let mark = Bundle.main.url(forResource: "menubar", withExtension: "tiff").flatMap(NSImage.init(contentsOf:))
        mark?.isTemplate = true
        mark?.size = NSSize(width: 18, height: 18)
        mark?.accessibilityDescription = "Cue"
        item.button?.image = mark ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "Cue")
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
    @Published private(set) var codexWarning: String?
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
        reload()
        resort()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        var live: [Session] = []
        for var s in Store.all() {
            if s.isExpired {
                // Claude exited without SessionEnd (tab closed, crash), or a session went quiet for good.
                // Re-check under the lock, so a resumed session that just rewrote this file keeps it.
                _ = try? Store.locked { if let fresh = Store.read(s.sessionId), fresh.isExpired { Store.delete(s.sessionId) } }
                continue
            }
            if !s.isAlive { continue }  // hidden, not deleted: an Amp window that stopped beating may resume
            if s.agent == .claude, s.status != .idle, s.interrupted { s = setIdle(s) { $0.status != .idle && $0.interrupted } }
            live.append(s)
        }
        if live != sessions { sessions = live }
        settlePending()
    }

    /// Runs when the popover opens.
    func resort() {
        order = sessions.sorted {
            if $0.status != $1.status { return $0.status.rank < $1.status.rank }
            return $0.status == .idle ? $0.updatedAt < $1.updatedAt : $0.project < $1.project
        }.map(\.sessionId)
        hooksInstalled = Self.hooksPresent()
        checkCodexHooks()
        recheckStale()
    }

    private var codexStamp: [Double]?
    private var checkingCodex = false

    /// Asks Codex whether it trusts Cue's hooks, when hooks.json or config.toml changed since the last
    /// answer. Takes a second or two, so it runs off the main thread and off the delivery queue.
    private func checkCodexHooks() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let stamp = [".codex/hooks.json", ".codex/config.toml"].map {
            ((try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent($0).path))?[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
        }
        guard stamp != codexStamp, !checkingCodex, let exe = Bundle.main.executablePath else { return }
        checkingCodex = true
        DispatchQueue.global(qos: .utility).async {
            let hooks = Codex.listHooks()
            DispatchQueue.main.async {
                self.checkingCodex = false
                guard let hooks else { return }  // no answer: stay quiet, ask again next time
                self.codexStamp = stamp
                self.codexWarning = Codex.warning(hooks, command: Codex.command(exe: exe))
            }
        }
    }

    /// Whether you can type a prompt in this row right now.
    func canType(_ s: Session) -> Bool {
        s.deliverable && !busy.contains(s.rowKey) && (s.agent.queuesWhileBusy || s.status != .needsYou)
    }

    /// A row quiet at working for 15 s gets one look at its screen.
    private func recheckStale() {
        let now = Date().timeIntervalSince1970
        for s in sessions where s.agent == .claude && s.deliverable && s.status == .working && !probing.contains(s.sessionId)
            && now - max(s.updatedAt, s.transcriptModified ?? 0) > 15 {
            probing.insert(s.sessionId)
            worker.async {
                let idle = Delivery.looksIdle(s)
                DispatchQueue.main.async {
                    self.probing.remove(s.sessionId)
                    guard idle else { return }
                    _ = self.setIdle(s) { $0.status == .working && $0.updatedAt == s.updatedAt }
                    self.reload()
                }
            }
        }
    }

    func name(_ s: Session) -> String {
        let clash = sessions.filter { $0.project == s.project && $0.agent == s.agent }.count > 1
        return "\(s.agent.name) · \(s.project)" + (clash ? " · \(s.sessionId.prefix(s.agent.idPrefix))" : "")
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
        let key = s.rowKey
        worker.async {
            let error = Delivery.open(s)
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
            fresh.status = .idle
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
    @FocusState private var focused: String?
    @State private var expanded: String?  // one reply open at a time keeps the popover short

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No agent sessions", systemImage: "terminal")
                } description: {
                    Text(model.hooksInstalled
                         ? "A Claude Code, Codex or Amp session appears after its next prompt or reply."
                         : "No agent is wired to Cue yet. Run ./install.sh in the cue folder.")
                }
                .padding(.vertical, 12)
            } else if model.rows.count <= 3 {
                rowList
            } else {
                // ponytail: fixed height past 3 rows; a measured height would need a GeometryReader dance.
                ScrollView { rowList }.frame(height: 600)
            }
            if let warning = model.codexWarning {
                Label {
                    Text(warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .bottom], 8)
            }
            Divider()
            footer
        }
        .frame(width: 380)
        // Each open puts the cursor in the first row you can type in: after sorting, the longest wait.
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didShowNotification)) { _ in
            focused = model.rows.first(where: model.canType)?.sessionId
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
            Text("Cue").font(.headline)
            Spacer()
            Text(model.summary).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var rowList: some View {
        VStack(spacing: 6) {
            ForEach(model.rows, id: \.sessionId) { s in
                RowView(session: s, focus: $focused,
                        expanded: Binding(get: { expanded == s.sessionId }, set: { expanded = $0 ? s.sessionId : nil }))
            }
        }
        .padding(8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Label(model.hooksInstalled ? "Hooks installed" : "Hooks missing",
                  systemImage: model.hooksInstalled ? "checkmark.circle" : "exclamationmark.triangle")
            Spacer()
            Text("⌃⌥Space opens Cue")
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One session as a rounded tile, like a Control Center module: agent, status, reply, prompt box.
struct RowView: View {
    @EnvironmentObject var model: Model
    let session: Session
    var focus: FocusState<String?>.Binding
    @Binding var expanded: Bool
    @State private var hovering = false

    var body: some View {
        let key = session.rowKey
        let target = session.deliverable
        let queues = session.agent.queuesWhileBusy
        let canType = model.canType(session)
        let editing = focus.wrappedValue == session.sessionId
        let draft = Binding(get: { model.drafts[key, default: ""] }, set: { model.drafts[key] = $0 })
        let canSend = canType && (queues || session.status == .idle) && !Delivery.sanitize(draft.wrappedValue).isEmpty

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentIcon(agent: session.agent)
                Text(model.name(session)).font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                StatusBadge(status: target ? session.status : nil, since: session.updatedAt)
            }
            if let message = session.lastMessage, !message.isEmpty {
                ReplyView(message: message, expanded: $expanded)
            }
            if !target || !queues && session.status == .needsYou {
                // Nothing to type here yet: a line saying why, and the way to the terminal.
                HStack(spacing: 8) {
                    Text(placeholder(target)).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if canOpen { Button("Open") { model.open(session) }.controlSize(.small) }
                }
            } else {
                PromptEditor(text: draft, placeholder: placeholder(target), enabled: canType, focused: editing)
                    .focused(focus, equals: session.sessionId)
                HStack(spacing: 8) {
                    if editing && canType { Text("⌘↩ to send").font(.caption).foregroundStyle(.tertiary) }
                    Spacer()
                    if canOpen {
                        Button { model.open(session) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Open in the terminal")
                    }
                    // Only the row being typed in owns ⌘Return, so rows never compete for the shortcut.
                    Button("Send") { model.send(session) }
                        .buttonStyle(.borderedProminent)
                        .tint(canSend ? nil : .gray)  // a disabled prominent button stays a muddy blue otherwise
                        .disabled(!canSend)
                        .keyboardShortcut(editing ? KeyboardShortcut(.return, modifiers: .command) : nil)
                }
                .controlSize(.small)
            }
            if let note = model.notes[key] { NoteView(note: note) }
        }
        .padding(10)
        .background(Color.primary.opacity(editing || hovering ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var canOpen: Bool { session.agent.canOpen && (session.itermSessionId != nil || session.tmuxPane != nil) }

    private func placeholder(_ target: Bool) -> String {
        if !target { return "Start Claude in iTerm2 or tmux to send from here" }
        if !session.agent.queuesWhileBusy { return session.status == .needsYou ? "Answer in the terminal" : "Next prompt" }
        return session.status == .idle ? "Next prompt" : "Queue a prompt"
    }
}

/// The agent as an SF Symbol in a tinted circle; the row title names it, so VoiceOver skips this.
struct AgentIcon: View {
    let agent: Agent

    var body: some View {
        let (symbol, color): (String, Color) = switch agent {
        case .claude: ("sparkle", .orange)
        case .codex: ("curlybraces", .teal)
        case .amp: ("bolt.fill", .purple)
        }
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(color.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

/// A row's note, marked by kind: a spinner while sending, a check once the agent took the prompt,
/// a warning for everything else, since every other note asks you to look at something.
struct NoteView: View {
    let note: String

    var body: some View {
        Label {
            Text(note).foregroundStyle(.secondary)
        } icon: {
            switch note {
            case "Sending…": ProgressView().controlSize(.mini)
            case "Sent", "Queued": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            default: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }
}

/// The agent's last reply: two lines that expand on click, or the whole reply with its line breaks,
/// inline Markdown and selectable text. Clicks on expanded text select; "Show less" collapses.
struct ReplyView: View {
    let message: String
    @Binding var expanded: Bool

    var body: some View {
        if expanded {
            VStack(alignment: .leading, spacing: 4) {
                // ponytail: length decides when to scroll; measuring the text would need a GeometryReader.
                if message.count > 600 {
                    ScrollView { full }.frame(height: 240)
                } else {
                    full
                }
                Button("Show less") { expanded = false }.buttonStyle(.link).font(.caption)
            }
        } else {
            Text(Self.markdown(message.split(whereSeparator: \.isNewline).joined(separator: " ")))
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                .contentShape(Rectangle())
                .onTapGesture { expanded = true }
                .help("Click to read the full reply")
        }
    }

    /// Inline Markdown (bold, code, links) as styled text; plain text when it doesn't parse.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private var full: some View {
        Text(Self.markdown(message))
            .font(.callout).foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A four-line text area for the next prompt; longer prompts scroll inside it. Drawn like a macOS
/// text field, with the accent focus ring while you type. Return adds a line break; ⌘Return sends.
struct PromptEditor: View {
    @Binding var text: String
    let placeholder: String
    let enabled: Bool
    let focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .frame(height: 76)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor.opacity(focused ? 0.6 : 0), lineWidth: 3).padding(-1.5))
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

/// Status as macOS shows presence: a colored dot and text, or a small spinner while the agent works.
struct StatusBadge: View {
    let status: Status?  // nil: a Claude session Cue can't type into
    let since: Double

    var body: some View {
        let (label, color): (String, Color) = switch status {
        case .idle: ("Idle", .green)
        case .needsYou: ("Needs you", .orange)
        case .working: ("Working", .blue)
        case nil: ("Read only", .gray)
        }
        HStack(spacing: 5) {
            if status == .working {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in Text("\(label) · \(ago)") }
                .foregroundStyle(status == .needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .font(.caption)
    }

    private var ago: String {
        let s = max(0, Int(Date().timeIntervalSince1970 - since))
        return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h"
    }
}

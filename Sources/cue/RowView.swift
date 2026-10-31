import AppKit
import CueCore
import SwiftUI

/// One session as a rounded tile, like a Control Center module: agent, status, reply, prompt box.
struct RowView: View {
    @Environment(AppModel.self) private var model
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
        let draft = Binding(get: { model.row(key).draft }, set: { model.setDraft($0, for: key) })
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
            if let note = model.row(key).note { NoteView(note: note) }
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

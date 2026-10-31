import Foundation

package enum Outcome: Sendable {
    case sent(at: Double)  // the turn should start; `last_prompt_at` confirms it
    case accepted(String)  // the agent took the prompt itself; the note says "Sent" or "Queued"
    case inbox(String)     // Amp: dropped in the inbox under this id; a receipt confirms it
    case refused(String)   // a check failed before anything was sent
    case failed(String)    // sending may have started; treat the prompt as at risk
}

/// Why a delivery step stopped. The terminal names the tab or pane in each message.
package enum DeliveryError: Error, Equatable {
    case closed(String)   // the tab, the pane or the tmux server is gone
    case moved(String)    // the tab or pane runs something else now
    case refused(String)  // a check said no before any key went out
    case failed(String)   // a tool failed; keys may have gone out

    package var message: String {
        switch self {
        case .closed(let m), .moved(let m), .refused(let m), .failed(let m): m
        }
    }
}

package enum Delivery {
    /// Sends `raw` to a session through its agent's channel.
    package static func send(sessionId: String, text raw: String) -> Outcome {
        let text = sanitize(raw)
        guard !text.isEmpty else { return .refused("Prompt is empty") }
        guard let s = Store.read(sessionId) else { return .refused("Session is gone") }
        switch s.agent {
        case .claude: return typeIntoClaude(s, text)
        case .codex: return Codex.queue(s, text)
        case .amp: return Inbox.drop(s, text)
        }
    }

    /// Types the prompt into the session's iTerm2 tab or tmux pane, then presses Return, each step behind the full set of checks.
    package static func typeIntoClaude(_ s: Session, _ text: String) -> Outcome {
        guard let terminal = s.terminal, let tty = s.tty else { return .refused("Not in iTerm2 or tmux") }
        let lines: [String]
        do { lines = try check(s) } catch { return .refused(error.message) }

        // A draft or a grayed-out suggestion sits in the box: Ctrl+U clears it, once per box line.
        // A real draft stays recoverable with Ctrl+Y in that tab.
        let clears = lines.first.map { $0 == "❯" || $0.hasPrefix("❯ Try \"") } == true ? 0 : lines.count
        let at = Date().timeIntervalSince1970
        do {
            try terminal.send(Array(repeating: Key.clearLine, count: clears) + keys(text), tty: tty)
        } catch {
            switch error {
            case .moved, .refused: return .refused(error.message)  // nothing went out
            case .closed, .failed: return .failed(error.message)
            }
        }

        // Typing a long prompt takes seconds. Before Return, check everything again, and check the box
        // ends with this prompt (a long draft scrolls inside the box, so its start may be out of view).
        do {
            guard box(try check(s), endsWith: text) else {
                return .failed("Typed but not sent: the input box doesn't end with this prompt")
            }
        } catch {
            return .failed("Typed but not sent: \(error.message). The text is in Claude's input box")
        }
        do {
            try terminal.send([Key.submit], tty: tty)
        } catch {
            return .failed("Typed but not sent: \(error.message)")
        }
        return .sent(at: at)
    }

    /// Every check that guards typing, process facts first, then what the terminal shows. Returns the
    /// input box's lines.
    package static func check(_ s: Session) throws(DeliveryError) -> [String] {
        if let why = gate(Store.read(s.sessionId) ?? s) { throw .refused(why) }
        guard let terminal = s.terminal, let tty = s.tty else { throw .refused("Not in iTerm2 or tmux") }
        let text = try terminal.screen(tty: tty, timeout: 60)
        if let why = screenProblem(text) { throw .refused(why) }
        return box(text)?.lines ?? []
    }

    /// Process checks, cheapest first. Returns why typing must not happen, or nil.
    package static func gate(_ s: Session) -> String? {
        guard s.status == .idle else { return s.status == .working ? "Claude is working" : "Claude needs you in the terminal" }
        guard let pid = s.pid, let p = Proc(pid), let start = s.pidStart, abs(p.start - start) < 0.01 else {
            return "Claude process is gone"
        }
        guard !p.stopped, p.tpgid == p.pgid else { return "Claude isn't in the foreground (suspended?)" }
        guard p.tty == s.tty else { return "Claude's terminal changed" }
        return nil
    }

    /// Why the screen is unsafe to type into, or nil. The box check catches what process checks
    /// can't: a permission dialog, a picker, the Ctrl+G editor. Only lines next to the box count,
    /// so Claude's own output can't trip the spinner or vim checks.
    package static func screenProblem(_ screen: String) -> String? {
        guard let b = box(screen) else { return "Claude's input box isn't on screen (dialog, editor or menu open)" }
        if b.above.contains(where: isSpinner) { return "Claude is working" }
        if (b.lines + b.below).contains(where: { $0.contains("-- NORMAL --") }) {
            return "Claude's vim mode is in NORMAL; press i in the terminal"
        }
        return nil
    }

    package struct Box { let lines: [String], above: [String], below: [String] }

    /// Claude Code's input box: a rule line, a line starting with "❯" (or "!" in bash mode),
    /// more input lines, a rule line. The last such box on screen, with its neighbours.
    /// The prompt marker sits in column 0; dialog options (" ❯ 1. Yes") are indented.
    package static func box(_ screen: String) -> Box? {
        let raw = screen.split(separator: "\n").map(String.init).filter { !$0.allSatisfy(\.isWhitespace) }
        let tail = Array(raw.suffix(30))
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
        let isRule: (String) -> Bool = { let t = trim($0); return t.count >= 20 && t.allSatisfy { $0 == "─" } }
        for i in tail.indices.reversed() where i > 0 && (tail[i].hasPrefix("❯") || tail[i].hasPrefix("!")) && isRule(tail[i - 1]) {
            guard let end = tail[(i + 1)...].prefix(25).firstIndex(where: isRule) else { continue }
            return Box(lines: tail[i..<end].map(trim), above: tail[max(0, i - 7)..<(i - 1)].map(trim), below: tail[(end + 1)...].map(trim))
        }
        return nil
    }

    /// True when the box's last line is the end of the prompt's last line (wrapping keeps that a suffix).
    package static func box(_ lines: [String], endsWith text: String) -> Bool {
        let tail = String(text.split(separator: "\n", omittingEmptySubsequences: false).last ?? "").trimmingCharacters(in: .whitespaces)
        var last = lines.last ?? ""
        if lines.count == 1 { last = String(last.dropFirst()) }  // the "❯" or "!" marker
        last = last.trimmingCharacters(in: .whitespaces)
        return !last.isEmpty && tail.hasSuffix(last)
    }

    /// The working spinner line: "✻ Propagating… (4s · ↓ 263 tokens)". A finished turn reads "✻ Cooked for 2s".
    package static func isSpinner(_ line: String) -> Bool {
        line.range(of: #"^\S\s+[^\s…]+…\s*\("#, options: .regularExpression) != nil
    }

    /// For a row stuck at working: true when the tab shows an idle input box. Catches Esc pressed
    /// before Claude wrote anything, which leaves no hook event and no transcript marker.
    package static func looksIdle(_ s: Session) -> Bool {
        guard let terminal = s.terminal, let tty = s.tty, let text = try? terminal.screen(tty: tty, timeout: 10) else { return false }
        return screenProblem(text) == nil
    }

    /// Drops what a terminal would read as keys or what hides text: C0/C1 controls (line breaks stay),
    /// invisible, bidi, tag and variation-selector characters. Tabs become spaces, since Tab completes.
    package static func sanitize(_ s: String) -> String {
        let kept = s.unicodeScalars.compactMap { u -> Unicode.Scalar? in
            switch u.value {
            case 0x0A: return u
            case 0x09: return " "
            case 0x00...0x1F, 0x7F...0x9F, 0x061C, 0x115F, 0x1160, 0x180E, 0x200B...0x200F, 0x2028...0x202E,
                 0x2060...0x2069, 0x3164, 0xFEFF, 0xFFA0, 0xE0000...0xE007F, 0xE0100...0xE01EF:
                return nil
            default: return u
            }
        }
        var out = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasSuffix("\\") { out += " " }  // "\" then Return inserts a line break instead of submitting
        return out
    }

    /// The prompt as key chunks: each line cut into 200-character pieces, with Option+Return between
    /// lines. Claude Code reads input that arrives in one burst as a paste and treats it as data, not
    /// as your instruction; terminals send the chunks 150 ms apart to stay under that detector.
    package static func keys(_ text: String) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if n > 0 { out.append(Key.lineBreak) }
            var rest = Substring(line)
            while !rest.isEmpty {
                out.append(Array(rest.prefix(200).utf8))
                rest = rest.dropFirst(200)
            }
        }
        return out
    }

    /// Selects the session's tab or pane; see `Terminal.open`.
    package static func open(_ s: Session) throws(DeliveryError) -> [AppRef] {
        guard let terminal = s.terminal else { throw .refused("Not in iTerm2 or tmux") }
        return try terminal.open()
    }
}

extension Delivery {
    /// Slash and shell commands may skip UserPromptSubmit, so there is nothing to wait for.
    package static func skipsConfirmation(_ text: String) -> Bool {
        let t = sanitize(text)
        return t.hasPrefix("/") || t.hasPrefix("!")
    }

    /// UserPromptSubmit stamped a prompt at or after the send started.
    package static func confirmed(_ id: String, at: Double) -> Bool {
        (Store.read(id)?.lastPromptAt ?? 0) >= at
    }
}

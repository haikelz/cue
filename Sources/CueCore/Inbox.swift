import Foundation

/// Amp delivery. Cue drops one file per prompt in ~/.cue/inbox/<thread id>/; the Cue plugin inside Amp
/// claims it with a rename, appends it to the thread, and leaves a receipt. At most once: only one
/// rename can win, so two Amp windows on one thread can't both send it, and Cue withdraws a file that
/// nobody claimed in time instead of letting it arrive late.
package enum Inbox {
    package static let root = Store.root.appendingPathComponent("inbox")

    package static func validThread(_ id: String) -> Bool {
        id.range(of: #"^T-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }

    package static func drop(_ s: Session, _ text: String) -> Outcome {
        guard validThread(s.sessionId) else { return .refused("Not an Amp thread id") }
        guard text.utf8.count <= 60_000 else { return .refused("Prompt is too long for Amp (60 KB at most)") }
        guard let beat = s.heartbeat, Date().timeIntervalSince1970 - beat < 15 else {
            return .refused("Amp isn't answering; is the thread still open?")
        }
        let dir = root.appendingPathComponent(s.sessionId)
        let id = UUID().uuidString.lowercased()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let tmp = dir.appendingPathComponent(".\(id).tmp")
            guard FileManager.default.createFile(atPath: tmp.path, contents: try JSONSerialization.data(withJSONObject: ["content": text]),
                                                 attributes: [.posixPermissions: 0o600]),
                  rename(tmp.path, dir.appendingPathComponent("\(id).json").path) == 0
            else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            return .refused("Couldn't write to Cue's inbox: \(error.localizedDescription)")
        }
        return .inbox(id)
    }

    package enum State: Equatable { case unclaimed, claimed, delivered, failed(String) }

    package static func state(thread: String, id: String) -> State {
        let dir = root.appendingPathComponent(thread)
        let receipt = dir.appendingPathComponent("receipts/\(id)")
        if FileManager.default.fileExists(atPath: receipt.path) {
            try? FileManager.default.removeItem(at: receipt)
            return .delivered
        }
        let error = dir.appendingPathComponent("receipts/\(id).error")
        if let why = try? String(contentsOf: error, encoding: .utf8) {
            try? FileManager.default.removeItem(at: error)
            return .failed("Amp refused the prompt: \(why)")
        }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).json").path) ? .unclaimed : .claimed
    }

    package enum Settlement: Equatable { case delivered, failed(String), withdrawn, unconfirmed }

    /// Where a dropped prompt stands after `waited` seconds, or nil to keep waiting. Shared by the app and `cue send`.
    package static func settle(thread: String, id: String, waited: Double) -> Settlement? {
        switch state(thread: thread, id: id) {
        case .delivered: return .delivered
        case .failed(let why): return .failed(why)
        case .unclaimed where waited > 5 && withdraw(thread: thread, id: id): return .withdrawn
        case .claimed where waited > 60: return .unconfirmed
        default: return nil
        }
    }

    /// Takes back a file nobody claimed. False when the plugin claimed it first.
    package static func withdraw(thread: String, id: String) -> Bool {
        let dir = root.appendingPathComponent(thread)
        let held = dir.appendingPathComponent(".\(id).withdrawn")
        guard rename(dir.appendingPathComponent("\(id).json").path, held.path) == 0 else { return false }
        try? FileManager.default.removeItem(at: held)
        return true
    }
}

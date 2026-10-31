import CueCore
import Foundation

/// `cue send <session-id> <text>`: the app's delivery path, for tests and scripts.
/// Exit 0 = sent and confirmed, 1 = refused or failed, 2 = sent but not confirmed in 5 s.
enum SendCommand {
    /// Exit 0 = delivered (or queued behind a running turn), 1 = refused or failed, 2 = sent but not confirmed.
    static func run(_ args: [String]) -> Int32 {
        guard args.count == 2 else {
            FileHandle.standardError.write(Data("usage: cue send <session-id> <text>\n".utf8))
            return 1
        }
        let (id, text) = (args[0], args[1])
        switch Delivery.send(sessionId: id, text: text) {
        case .refused(let why), .failed(let why):
            FileHandle.standardError.write(Data("\(why)\n".utf8))
            return 1
        case .accepted(let note):
            print(note.lowercased())
            return 0
        case .sent(let at):
            if Delivery.skipsConfirmation(text) { print("sent"); return 0 }
            for _ in 0..<50 {
                if Delivery.confirmed(id, at: at) { print("confirmed"); return 0 }
                usleep(100_000)
            }
            print("not confirmed")
            return 2
        case .inbox(let msg):
            let start = Date().timeIntervalSince1970
            while true {
                switch Inbox.settle(thread: id, id: msg, waited: Date().timeIntervalSince1970 - start) {
                case .delivered:
                    print("delivered")
                    return 0
                case .failed(let why):
                    FileHandle.standardError.write(Data("\(why)\n".utf8))
                    return 1
                case .withdrawn:
                    FileHandle.standardError.write(Data("Amp didn't pick it up\n".utf8))
                    return 1
                case .unconfirmed:
                    print("not confirmed")
                    return 2
                case nil:
                    usleep(100_000)
                }
            }
        }
    }
}

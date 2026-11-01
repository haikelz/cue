import CueCore
import Foundation
import UserNotifications

/// Posts Cue's notifications: a turn that ended, or a session that started waiting on you. One per
/// session, each replacing the one before; clicking one opens Cue on that session. macOS shows no
/// banner while Cue itself is in front, so an open popover stays quiet.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the session id of a notification you clicked.
    var onOpen: ((String) -> Void)?
    private var last: [String: Session] = [:]
    private var allowed = false

    /// A build run from .build/ has no bundle, and UNUserNotificationCenter crashes without one.
    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Asks for permission the first time; later, only reads what you chose.
    func start() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refresh()
        }
    }

    /// Follows the choice in System Settings > Notifications, so the hooks' terminal banner comes back
    /// when you turn Cue's notifications off. Runs at launch and each time the popover opens.
    func refresh() async {
        guard available else { return }
        let status = await Self.authorization()
        allowed = status == .authorized || status == .provisional
        if allowed { NotifierFile.claim() } else { NotifierFile.release() }
    }

    /// Nonisolated on purpose: macOS calls the completion handler on a background queue, and a closure
    /// formed on the main actor would trap there under Swift 6's isolation checks.
    private nonisolated static func authorization() async -> UNAuthorizationStatus {
        await withCheckedContinuation { done in
            UNUserNotificationCenter.current().getNotificationSettings { done.resume(returning: $0.authorizationStatus) }
        }
    }

    func stop() { NotifierFile.release() }

    /// Compares each session with how the last poll saw it. A session seen for the first time only sets
    /// the baseline, so starting Cue doesn't replay old turns.
    func update(_ sessions: [Session], name: (Session) -> String) {
        for s in sessions {
            if allowed, let before = last[s.sessionId], let alert = s.alert(since: before) { post(alert, for: s, name: name(s)) }
            last[s.sessionId] = s
        }
        let ids = Set(sessions.map(\.sessionId))
        last = last.filter { ids.contains($0.key) }
    }

    private func post(_ alert: Alert, for s: Session, name: String) {
        let content = UNMutableNotificationContent()
        content.title = alert.title(name)
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = s.sessionId
        content.userInfo = ["session": s.sessionId]
        // The session id as the identifier: a newer notification for a session replaces the older one.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.sessionId, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["session"] as? String else { return }
        await MainActor.run { onOpen?(id) }
    }
}

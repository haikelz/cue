import AppKit
import CueCore
import UserNotifications

/// Posts Cue's notifications: a turn that ended, or a session that started waiting on you. One per
/// session, each replacing the one before; clicking one opens Cue on that session. They show while
/// Cue is the active app too (it stays active after the popover closes), except while the popover is open.
/// The same changes play Amp's sounds for Claude and Codex, notifications allowed or not; the banners stay silent.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the session id of a notification you clicked.
    var onOpen: ((String) -> Void)?
    /// True while the popover is open, where a banner would only repeat what you see.
    var popoverShown: () -> Bool = { false }
    private var tracker = AlertTracker()
    private var allowed = false

    /// The gear menu's Play Sounds, on unless you turned it off.
    nonisolated static let soundsKey = "playSounds"
    private var playsSounds: Bool { UserDefaults.standard.object(forKey: Self.soundsKey) as? Bool ?? true }

    /// A build run from .build/ has no bundle, and UNUserNotificationCenter crashes without one.
    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Asks for permission the first time; later, only reads what you chose.
    func start() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            await refresh()
        }
    }

    /// Follows the choice in System Settings > Notifications, so the hooks' terminal banner comes back
    /// when you turn Cue's notifications off or set its alert style to None. Runs at launch, each time
    /// the popover opens, and every 10 s.
    func refresh() async {
        guard available else { return }
        let (status, style) = await Self.settings()
        allowed = (status == .authorized || status == .provisional) && style != .none
        if allowed { NotifierFile.claim() } else { NotifierFile.release() }
    }

    /// Nonisolated on purpose: macOS calls the completion handler on a background queue, and a closure
    /// formed on the main actor would trap there under Swift 6's isolation checks.
    private nonisolated static func settings() async -> (UNAuthorizationStatus, UNAlertStyle) {
        await withCheckedContinuation { done in
            UNUserNotificationCenter.current().getNotificationSettings { done.resume(returning: ($0.authorizationStatus, $0.alertStyle)) }
        }
    }

    func stop() { NotifierFile.release() }

    /// Sounds and posts what changed since the last poll. The tracker runs even while notifications are
    /// off, so turning them on doesn't replay what happened meanwhile.
    func update(_ sessions: [Session], name: (Session) -> String) {
        let changes = tracker.changes(in: sessions)
        if playsSounds, let sound = Alert.sound(for: changes) { NSSound(named: sound)?.play() }
        for (s, alert) in changes where allowed { post(alert, for: s, name: name(s)) }
    }

    private func post(_ alert: Alert, for s: Session, name: String) {
        let content = UNMutableNotificationContent()
        content.title = alert.title(name)
        content.body = alert.body
        content.threadIdentifier = s.sessionId
        content.userInfo = ["session": s.sessionId]
        // The session id as the identifier: a newer notification for a session replaces the older one.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.sessionId, content: content, trigger: nil))
    }

    /// Without this, macOS drops every banner while Cue is the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { popoverShown() } ? [] : [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["session"] as? String else { return }
        await MainActor.run { onOpen?(id) }
    }
}

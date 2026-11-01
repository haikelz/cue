import Foundation
import ServiceManagement

/// Starts Cue at login through SMAppService: on by default, and the gear menu turns it off. A
/// reinstall changes Cue's ad-hoc signature, so Cue registers itself again at each launch while on.
@MainActor
enum LoginItem {
    private static let key = "openAtLogin"

    static var wanted: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            apply()
        }
    }

    /// macOS wants you to allow Cue in System Settings > General > Login Items first.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Registers or unregisters Cue to match `wanted`. A build run from .build/ is no app to register.
    static func apply() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = SMAppService.mainApp
        if wanted, service.status != .enabled { try? service.register() }
        if !wanted, service.status != .notRegistered { try? service.unregister() }
    }
}

import Foundation
import ServiceManagement

/// Starts Cue at login through SMAppService. Cue registers itself on its first launch; after that the
/// gear menu, or System Settings > General > Login Items, decides. A reinstall can drop the
/// registration, so Cue registers again at launch only when macOS has none and you never turned it off.
@MainActor
enum LoginItem {
    private static let key = "openAtLogin"

    /// A build run from .build/ is no app to register.
    private static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Whether you want Cue at login, as you last set it in the gear menu.
    static var wanted: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// What the gear menu shows: whether macOS will open Cue at login.
    static var isOn: Bool { available && SMAppService.mainApp.status == .enabled }

    /// macOS wants you to allow Cue in System Settings > General > Login Items first.
    static var needsApproval: Bool { available && SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        if on { register() } else { unregister() }
    }

    /// At launch: registers on the first launch, or after a reinstall dropped the registration.
    static func setUp() {
        guard wanted, available, SMAppService.mainApp.status == .notRegistered else { return }
        register()
    }

    static func register() {
        guard available else { return }
        try? SMAppService.mainApp.register()
    }

    /// Also for uninstall.sh, through `cue login-item off`.
    static func unregister() {
        guard available, SMAppService.mainApp.status != .notRegistered else { return }
        try? SMAppService.mainApp.unregister()
    }
}

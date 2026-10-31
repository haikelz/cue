import Carbon.HIToolbox

/// A system-wide shortcut through Carbon's RegisterEventHotKey, which needs no Accessibility
/// permission. macOS lets two apps register one combination, so nil means only that Carbon refused.
/// Unchecked Sendable: it's created on the main thread, and Carbon calls back on the main thread only.
final class HotKey: @unchecked Sendable {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // A C callback can't capture, so `self` travels as userData.
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }  // Carbon delivers hotkey events on the main thread
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4355_4521), id: 1)  // "CUE!"
        // On failure deinit still runs, since every property is set, and removes the handler.
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

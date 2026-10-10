import Carbon.HIToolbox

/// A system-wide keyboard shortcut via Carbon's RegisterEventHotKey. Unlike a global
/// NSEvent monitor it needs no Accessibility permission, and it fires even when a
/// full-screen app is frontmost.
@MainActor
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?

    /// nil if the shortcut couldn't be registered, usually because another app holds it.
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.installHandler()
        let id = Self.nextID
        Self.nextID += 1
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4E444745) /* NDGE */, id: id),
            GetEventDispatcherTarget(), 0, &ref
        )
        guard status == noErr else {
            NSLog("nudge: couldn't register hotkey (\(status))")
            return nil
        }
        Self.actions[id] = action
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { HotKey.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

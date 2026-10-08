import AppKit
import Carbon

// Carbon's global hotkey provides a second recovery route independently of
// the Accessibility event tap: Control + Option + Command + Up Arrow.
final class EmergencyRestore {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var handle: (() -> Void)?
    var ready: Bool { hotKey != nil && eventHandler != nil }

    func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetEventDispatcherTarget(), { _, _, context -> OSStatus in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let handler = Unmanaged<EmergencyRestore>.fromOpaque(context).takeUnretainedValue()
            handler.handle?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard installed == noErr else { return }
        let id = EventHotKeyID(signature: OSType(0x45425254), id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_UpArrow), UInt32(cmdKey | optionKey | controlKey), id,
            GetEventDispatcherTarget(), 0, &hotKey)
        if registered != noErr { stop() }
    }
    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil; eventHandler = nil
    }
    deinit { stop() }
}

import AppKit

struct BrightnessKey {
    let direction: Double
    let pressed: Bool
    let fine: Bool
}

enum BrightnessKeys {
    static func decode(_ event: NSEvent, useFunctionKeys: Bool) -> BrightnessKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .systemDefined {
            guard event.subtype.rawValue == 8 else { return nil }
            guard !flags.contains(.command), !flags.contains(.control) else { return nil }
            if flags.contains(.option) && !flags.contains(.shift) { return nil }
            let code = (event.data1 >> 16) & 0xffff
            guard code == 2 || code == 3 else { return nil }
            let state = (event.data1 >> 8) & 0xff
            guard state == 0x0a || state == 0x0b else { return nil }
            return BrightnessKey(direction: code == 2 ? 1 : -1, pressed: state == 0x0a, fine: flags.contains(.option) && flags.contains(.shift))
        }
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        if flags.contains(.control), flags.contains(.option), !flags.contains(.command),
           event.keyCode == 125 || event.keyCode == 126 {
            return BrightnessKey(direction: event.keyCode == 126 ? 1 : -1, pressed: event.type == .keyDown, fine: flags.contains(.shift))
        }
        guard useFunctionKeys, !flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
              event.keyCode == 122 || event.keyCode == 120 else { return nil }
        return BrightnessKey(direction: event.keyCode == 120 ? 1 : -1, pressed: event.type == .keyDown, fine: flags.contains(.shift))
    }
}

final class KeyboardListener {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var handle: ((NSEvent) -> Bool)?
    var running: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return running }
        let mask = (CGEventMask(1) << 14) | (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<KeyboardListener>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = listener.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                if let nsEvent = NSEvent(cgEvent: event), listener.handle?(nsEvent) == true { return nil }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else { CFMachPortInvalidate(created); return false }
        tap = created; source = runSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        return running
    }
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil
    }
    deinit { stop() }
}

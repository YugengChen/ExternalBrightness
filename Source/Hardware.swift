import AppKit
import IOKit
import Darwin

struct ScreenDescriptor {
    let id: CGDirectDisplayID
    let name: String
    static func externalScreens() -> [ScreenDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            guard CGDisplayIsBuiltin(id) == 0 else { return nil }
            return ScreenDescriptor(id: id, name: screen.localizedName)
        }
    }
}

struct DisplayState {
    let id: CGDirectDisplayID
    let name: String
    let backend: String
    var brightness: Double?
    var error: String?
    var supported: Bool { brightness != nil && backend != "unsupported" }
    var json: [String: Any] {
        var result: [String: Any] = ["id": id, "name": name, "backend": backend, "supported": supported, "brightnessVerified": supported && error == nil]
        if let brightness { result["brightnessPercent"] = (brightness * 10000).rounded() / 100 }
        if let error { result["error"] = error }
        return result
    }
}

private final class SystemDisplayAPI {
    typealias CreateAV = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    typealias DisplayInfo = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
    typealias CanChange = @convention(c) (UInt32) -> Bool
    typealias GetNative = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetNative = @convention(c) (UInt32, Float) -> Int32
    // Keep handles alive for the lifetime of the function pointers.
    private var handles: [UnsafeMutableRawPointer] = []
    var createAV: CreateAV?
    var readI2C: Transfer?
    var writeI2C: Transfer?
    var info: DisplayInfo?
    var canChange: CanChange?
    var getNative: GetNative?
    var setNative: SetNative?

    private func load<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
    init() {
        let io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        let core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
        let native = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        handles = [io, core, native].compactMap { $0 }
        createAV = load(io, "IOAVServiceCreateWithService", CreateAV.self)
        readI2C = load(io, "IOAVServiceReadI2C", Transfer.self)
        writeI2C = load(io, "IOAVServiceWriteI2C", Transfer.self)
        info = load(core, "CoreDisplay_DisplayCreateInfoDictionary", DisplayInfo.self)
        canChange = load(native, "DisplayServicesCanChangeBrightness", CanChange.self)
        getNative = load(native, "DisplayServicesGetBrightness", GetNative.self)
        setNative = load(native, "DisplayServicesSetBrightness", SetNative.self)
    }
}

private struct DDCCandidate {
    let service: CFTypeRef
    let path: String
    let vendor: UInt32
    let product: UInt32
    let serial: UInt32
}

enum HardwareError: Error, CustomStringConvertible {
    case unavailable, readFailed, writeFailed, verificationFailed(Double)
    var description: String {
        switch self {
        case .unavailable: return "没有可用的硬件亮度接口"
        case .readFailed: return "无法读取显示器亮度，请检查连接和 DDC/CI 设置"
        case .writeFailed: return "显示器没有接受亮度指令"
        case .verificationFailed(let value): return "亮度读回值与请求不一致（\(Int((value * 100).rounded()))%）"
        }
    }
}

// IOAVService discovery and DDC packet layout follow MonitorControl's Arm64DDC.
// Copyright © MonitorControl contributors. See THIRD_PARTY_NOTICES.txt (MIT).
// All IORegistry objects are released here; replies require a valid checksum,
// successful VCP result, matching command, and a plausible current/max value.
final class BrightnessHardware {
    private enum Channel { case native; case ddc(CFTypeRef, UInt16) }
    private let api = SystemDisplayAPI()
    private var channels: [CGDirectDisplayID: Channel] = [:]
    private var lastKnown: [CGDirectDisplayID: DisplayState] = [:]

    private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    private func candidates() -> [DDCCandidate] {
        guard let create = api.createAV, api.readI2C != nil, api.writeI2C != nil else { return [] }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return [] }
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var path = ""
        var vendor: UInt32 = 0, product: UInt32 = 0, serial: UInt32 = 0
        var result: [DDCCandidate] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var buffer = [CChar](repeating: 0, count: 4096)
            guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { continue }
            let name = String(cString: buffer)
            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                path = ""; vendor = 0; product = 0; serial = 0
                if IORegistryEntryGetPath(entry, kIOServicePlane, &buffer) == KERN_SUCCESS { path = String(cString: buffer) }
                if let attributes = property(entry, "DisplayAttributes") as? [String: Any],
                   let details = attributes["ProductAttributes"] as? [String: Any] {
                    vendor = (details["LegacyManufacturerID"] as? NSNumber)?.uint32Value ?? 0
                    product = (details["ProductID"] as? NSNumber)?.uint32Value ?? 0
                    serial = (details["SerialNumber"] as? NSNumber)?.uint32Value ?? 0
                }
            } else if name == "DCPAVServiceProxy", property(entry, "Location") as? String == "External",
                      let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                result.append(DDCCandidate(service: service, path: path, vendor: vendor, product: product, serial: serial))
            }
        }
        return result
    }

    private func score(_ candidate: DDCCandidate, _ id: CGDirectDisplayID) -> Int {
        var score = 0
        if candidate.vendor != 0 && candidate.vendor == CGDisplayVendorNumber(id) && candidate.product == CGDisplayModelNumber(id) { score += 20 }
        if candidate.serial != 0 && candidate.serial == CGDisplaySerialNumber(id) { score += 10 }
        if let info = api.info?(id)?.takeRetainedValue() as? [String: Any],
           let location = info["IODisplayLocation"] as? String, !candidate.path.isEmpty, location == candidate.path { score += 100 }
        return score
    }

    private func nativeRead(_ id: CGDirectDisplayID) -> Double? {
        var value: Float = -1
        guard api.getNative?(id, &value) == 0, value.isFinite, value >= 0, value <= 1 else { return nil }
        return Double(value)
    }

    private func send(_ service: CFTypeRef, _ payload: [UInt8], isRead: Bool) -> Bool {
        guard let write = api.writeI2C else { return false }
        var packet = [UInt8(0x80 | (payload.count + 1)), UInt8(payload.count)] + payload + [0]
        packet[packet.count - 1] = packet.dropLast().reduce(isRead ? UInt8(0x6e) : UInt8(0x6e ^ 0x51), ^)
        var succeeded = false
        for _ in 0..<2 {
            usleep(10000)
            succeeded = packet.withUnsafeMutableBytes { write(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) == 0 }
        }
        return succeeded
    }

    private func ddcRead(_ service: CFTypeRef) -> (current: UInt16, maximum: UInt16)? {
        guard let read = api.readI2C else { return nil }
        for attempt in 0..<5 {
            if attempt > 0 { usleep(40000) }
            guard send(service, [0x10], isRead: true) else { continue }
            usleep(80000)
            var reply = [UInt8](repeating: 0, count: 11)
            let result = reply.withUnsafeMutableBytes { read(service, 0x37, 0, $0.baseAddress!, UInt32($0.count)) }
            let checksum = reply.dropLast().reduce(UInt8(0x50), ^)
            guard result == 0, reply[0] == 0x6e, reply[1] == 0x88, reply[2] == 0x02,
                  reply[3] == 0, reply[4] == 0x10, checksum == reply[10] else { continue }
            let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
            if maximum > 0, current <= maximum { return (current, maximum) }
        }
        return nil
    }

    func refresh(_ screens: [ScreenDescriptor]) -> [DisplayState] {
        channels.removeAll()
        let services = candidates()
        var used: Set<Int> = []
        let states = screens.map { screen -> DisplayState in
            if api.canChange?(screen.id) == true, api.setNative != nil, let value = nativeRead(screen.id) {
                channels[screen.id] = .native
                return DisplayState(id: screen.id, name: screen.name, backend: "DisplayServices", brightness: value)
            }
            let ranked = services.indices.filter { !used.contains($0) }.map { ($0, score(services[$0], screen.id)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
            // Never guess between two indistinguishable monitor/service pairs.
            if let match = ranked.first, ranked.count == 1 || match.1 > ranked[1].1 {
                used.insert(match.0)
                if let reading = ddcRead(services[match.0].service) {
                    channels[screen.id] = .ddc(services[match.0].service, reading.maximum)
                    return DisplayState(id: screen.id, name: screen.name, backend: "DDC/CI", brightness: Double(reading.current) / Double(reading.maximum))
                }
                // A busy monitor may fail one poll. Preserve a previously verified
                // route only when the same physical service is unambiguously mapped.
                // Reads/writes still have to succeed and are always verified.
                if let previous = lastKnown[screen.id], previous.name == screen.name, previous.backend == "DDC/CI",
                   let value = previous.brightness, let maximum = previousMaximum[screen.id], match.1 >= 30 {
                    channels[screen.id] = .ddc(services[match.0].service, maximum)
                    return DisplayState(id: screen.id, name: screen.name, backend: "DDC/CI", brightness: value, error: "显示器暂时忙，正在重试读取亮度")
                }
            }
            return DisplayState(id: screen.id, name: screen.name, backend: "unsupported", brightness: nil, error: HardwareError.unavailable.description)
        }
        lastKnown = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
        previousMaximum = previousMaximum.filter { lastKnown[$0.key]?.supported == true }
        for (id, channel) in channels {
            if case .ddc(_, let maximum) = channel { previousMaximum[id] = maximum }
        }
        return states
    }

    private var previousMaximum: [CGDirectDisplayID: UInt16] = [:]

    func read(_ id: CGDirectDisplayID) throws -> Double {
        guard let channel = channels[id] else { throw HardwareError.unavailable }
        switch channel {
        case .native:
            guard let value = nativeRead(id) else { throw HardwareError.readFailed }
            return value
        case .ddc(let service, _):
            guard let value = ddcRead(service) else { throw HardwareError.readFailed }
            channels[id] = .ddc(service, value.maximum)
            let brightness = Double(value.current) / Double(value.maximum)
            lastKnown[id]?.brightness = brightness
            lastKnown[id]?.error = nil
            previousMaximum[id] = value.maximum
            return brightness
        }
    }

    @discardableResult func set(_ id: CGDirectDisplayID, _ brightness: Double) throws -> Double {
        guard brightness.isFinite, let channel = channels[id] else { throw HardwareError.unavailable }
        let desired = min(1, max(0, brightness))
        let tolerance: Double
        switch channel {
        case .native:
            guard api.setNative?(id, Float(desired)) == 0 else { throw HardwareError.writeFailed }
            tolerance = 0.015
        case .ddc(let service, let maximum):
            let raw = UInt16((desired * Double(maximum)).rounded())
            guard send(service, [0x10, UInt8(raw >> 8), UInt8(raw & 0xff)], isRead: false) else { throw HardwareError.writeFailed }
            tolerance = 1.1 / Double(maximum)
        }
        usleep(80000)
        let actual = try read(id)
        guard abs(actual - desired) <= tolerance else { throw HardwareError.verificationFailed(actual) }
        return actual
    }
}

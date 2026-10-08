import AppKit
import ApplicationServices
import Darwin

func printJSON(_ value: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
}
func testKeyDecoder() -> Bool {
    func media(_ code: Int, down: Bool = true, repeatKey: Bool = false, flags: NSEvent.ModifierFlags = [], subtype: Int16 = 8) -> NSEvent {
        NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, subtype: subtype, data1: (code << 16) | (down ? 0x0a00 : 0x0b00) | (repeatKey ? 1 : 0), data2: -1)!
    }
    func normal(_ code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
    func decode(_ event: NSEvent, _ fkeys: Bool = false) -> BrightnessKey? { BrightnessKeys.decode(event, useFunctionKeys: fkeys) }
    var checks: [(String, Bool)] = [
        ("brightness up", decode(media(2))?.direction == 1),
        ("brightness down", decode(media(3))?.direction == -1),
        ("key release does not adjust", decode(media(3, down: false))?.pressed == false),
        ("held key repeats", decode(media(2, repeatKey: true))?.pressed == true),
        ("volume up passes through", decode(media(0)) == nil),
        ("volume down passes through", decode(media(1)) == nil),
        ("keyboard backlight passes through", decode(media(21)) == nil),
        ("different system subtype passes through", decode(media(2, subtype: 7)) == nil),
        ("option opens native settings", decode(media(2, flags: [.option])) == nil),
        ("command shortcut passes through", decode(media(2, flags: [.command])) == nil),
        ("fine brightness step", decode(media(2, flags: [.option, .shift]))?.fine == true),
        ("ordinary typing passes through", decode(normal(0), true) == nil),
        ("F1 preserved by default", decode(normal(122)) == nil),
        ("opt-in F1 decreases", decode(normal(122), true)?.direction == -1),
        ("opt-in F2 increases", decode(normal(120), true)?.direction == 1),
        ("command F1 preserved", decode(normal(122, flags: [.command]), true) == nil),
        ("backup shortcut increases", decode(normal(126, flags: [.control, .option]))?.direction == 1),
        ("backup shortcut decreases", decode(normal(125, flags: [.control, .option]))?.direction == -1),
        ("plain arrows preserved", decode(normal(126)) == nil)
    ]
    func equal(_ actual: Double, _ expected: Double) -> Bool { abs(actual - expected) < 0.000001 }
    checks += [
        ("zero reaches hardware minimum", equal(BrightnessScale.hardware(0), 0)),
        ("zero cannot create an opaque screen", equal(BrightnessScale.opacity(0), 0.95)),
        ("10 percent holds hardware at minimum", equal(BrightnessScale.hardware(0.1), 0)),
        ("10 percent darkens further by 50 percent", equal(BrightnessScale.opacity(0.1), 0.5)),
        ("20 percent reaches minimum with no shade", equal(BrightnessScale.hardware(0.2), 0) && equal(BrightnessScale.opacity(0.2), 0)),
        ("60 percent uses half hardware brightness", equal(BrightnessScale.hardware(0.6), 0.5)),
        ("100 percent reaches hardware maximum", equal(BrightnessScale.hardware(1), 1)),
        ("maximum has no software shading", equal(BrightnessScale.opacity(1), 0)),
        ("existing minimum maps to a visible level", equal(BrightnessScale.level(forHardware: 0), 0.2)),
        ("existing half brightness is preserved", equal(BrightnessScale.level(forHardware: 0.5), 0.6)),
        ("existing maximum is preserved", equal(BrightnessScale.level(forHardware: 1), 1)),
        ("hardware target clamps low", equal(BrightnessScale.hardware(-1), 0)),
        ("hardware target clamps high", equal(BrightnessScale.hardware(2), 1)),
        ("software shade clamps at the visible minimum", equal(BrightnessScale.opacity(-1), 0.95)),
        ("black opacity clamps high input", equal(BrightnessScale.opacity(2), 0))
    ]
    checks += [
        ("ordinary keys increase directly from one to five percent", equal(BrightnessScale.nextLevel(0.01, direction: 1, fine: false), 0.05)),
        ("ordinary keys decrease directly from five to one percent", equal(BrightnessScale.nextLevel(0.05, direction: -1, fine: false), 0.01)),
        ("ordinary keys cannot lower the one percent minimum", equal(BrightnessScale.nextLevel(0.01, direction: -1, fine: false), 0.01)),
        ("decreasing enters low range without skipping it", equal(BrightnessScale.nextLevel(0.0625, direction: -1, fine: false), 0.05)),
        ("ordinary keys retain larger steps above low range", equal(BrightnessScale.nextLevel(0.5, direction: 1, fine: false), 0.5625)),
        ("fine shortcut skips removed low stops", equal(BrightnessScale.nextLevel(0.05, direction: -1, fine: true), 0.01) && equal(BrightnessScale.nextLevel(0.01, direction: 1, fine: true), 0.05)),
        ("fine shortcut retains one percent steps above low range", equal(BrightnessScale.nextLevel(0.5, direction: 1, fine: true), 0.51)),
        ("slider normalizes removed stops to one or five percent", equal(BrightnessScale.normalized(0.02), 0.01) && equal(BrightnessScale.normalized(0.03), 0.05) && equal(BrightnessScale.normalized(0.04), 0.05)),
        ("visual commands reject deleted brightness stops", [0.0, 0.02, 0.03, 0.04].allSatisfy { !BrightnessScale.isSelectable($0) } && BrightnessScale.isSelectable(0.01) && BrightnessScale.isSelectable(0.05))
    ]
    for (name, success) in checks { print("\(success ? "PASS" : "FAIL") \(name)") }
    return checks.allSatisfy { $0.1 }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if let command = arguments.first {
    switch command {
    case "--self-test": exit(testKeyDecoder() ? 0 : 1)
    case "--status":
        if let data = try? Data(contentsOf: RuntimeStatus.url), let text = String(data: data, encoding: .utf8) { print(text); exit(0) }
        print("No runtime status; launch the app first."); exit(1)
    case "--set-visual", "--restore":
        guard let data = try? Data(contentsOf: RuntimeStatus.url),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              status["version"] as? String == "1.1.2", let pid = status["pid"] as? Int32, kill(pid, 0) == 0 else {
            print("Launch ExternalBrightness 1.1.2 first."); exit(1)
        }
        let name: String
        var values: [String: Any]?
        if command == "--set-visual" {
            guard arguments.count == 2, let percent = Double(arguments[1]), BrightnessScale.isSelectable(percent / 100) else {
                print("Usage: --set-visual <1 | 5...100> (0%, 2%, 3%, 4% removed)"); exit(2)
            }
            name = "local.ychen.ExternalBrightness.setVisual"; values = ["percent": percent]
        } else { name = "local.ychen.ExternalBrightness.restore" }
        DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(name), object: nil, userInfo: values, deliverImmediately: true)
        print("Requested \(command). Use --status to confirm the applied level."); exit(0)
    case "--register-login":
        UserDefaults.standard.set(true, forKey: "launchAtLogin")
        UserDefaults.standard.register(defaults: ["enabled": true, "useFunctionKeys": false])
        do { try LaunchAtLogin.configure(true); print("Login launch configured."); exit(0) }
        catch { print(error); exit(1) }
    case "--request-quit":
        DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("local.ychen.ExternalBrightness.quit"), object: nil, userInfo: nil, deliverImmediately: true)
        if let id = Bundle.main.bundleIdentifier {
            for _ in 0..<50 {
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).contains {
                    $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated && kill($0.processIdentifier, 0) == 0
                }
                if !running { break }
                usleep(100000)
            }
        }
        exit(0)
    case "--diagnose", "--set", "--hardware-test":
        let hardware = BrightnessHardware()
        let states = hardware.refresh(ScreenDescriptor.externalScreens())
        if command == "--diagnose" {
            printJSON(["architecture": "arm64", "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                       "accessibilityTrustedForThisProcess": AXIsProcessTrusted(), "displays": states.map { $0.json }]); exit(0)
        }
        let supported = states.filter { $0.supported }
        guard !supported.isEmpty else { printJSON(["error": "No supported external display"]); exit(1) }
        if command == "--set" {
            guard arguments.count == 2, let percent = Double(arguments[1]), percent.isFinite, (0...100).contains(percent) else { print("Usage: --set <0...100>"); exit(2) }
            var results: [[String: Any]] = []
            for state in supported {
                do { results.append(["name": state.name, "verifiedBrightnessPercent": try hardware.set(state.id, percent / 100) * 100]) }
                catch { printJSON(["error": String(describing: error)]); exit(1) }
            }
            printJSON(results); exit(0)
        }
        var results: [[String: Any]] = []
        var succeeded = true
        for state in supported {
            let original = state.brightness!
            let test = original >= 0.05 ? original - 0.05 : original + 0.05
            do {
                let changed = try hardware.set(state.id, test)
                let restored = try hardware.set(state.id, original)
                results.append(["name": state.name, "backend": state.backend, "originalPercent": original * 100,
                    "testReadbackPercent": changed * 100, "restoredReadbackPercent": restored * 100, "passed": true])
            } catch {
                succeeded = false
                var restored: Double?
                for _ in 0..<3 { if let value = try? hardware.set(state.id, original) { restored = value; break } }
                results.append(["name": state.name, "passed": false, "error": String(describing: error), "restored": restored != nil])
            }
        }
        printJSON(results); exit(succeeded ? 0 : 1)
    default:
        print("ExternalBrightness: --diagnose | --status | --self-test | --hardware-test | --set <hardware 0...100> | --set-visual <1 | 5...100> | --restore"); exit(2)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if let id = Bundle.main.bundleIdentifier,
   let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: {
       $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated && kill($0.processIdentifier, 0) == 0
   }) {
    existing.activate(options: []); exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()

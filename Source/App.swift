import AppKit
import ApplicationServices

enum RuntimeStatus {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ExternalBrightness/status.json")
    }
    static func write(_ value: [String: Any]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch { NSLog("ExternalBrightness status: %@", String(describing: error)) }
    }
}

final class BrightnessSliderView: NSView {
    let label = NSTextField(labelWithString: "")
    let slider: NSSlider
    init(_ state: DisplayState, target: AnyObject, action: Selector) {
        slider = NSSlider(value: state.brightness ?? BrightnessScale.minimumLevel, minValue: BrightnessScale.minimumLevel, maxValue: 1, target: target, action: action)
        super.init(frame: NSRect(x: 0, y: 0, width: 290, height: 65))
        label.frame = NSRect(x: 15, y: 37, width: 260, height: 20)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        slider.frame = NSRect(x: 15, y: 8, width: 260, height: 25)
        slider.tag = Int(state.id); slider.isContinuous = true
        addSubview(label); addSubview(slider); update(state)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(_ state: DisplayState) {
        let percent = Int(((state.brightness ?? 0) * 100).rounded())
        label.stringValue = "\(state.name)  ·  \(percent)%"
        label.toolTip = state.error ?? "最低档位为 1%、5%；20–100% 调整背光"
        slider.doubleValue = state.brightness ?? 0; slider.isEnabled = state.supported
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let hardware = BrightnessHardware()
    private let worker = DispatchQueue(label: "local.ychen.ExternalBrightness.hardware", qos: .userInitiated)
    private let keyboard = KeyboardListener()
    private let hud = BrightnessHUD()
    private let dimming = ScreenDimming()
    private let emergency = EmergencyRestore()
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var sliders: [CGDirectDisplayID: BrightnessSliderView] = [:]
    private var displays: [DisplayState] = []
    private var levels: [CGDirectDisplayID: Double] = [:]
    private var workerBusy = false
    private var needsRefresh = false
    private var pendingLevels: [CGDirectDisplayID: Double] = [:]
    private var menuTracking = false
    private var refreshDebounce: DispatchWorkItem?
    private var permissionTimer: Timer?
    private var pollTimer: Timer?
    private var keyPressCount = 0
    private var hardwareWriteCount = 0
    private var emergencyRestoreCount = 0
    private var lastKeyDate: Date?
    private var lastWriteDate: Date?
    private var lastError: String?
    private var enabled: Bool { defaults.bool(forKey: "enabled") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["enabled": true, "launchAtLogin": true, "useFunctionKeys": false])
        try? LaunchAtLogin.configure(defaults.bool(forKey: "launchAtLogin"))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "外接屏亮度")
        statusItem.button?.image?.isTemplate = true
        menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false; statusItem.menu = menu
        emergency.handle = { [weak self] in self?.restoreBrightness() }
        emergency.register()
        keyboard.handle = { [weak self] event in
            if let self, event.type == .keyDown || event.type == .keyUp,
               event.keyCode == 126, event.modifierFlags.contains([.control, .option, .command]) {
                if event.type == .keyDown { self.restoreBrightness() }
                return true
            }
            guard let self, self.enabled, self.displays.contains(where: { $0.supported }),
                  let key = BrightnessKeys.decode(event, useFunctionKeys: self.defaults.bool(forKey: "useFunctionKeys")) else { return false }
            if key.pressed {
                self.keyPressCount += 1; self.lastKeyDate = Date()
                self.adjust(key)
            }
            return true
        }
        updateKeyboard(); requestRefresh()
        let permissionTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.updateKeyboard() }
        self.permissionTimer = permissionTimer; RunLoop.main.add(permissionTimer, forMode: .common)
        let pollTimer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.requestRefresh() }
        self.pollTimer = pollTimer; RunLoop.main.add(pollTimer, forMode: .common)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(revealOnSessionChange), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(revealOnSessionChange), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(quit), name: NSNotification.Name("local.ychen.ExternalBrightness.quit"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(setVisualLevel), name: NSNotification.Name("local.ychen.ExternalBrightness.setVisual"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(restoreBrightness), name: NSNotification.Name("local.ychen.ExternalBrightness.restore"), object: nil)
        if enabled && !keyboard.running && !defaults.bool(forKey: "permissionExplained") {
            defaults.set(true, forKey: "permissionExplained")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.openPermissionSettings() }
        }
    }
    private func updateKeyboard() {
        let before = keyboard.running
        if enabled {
            if !keyboard.running && AXIsProcessTrusted() { _ = keyboard.start() }
            if keyboard.running && !AXIsProcessTrusted() { keyboard.stop() }
        } else { keyboard.stop() }
        if !keyboard.running { revealSoftwareDimmedScreens() }
        if before != keyboard.running { renderMenu(); report() }
    }
    private func requestRefresh() { needsRefresh = true; pump() }

    // One hardware operation at a time. Held keys and slider drags retain only
    // the latest target, so slow DDC writes cannot accumulate without bound.
    // Hardware I/O never runs inside the keyboard event-tap callback.
    private func pump() {
        guard !workerBusy else { return }
        if !pendingLevels.isEmpty {
            let requests = pendingLevels; pendingLevels.removeAll(); workerBusy = true
            worker.async { [weak self] in
                guard let self else { return }
                var results: [CGDirectDisplayID: Result<Double, Error>] = [:]
                for (id, value) in requests { results[id] = Result { try self.hardware.set(id, BrightnessScale.hardware(value)) } }
                DispatchQueue.main.async {
                    self.workerBusy = false
                    for (id, result) in results {
                        guard let index = self.displays.firstIndex(where: { $0.id == id }) else { continue }
                        switch result {
                        case .success(let actual):
                            self.hardwareWriteCount += 1; self.lastWriteDate = Date(); self.lastError = nil
                            self.displays[index].error = nil
                            self.displays[index].brightness = actual
                            if self.pendingLevels[id] == nil, let requested = requests[id], requested > BrightnessScale.softwareRange {
                                self.levels[id] = BrightnessScale.level(forHardware: actual)
                            }
                            if let level = self.levels[id], level > 0 {
                                self.hud.show(level, name: self.displays[index].name, displayID: id)
                            } else { self.hud.hideNow() }
                        case .failure(let error):
                            self.lastError = String(describing: error); self.displays[index].error = self.lastError
                            self.pendingLevels.removeValue(forKey: id); self.needsRefresh = true
                            self.levels[id] = BrightnessScale.level(forHardware: self.displays[index].brightness ?? 0)
                            self.applyDimming()
                            self.hud.show(nil, name: self.displays[index].name, error: "未能调整亮度，请检查显示器连接", displayID: id)
                            NSLog("ExternalBrightness: %@", String(describing: error))
                        }
                    }
                    self.renderMenu(); self.report(); self.pump()
                }
            }
        } else if needsRefresh {
            needsRefresh = false; workerBusy = true
            let screens = ScreenDescriptor.externalScreens()
            worker.async { [weak self] in
                guard let self else { return }
                let states = self.hardware.refresh(screens)
                DispatchQueue.main.async {
                    self.workerBusy = false; self.displays = states
                    let supported = Set(states.filter { $0.supported }.map { $0.id })
                    self.pendingLevels = self.pendingLevels.filter { supported.contains($0.key) }
                    self.levels = self.levels.filter { supported.contains($0.key) }
                    for state in states where state.supported {
                        if let pending = self.pendingLevels[state.id] { self.levels[state.id] = pending }
                        else if let current = self.levels[state.id], current <= BrightnessScale.softwareRange, state.brightness == 0 {
                            // Preserve the software part of the scale while the
                            // physical backlight remains at its verified minimum.
                        } else { self.levels[state.id] = BrightnessScale.level(forHardware: state.brightness!) }
                    }
                    if !self.keyboard.running { self.revealSoftwareDimmedScreens() }
                    self.applyDimming()
                    self.renderMenu(); self.report(); self.pump()
                }
            }
        }
    }
    private func adjust(_ key: BrightnessKey) {
        for index in displays.indices where displays[index].supported {
            let id = displays[index].id
            let current = levels[id] ?? BrightnessScale.level(forHardware: displays[index].brightness!)
            let value = safeLevel(BrightnessScale.nextLevel(current, direction: key.direction, fine: key.fine))
            levels[id] = value; pendingLevels[id] = value
        }
        applyDimming(); renderMenu(); report(); pump()
    }
    @objc private func sliderChanged(_ sender: NSSlider) {
        let id = CGDirectDisplayID(sender.tag)
        guard let index = displays.firstIndex(where: { $0.id == id }), displays[index].supported else { return }
        let value = safeLevel(sender.doubleValue)
        levels[id] = value; pendingLevels[id] = value
        applyDimming(); renderMenu(); report(); pump()
    }
    private func safeLevel(_ value: Double) -> Double {
        let level = BrightnessScale.normalized(value)
        // Require keyboard recovery for software dimming on the only screen.
        if level < BrightnessScale.softwareRange && (!enabled || !keyboard.running || !AXIsProcessTrusted()) { return BrightnessScale.softwareRange }
        return level
    }
    private func applyDimming() {
        dimming.apply(levels)
    }
    private func revealSoftwareDimmedScreens() {
        for (id, level) in levels where level < BrightnessScale.softwareRange {
            levels[id] = BrightnessScale.softwareRange
            if pendingLevels[id] != nil { pendingLevels[id] = BrightnessScale.softwareRange }
        }
        dimming.clear()
    }
    @objc private func revealOnSessionChange() { revealSoftwareDimmedScreens(); renderMenu(); report() }
    @objc private func restoreBrightness() {
        emergencyRestoreCount += 1; dimming.clear()
        for state in displays where state.supported { levels[state.id] = 1; pendingLevels[state.id] = 1 }
        renderMenu(); report(); pump()
    }
    @objc private func setVisualLevel(_ notification: Notification) {
        guard let percent = notification.userInfo?["percent"] as? Double, BrightnessScale.isSelectable(percent / 100) else { return }
        let value = safeLevel(percent / 100)
        for state in displays where state.supported { levels[state.id] = value; pendingLevels[state.id] = value }
        applyDimming(); renderMenu(); report(); pump()
    }
    private func viewState(_ state: DisplayState) -> DisplayState {
        var result = state
        result.brightness = levels[state.id] ?? state.brightness.map { BrightnessScale.level(forHardware: $0) }
        return result
    }
    private func item(_ title: String, _ action: Selector? = nil, checked: Bool? = nil) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
        result.target = self; result.isEnabled = action != nil
        if let checked { result.state = checked ? .on : .off }
        return result
    }
    private func renderMenu() {
        guard statusItem != nil else { return }
        let working = enabled && keyboard.running
        statusItem.button?.appearsDisabled = !enabled
        statusItem.button?.toolTip = "外接屏亮度 · \(working ? "键盘控制已启用" : enabled ? "等待辅助功能权限" : "键盘控制已暂停")"
        if menuTracking { for state in displays { sliders[state.id]?.update(viewState(state)) }; return }
        menu.removeAllItems(); sliders.removeAll()
        menu.addItem(item("外接屏亮度"))
        if displays.isEmpty { menu.addItem(item(workerBusy ? "正在检测显示器…" : "未连接外接显示器")) }
        for state in displays {
            if state.supported {
                let view = BrightnessSliderView(viewState(state), target: self, action: #selector(sliderChanged))
                sliders[state.id] = view
                let row = NSMenuItem(); row.view = view; menu.addItem(row)
            } else { menu.addItem(item("\(state.name) · 暂无硬件亮度接口")) }
        }
        menu.addItem(.separator())
        menu.addItem(item("恢复亮度（⌃⌥⌘↑）", #selector(restoreBrightness)))
        menu.addItem(item("启用键盘亮度控制", #selector(toggleEnabled), checked: enabled))
        menu.addItem(item("F1 / F2 同时用于亮度", #selector(toggleFunctionKeys), checked: defaults.bool(forKey: "useFunctionKeys")))
        menu.addItem(item("登录时启动", #selector(toggleLogin), checked: defaults.bool(forKey: "launchAtLogin")))
        if enabled && !keyboard.running { menu.addItem(item("授权辅助功能…", #selector(openPermissionSettings))) }
        menu.addItem(item("重新检测显示器", #selector(refreshMenuAction)))
        menu.addItem(item("使用说明…", #selector(showHelp)))
        menu.addItem(.separator()); menu.addItem(item("退出", #selector(quit)))
    }
    func menuWillOpen(_ menu: NSMenu) { renderMenu(); menuTracking = true; requestRefresh() }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false; renderMenu() }
    @objc private func toggleEnabled() {
        defaults.set(!enabled, forKey: "enabled"); updateKeyboard(); renderMenu(); report()
        if enabled && !keyboard.running { openPermissionSettings() }
    }
    @objc private func toggleFunctionKeys() { defaults.set(!defaults.bool(forKey: "useFunctionKeys"), forKey: "useFunctionKeys"); renderMenu(); report() }
    @objc private func toggleLogin() {
        let enabled = !defaults.bool(forKey: "launchAtLogin")
        do { try LaunchAtLogin.configure(enabled); defaults.set(enabled, forKey: "launchAtLogin") }
        catch { showMessage("无法修改登录启动", String(describing: error)) }
        renderMenu(); report()
    }
    @objc private func refreshMenuAction() { requestRefresh() }
    @objc private func screenChanged() { debounceRefresh(0.8) }
    @objc private func wokeUp() { debounceRefresh(2) }
    private func debounceRefresh(_ delay: Double) {
        refreshDebounce?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.requestRefresh(); self?.updateKeyboard() }
        refreshDebounce = task; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
    @objc private func openPermissionSettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    private func showMessage(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.addButton(withTitle: "好"); alert.runModal()
    }
    @objc private func showHelp() {
        showMessage("外接屏亮度", "最低档位为 1%、5%，之后保留较高亮度档位。0%、2%、3%、4% 已删除，键盘和滑块都会跳过这些数值。\n\n普通亮度键：5% 再降低到 1%，1% 再增加到 5%；高于 5% 时每次约 6%。Shift + Option + 亮度键在较高亮度区间每次约 1%，低亮度区间同样只在 1%、5% 之间切换。\n\n20–100% 调节硬件背光；低于 20% 时在硬件最低背光上继续调暗。显示器仍通电。Control + Option + Command + ↑ 可立即恢复到 100%。\n\nMX Keys 若发送普通 F1/F2，可在菜单中启用“F1 / F2 同时用于亮度”，或切换 Fn 锁。备用快捷键：Control + Option + ↑ / ↓。\n\n退出、暂停键盘控制、失去辅助功能权限或切换到登录界面时，会解除软件调暗。")
    }
    private func report() {
        var value: [String: Any] = [
            "app": "ExternalBrightness", "version": "1.1.2", "pid": ProcessInfo.processInfo.processIdentifier,
            "updatedAt": ISO8601DateFormatter().string(from: Date()), "enabled": enabled,
            "launchAtLogin": defaults.bool(forKey: "launchAtLogin"),
            "useFunctionKeys": defaults.bool(forKey: "useFunctionKeys"),
            "accessibilityTrusted": AXIsProcessTrusted(), "keyboardListening": keyboard.running,
            "hardwareBusy": workerBusy, "pendingHardwareWrites": pendingLevels.count,
            "keyPressCount": keyPressCount, "verifiedHardwareWriteCount": hardwareWriteCount,
            "emergencyShortcutReady": emergency.ready, "emergencyRestoreCount": emergencyRestoreCount,
            "softwareDimming": dimming.status,
            "displays": displays.map { state -> [String: Any] in
                var result = state.json
                result["hardwareBrightnessPercent"] = result["brightnessPercent"]
                let level = levels[state.id] ?? state.brightness.map { BrightnessScale.level(forHardware: $0) }
                if let level {
                    result["brightnessPercent"] = (level * 10000).rounded() / 100
                    result["softwareDimmingPercent"] = BrightnessScale.opacity(level) * 100
                    result["blackedOut"] = level == 0
                }
                return result
            }
        ]
        if let lastKeyDate { value["lastBrightnessKeyAt"] = ISO8601DateFormatter().string(from: lastKeyDate) }
        if let lastWriteDate { value["lastVerifiedHardwareWriteAt"] = ISO8601DateFormatter().string(from: lastWriteDate) }
        if let lastError { value["lastError"] = lastError }
        RuntimeStatus.write(value)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        dimming.clear(); emergency.stop(); keyboard.stop(); permissionTimer?.invalidate(); pollTimer?.invalidate()
    }
}

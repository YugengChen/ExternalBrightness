import AppKit

final class BrightnessHUD {
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?
    func hideNow() { hide?.cancel(); panel?.orderOut(nil) }
    func show(_ value: Double?, name: String, error: String? = nil, displayID: CGDirectDisplayID) {
        hide?.cancel()
        if panel == nil {
            let newPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 132), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            newPanel.isOpaque = false; newPanel.backgroundColor = .clear
            newPanel.level = .floating; newPanel.ignoresMouseEvents = true
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            newPanel.hidesOnDeactivate = false
            panel = newPanel
        }
        guard let panel else { return }
        let visual = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 260, height: 132))
        visual.material = .hudWindow; visual.blendingMode = .behindWindow; visual.state = .active
        visual.wantsLayer = true; visual.layer?.cornerRadius = 18; visual.layer?.masksToBounds = true
        let image = NSImageView(frame: NSRect(x: 110, y: 82, width: 40, height: 34))
        image.image = NSImage(systemSymbolName: error == nil ? "sun.max.fill" : "exclamationmark.triangle", accessibilityDescription: "亮度")
        image.contentTintColor = .labelColor
        visual.addSubview(image)
        let label = NSTextField(labelWithString: error ?? "\(name)  \(Int(((value ?? 0) * 100).rounded()))%")
        label.frame = NSRect(x: 12, y: 48, width: 236, height: 25)
        label.alignment = .center; label.font = .systemFont(ofSize: error == nil ? 15 : 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        visual.addSubview(label)
        let progress = NSProgressIndicator(frame: NSRect(x: 26, y: 24, width: 208, height: 10))
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        progress.doubleValue = value ?? 0; progress.style = .bar
        visual.addSubview(progress); panel.contentView = visual
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID } ?? NSScreen.main
        if let frame = screen?.visibleFrame { panel.setFrameOrigin(NSPoint(x: frame.midX - 130, y: frame.minY + 95)) }
        panel.orderFrontRegardless()
        let task = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        hide = task; DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: task)
    }
}

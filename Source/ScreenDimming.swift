import AppKit

enum BrightnessScale {
    static let softwareRange: Double = 0.20
    static let minimumLevel: Double = 0.01
    static let lowBrightnessCeiling: Double = 0.05
    static func isSelectable(_ level: Double) -> Bool {
        level.isFinite && (level == minimumLevel || (lowBrightnessCeiling...1).contains(level))
    }
    static func normalized(_ level: Double) -> Double {
        let clamped = min(1, max(minimumLevel, level))
        if clamped > minimumLevel && clamped < lowBrightnessCeiling {
            return clamped < 0.03 ? minimumLevel : lowBrightnessCeiling
        }
        return clamped
    }
    static func nextLevel(_ level: Double, direction: Double, fine: Bool) -> Double {
        let current = normalized(level)
        guard direction != 0 else { return current }
        let sign: Double = direction > 0 ? 1 : -1
        // Only 1% and 5% are selectable below 5%, for ordinary and fine keys.
        if current <= lowBrightnessCeiling {
            if sign < 0 { return minimumLevel }
            if current < lowBrightnessCeiling { return lowBrightnessCeiling }
        }
        let next = min(1, max(minimumLevel, current + sign * (fine ? 0.01 : 0.0625)))
        // Decreasing from above the low range must visit 5% before 1%.
        if sign < 0, current > lowBrightnessCeiling, next < lowBrightnessCeiling {
            return lowBrightnessCeiling
        }
        return normalized(next)
    }
    static func hardware(_ level: Double) -> Double {
        min(1, max(0, (normalized(level) - softwareRange) / (1 - softwareRange)))
    }
    static func level(forHardware value: Double) -> Double {
        softwareRange + min(1, max(0, value)) * (1 - softwareRange)
    }
    static func opacity(_ level: Double) -> Double {
        min(1, max(0, 1 - normalized(level) / softwareRange))
    }
}

private final class ShadePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class BlackView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
    }
}

// Window-based dimming leaves the user's ColorSync/Night Shift gamma tables
// untouched. Window lifetime makes software dimming disappear on app exit.
final class ScreenDimming {
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var opacities: [CGDirectDisplayID: Double] = [:]

    func apply(_ levels: [CGDirectDisplayID: Double]) {
        let screens = NSScreen.screens
        let screensByID = Dictionary(uniqueKeysWithValues: screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return (id, screen)
        })
        for id in Array(panels.keys) where levels[id] == nil || screensByID[id] == nil || BrightnessScale.opacity(levels[id]!) == 0 { remove(id) }
        for (id, level) in levels {
            let opacity = BrightnessScale.opacity(level)
            guard opacity > 0, let screen = screensByID[id] else { continue }
            let panel: NSPanel
            if let existing = panels[id] { panel = existing }
            else {
                let newPanel = ShadePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                newPanel.title = "ExternalBrightness Dimmer \(id)"
                newPanel.isReleasedWhenClosed = false
                newPanel.isOpaque = true; newPanel.backgroundColor = .black; newPanel.hasShadow = false
                newPanel.ignoresMouseEvents = true; newPanel.hidesOnDeactivate = false
                newPanel.isMovable = false; newPanel.isExcludedFromWindowsMenu = true
                newPanel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
                newPanel.collectionBehavior = [.stationary, .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .canJoinAllApplications]
                newPanel.contentView = BlackView(frame: NSRect(origin: .zero, size: screen.frame.size))
                panels[id] = newPanel; panel = newPanel
            }
            panel.setFrame(screen.frame, display: true)
            panel.alphaValue = opacity
            panel.orderFrontRegardless()
            opacities[id] = opacity
        }
    }
    private func remove(_ id: CGDirectDisplayID) {
        panels.removeValue(forKey: id)?.close(); opacities.removeValue(forKey: id)
    }
    func clear() {
        for id in Array(panels.keys) { remove(id) }
    }
    var status: [String: Any] {
        ["activeWindows": panels.map { id, panel in
            ["displayID": id, "opacity": opacities[id] ?? 0, "visible": panel.isVisible,
             "ignoresMouseEvents": panel.ignoresMouseEvents, "windowNumber": panel.windowNumber,
             "windowLevel": panel.level.rawValue,
             "frame": ["x": panel.frame.minX, "y": panel.frame.minY, "width": panel.frame.width, "height": panel.frame.height]] as [String: Any]
        }, "cursorHideRequested": false]
    }
    deinit { clear() }
}

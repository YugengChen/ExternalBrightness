import Foundation

enum LaunchAtLogin {
    static let label = "local.ychen.ExternalBrightness"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static func configure(_ enabled: Bool) throws {
        if !enabled {
            if FileManager.default.fileExists(atPath: plistURL.path) { try FileManager.default.removeItem(at: plistURL) }
            return
        }
        guard let executable = Bundle.main.executableURL else { return }
        let logDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ExternalBrightness")
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label, "ProgramArguments": [executable.path], "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 10,
            "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": logDirectory.appendingPathComponent("stdout.log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("stderr.log").path
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        // Avoid rewriting the login item on every launch.
        if (try? Data(contentsOf: plistURL)) != data { try data.write(to: plistURL, options: .atomic) }
    }
}

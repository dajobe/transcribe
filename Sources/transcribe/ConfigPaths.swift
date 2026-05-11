import Foundation

enum ConfigPaths {
    /// `$TRANSCRIBE_CONFIG` if set (absolute path to `config.json`), else XDG-style config path.
    static func configFileURL() throws -> URL {
        if let raw = ProcessInfo.processInfo.environment["TRANSCRIBE_CONFIG"], !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: false)
        }
        let dir = try configDirectoryURL()
        return dir.appendingPathComponent("config.json", isDirectory: false)
    }

    /// `XDG_CONFIG_HOME/transcribe` or `~/.config/transcribe` (including macOS).
    static func configDirectoryURL() throws -> URL {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            let expanded = (xdg as NSString).expandingTildeInPath
            base = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            let home = (("~/.config") as NSString).expandingTildeInPath
            base = URL(fileURLWithPath: home, isDirectory: true)
        }
        return base.appendingPathComponent("transcribe", isDirectory: true)
    }
}

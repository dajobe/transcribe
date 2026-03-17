import Foundation

/// Logs progress to stderr with optional elapsed time when verbose is true.
struct VerboseLogger {
    let verbose: Bool
    let startDate: Date

    func log(_ message: String) {
        guard verbose else { return }
        let elapsed = Int(Date().timeIntervalSince(startDate))
        let m = elapsed / 60
        let s = elapsed % 60
        let prefix = String(format: "[%02d:%02d] ", m, s)
        let line = prefix + message + "\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
}

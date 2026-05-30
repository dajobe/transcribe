import Foundation

/// Emits verbose progress through the active event reporter when verbose is true.
struct VerboseLogger {
    let verbose: Bool
    let startDate: Date
    let reporter: TranscribeEventReporter?

    func log(_ message: String) {
        guard verbose else { return }
        reporter?.verbose(message, elapsedSeconds: Date().timeIntervalSince(startDate))
    }
}

func emitWarning(_ message: String) {
    if TranscribeEventReporter.emitWarning(message) {
        return
    }
    let line = "Warning: \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

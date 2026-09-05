import Darwin
import Foundation

/// ANSI styling for one output stream. Styling is a fixed small set with no
/// cursor movement or line rewriting, so styled output degrades to plain text
/// wherever color is off and never breaks line-oriented consumers.
struct TerminalColor {
    let enabled: Bool

    /// Color is wanted on a stream when it is a terminal, `TERM` is set and
    /// not `dumb`, and `NO_COLOR` is unset (any value disables it, per
    /// no-color.org). `CLICOLOR_FORCE=1` forces color onto a non-terminal
    /// stream, which is also how tests capture styled output through pipes.
    static func detect(
        fileDescriptor: Int32,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalColor {
        if environment["NO_COLOR"] != nil { return TerminalColor(enabled: false) }
        if environment["CLICOLOR_FORCE"] == "1" { return TerminalColor(enabled: true) }
        guard let term = environment["TERM"], term != "dumb" else {
            return TerminalColor(enabled: false)
        }
        return TerminalColor(enabled: isatty(fileDescriptor) == 1)
    }

    static let disabled = TerminalColor(enabled: false)

    private func wrap(_ code: String, _ text: String) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    func bold(_ text: String) -> String { wrap("1", text) }
    func dim(_ text: String) -> String { wrap("2", text) }
    func red(_ text: String) -> String { wrap("31", text) }
    func green(_ text: String) -> String { wrap("32", text) }
    func yellow(_ text: String) -> String { wrap("33", text) }
    func cyan(_ text: String) -> String { wrap("36", text) }
}

enum Terminal {
    /// Detected once per process; commands run to completion, so a stream
    /// does not change nature mid-run.
    static let stdout = TerminalColor.detect(fileDescriptor: STDOUT_FILENO)
    static let stderr = TerminalColor.detect(fileDescriptor: STDERR_FILENO)

    /// Whether prompting a human makes sense: both the questions and the
    /// answers need a terminal.
    static var isInteractive: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }
}

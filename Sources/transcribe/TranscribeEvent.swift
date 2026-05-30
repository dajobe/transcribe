import Foundation
import ArgumentParser

enum TranscribeEventLevel: String, CaseIterable, ExpressibleByArgument, Codable, Comparable {
    case debug
    case info
    case warn
    case error

    var rendered: String { rawValue.uppercased() }

    private var priority: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    static func < (lhs: TranscribeEventLevel, rhs: TranscribeEventLevel) -> Bool {
        lhs.priority < rhs.priority
    }
}

enum TranscribeEventValue: Equatable {
    case string(String)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
    case strings([String])

    var rendered: String {
        switch self {
        case .string(let value):
            return Self.renderString(value)
        case .int(let value):
            return String(value)
        case .int64(let value):
            return String(value)
        case .double(let value):
            return Self.renderDouble(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .strings(let values):
            return Self.renderString(values.joined(separator: ","))
        }
    }

    private static func renderDouble(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private static func renderString(_ value: String) -> String {
        let needsQuoting = value.isEmpty
            || value.contains { $0.isWhitespace }
            || value.contains("\"")
            || value.contains("\\")
            || value.contains(",")
        guard needsQuoting else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

struct TranscribeEventField: Equatable {
    let name: String
    let value: TranscribeEventValue

    init(_ name: String, _ value: TranscribeEventValue) {
        self.name = name
        self.value = value
    }
}

struct TranscribeEvent: Equatable {
    let timestamp: Date
    let level: TranscribeEventLevel
    let name: String
    let fields: [TranscribeEventField]
    let message: String?

    init(
        timestamp: Date = Date(),
        level: TranscribeEventLevel = .info,
        name: String,
        fields: [TranscribeEventField] = [],
        message: String? = nil
    ) {
        self.timestamp = timestamp
        self.level = level
        self.name = name
        self.fields = fields
        self.message = message
    }
}

enum TranscribeEventTextRenderer {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func render(_ event: TranscribeEvent) -> String {
        var parts = [
            formatter.string(from: event.timestamp),
            event.level.rendered,
            "event=\(event.name)",
        ]
        parts.append(contentsOf: event.fields.map { "\($0.name)=\($0.value.rendered)" })
        if let message = event.message, !message.isEmpty {
            parts.append("message=\(TranscribeEventValue.string(message).rendered)")
        }
        return parts.joined(separator: " ")
    }
}

final class TranscribeEventReporter {
    private static let lock = NSLock()
    private static var currentReporter: TranscribeEventReporter?

    static func setCurrent(_ reporter: TranscribeEventReporter?) {
        lock.lock()
        currentReporter = reporter
        lock.unlock()
    }

    static func emitWarning(_ message: String) -> Bool {
        lock.lock()
        let reporter = currentReporter
        lock.unlock()
        guard let reporter else { return false }
        reporter.warning(message)
        return true
    }

    static func emitError(_ message: String, exitCode: Int32? = nil) -> Bool {
        lock.lock()
        let reporter = currentReporter
        lock.unlock()
        guard let reporter else { return false }
        var fields: [TranscribeEventField] = []
        if let exitCode {
            fields.append(TranscribeEventField("exit", .int(Int(exitCode))))
        }
        reporter.error("run_failed", fields: fields, message: message)
        return true
    }

    let statusEnabled: Bool
    let minimumLevel: TranscribeEventLevel
    private let handle: FileHandle
    private let textOutputEnabled: Bool
    private let diagnosticsSink: ((TranscribeEvent) -> Void)?
    private let failureSink: ((TranscribeEvent) -> Void)?

    init(
        statusEnabled: Bool = true,
        minimumLevel: TranscribeEventLevel = .info,
        handle: FileHandle = .standardOutput,
        textOutputEnabled: Bool = true,
        diagnosticsSink: ((TranscribeEvent) -> Void)? = nil,
        failureSink: ((TranscribeEvent) -> Void)? = nil
    ) {
        self.statusEnabled = statusEnabled
        self.minimumLevel = minimumLevel
        self.handle = handle
        self.textOutputEnabled = textOutputEnabled
        self.diagnosticsSink = diagnosticsSink
        self.failureSink = failureSink
    }

    func debug(_ name: String, fields: [TranscribeEventField] = [], message: String? = nil) {
        emit(TranscribeEvent(level: .debug, name: name, fields: fields, message: message))
    }

    func info(_ name: String, fields: [TranscribeEventField] = [], message: String? = nil) {
        emit(TranscribeEvent(level: .info, name: name, fields: fields, message: message))
    }

    func warning(_ message: String, fields: [TranscribeEventField] = []) {
        emit(TranscribeEvent(level: .warn, name: "warning", fields: fields, message: message))
    }

    func error(_ name: String, fields: [TranscribeEventField] = [], message: String? = nil) {
        emit(TranscribeEvent(level: .error, name: name, fields: fields, message: message))
    }

    func verbose(_ message: String, elapsedSeconds: TimeInterval) {
        debug(
            "verbose",
            fields: [TranscribeEventField("elapsed_s", .double(elapsedSeconds))],
            message: message
        )
    }

    private func emit(_ event: TranscribeEvent) {
        guard event.level >= minimumLevel else { return }
        let shouldWriteText = textOutputEnabled && (statusEnabled || event.level >= .warn)
        if shouldWriteText {
            let line = TranscribeEventTextRenderer.render(event) + "\n"
            handle.write(Data(line.utf8))
        }
        if event.level != .info {
            diagnosticsSink?(event)
        }
        if event.level == .error {
            failureSink?(event)
        }
    }
}

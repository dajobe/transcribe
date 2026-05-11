import Foundation

/// Explicit missing vs set value for CLI / config merge.
enum TriState<Value: Equatable>: Equatable {
    case omitted
    case value(Value)

    func merged(file: Value?, default def: Value) -> Value {
        switch self {
        case .value(let v):
            return v
        case .omitted:
            return file ?? def
        }
    }

}

extension TriState where Value == Bool {
    /// Pair of mutually exclusive flags: first is “enable”, second is “disable”.
    static func from(enable: Bool, disable: Bool, enableLabel: String, disableLabel: String) throws -> TriState<Bool> {
        if enable && disable {
            throw TranscribeError(
                message: "Cannot combine \(enableLabel) with \(disableLabel).",
                exitCode: .invalidUsage
            )
        }
        if enable { return .value(true) }
        if disable { return .value(false) }
        return .omitted
    }
}

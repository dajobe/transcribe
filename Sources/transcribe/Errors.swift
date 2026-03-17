import Foundation

enum ExitCode: Int32 {
    case success = 0
    case runtimeFailure = 1
    case invalidUsage = 2
    case inputFile = 3
    case modelFailure = 4
    case outputWrite = 5
}

struct TranscribeError: Error {
    let message: String
    let exitCode: ExitCode
}

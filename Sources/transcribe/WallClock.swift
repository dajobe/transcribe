import Foundation

enum WallClock {
    /// Measures synchronous work in milliseconds.
    static func measureMs<T>(_ block: () throws -> T) rethrows -> (value: T, ms: Int64) {
        let start = CFAbsoluteTimeGetCurrent()
        let value = try block()
        let ms = Int64((CFAbsoluteTimeGetCurrent() - start) * 1000.0)
        return (value, ms)
    }

    /// Measures synchronous non-throwing work in milliseconds.
    static func measureMs<T>(_ block: () -> T) -> (value: T, ms: Int64) {
        let start = CFAbsoluteTimeGetCurrent()
        let value = block()
        let ms = Int64((CFAbsoluteTimeGetCurrent() - start) * 1000.0)
        return (value, ms)
    }

    /// Measures async work in milliseconds.
    static func measureMs<T>(_ block: () async throws -> T) async rethrows -> (value: T, ms: Int64) {
        let start = CFAbsoluteTimeGetCurrent()
        let value = try await block()
        let ms = Int64((CFAbsoluteTimeGetCurrent() - start) * 1000.0)
        return (value, ms)
    }
}

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Owner-only append-only JSONL writer with POSIX advisory locking.
enum LockedAppendWriter {
    private static let ownerOnlyMode: mode_t = 0o600

    static func append(_ data: Data, to url: URL) throws {
#if canImport(Darwin)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, ownerOnlyMode)
        guard fd >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }

        if fchmod(fd, ownerOnlyMode) != 0 {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        guard flock(fd, LOCK_EX) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { flock(fd, LOCK_UN) }

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var bytesRemaining = buffer.count
            var offset = 0

            while bytesRemaining > 0 {
                let bytesWritten = write(fd, baseAddress.advanced(by: offset), bytesRemaining)
                if bytesWritten < 0 {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }

                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }
#else
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int(ownerOnlyMode))],
                ofItemAtPath: url.path
            )
        }
#endif
    }
}

#if canImport(Darwin)
func fileModeBits(atPath path: String) -> mode_t? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return info.st_mode
}
#endif

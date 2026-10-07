import Foundation

/// Names a canonical transcript a command operates on. Managed documents live
/// in the state database and are addressed by their internal ID; a portable
/// document is a `.transcript.json` file the user placed, read and edited in
/// place without being imported.
enum TranscriptRef: Equatable {
    case managed(id: UUID)
    case portable(URL)

    /// What output names the document by: the lowercased ID a managed
    /// document is addressed with, or a portable file's path.
    var displayName: String {
        switch self {
        case .managed(let id): return id.uuidString.lowercased()
        case .portable(let url): return url.path
        }
    }
}

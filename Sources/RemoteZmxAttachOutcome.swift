import Foundation

/// Sendable result of an attach, serialized by the socket worker after UI commit.
enum RemoteZmxAttachOutcome: Sendable {
    struct Mapping: Sendable {
        let session: String
        let workspaceID: UUID
        let surfaceID: UUID
    }
    case authentication([String])
    case mirrored(windowID: UUID, mappings: [Mapping])
}

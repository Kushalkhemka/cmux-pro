import CmuxCloud
import CmuxCore
import Foundation

/// Generates terminal commands from structured mappings instead of storing executable shell text.
struct RemoteZmxLaunch {
    static func newBinding(endpoint: RemoteZmxEndpoint, scopeID: UUID) -> RemoteZmxBinding? {
        try? RemoteZmxBinding(endpoint: endpoint,
            session: "cmux-\(scopeID.uuidString.prefix(8).lowercased())-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased())")
    }

    static var missingMessage: String {
        String(localized: "remoteZmx.sessionMissing", defaultValue: "The zmx session no longer exists. Refresh the host to discover its current sessions.")
    }

    static func command(_ binding: RemoteZmxBinding, create: Bool = false,
                        command: String? = nil, workingDirectory: String? = nil) -> String {
        guard ManagedRemoteConnectionsPolicy.isEnabled else { return "/usr/bin/false" }
        return binding.startupCommand(
            sshArguments: binding.endpoint.terminalSSHArguments,
            create: create,
            reconnectMessage: String(localized: "remoteZmx.reconnecting", defaultValue: "SSH disconnected. Reconnecting to the zmx session…"),
            missingMessage: missingMessage,
            command: command, workingDirectory: workingDirectory
        )
    }
}

import CmuxCloud
import CmuxCore
import CmuxControlSocket
import Foundation

extension TerminalController {
    /// Runs SSH discovery off the main actor; only the native layout commit needs it.
    nonisolated func v2RemoteZmx(id: Any?, method: String, params: [String: Any]) -> String {
        guard ManagedRemoteConnectionsPolicy.isEnabled else {
            return v2Error(id: id, code: "remote_connections_disabled", message: ManagedRemoteConnectionsPolicy.disabledMessage)
        }
        // These methods stay denied by RemoteRelayCommandPolicy. They can spawn local SSH.
        guard let host = Self.remoteTmuxHost(from: params),
              let endpoint = try? RemoteZmxEndpoint(destination: host.destination, port: host.port,
                identityFile: host.identityFile, executable: params["zmx_path"] as? String ?? "zmx",
                socketDirectory: params["zmx_dir"] as? String),
              params["session"] == nil || (params["session"] as? String).flatMap({
                  try? RemoteZmxBinding(endpoint: endpoint, session: $0)
              }) != nil else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "remoteZmx.invalidParams", defaultValue: "Invalid zmx connection or session."))
        }
        guard params["create"] as? Bool != true || params["session"] != nil else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "remoteZmx.invalidParams", defaultValue: "Invalid zmx connection or session."))
        }
        let session = params["session"] as? String
        let create = params["create"] as? Bool ?? false
        let activate = params["activate"] as? Bool ?? false
        let title = params["workspace_name"] as? String
        let routing = remoteTmuxRouting(from: params)
        return v2VmCall(id: id, timeoutSeconds: 60) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteZmxController }) else {
                throw RemoteTmuxError.windowCreationFailed
            }
            if method == "remote.zmx.sessions" {
                do {
                    let sessions = try await controller.list(endpoint)
                    return ["host": endpoint.destination, "sessions": sessions.map { ["name": $0.session] }]
                } catch let error as RemoteTmuxError {
                    if case .commandFailed(_, let stderr) = error,
                       RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr) {
                        let host = await controller.sshHost(endpoint)
                        return ["host": endpoint.destination, "auth_required": true, "ssh_argv": host.interactiveAuthInvocation()]
                    }
                    throw error
                }
            }
            let target: RemoteTmuxAttachWindowTarget = await MainActor.run {
                method == "remote.zmx.window" ? .dedicatedNewWindow : self.remoteTmuxAttachWindowTarget(routing: routing)
            }
            let outcome = try await controller.mirror(endpoint: endpoint, session: session, create: create,
                target: target, activate: activate, title: title)
            switch outcome {
            case .authentication(let argv): return ["host": endpoint.destination, "auth_required": true, "ssh_argv": argv]
            case .mirrored(let windowID, let mappings):
                return ["host": endpoint.destination, "mirrored": true, "window_id": windowID.uuidString,
                    "workspace_ids": Array(Set(mappings.map { $0.workspaceID.uuidString })),
                    "sessions": mappings.map { ["session": $0.session, "workspace_id": $0.workspaceID.uuidString,
                        "surface_id": $0.surfaceID.uuidString] }]
            }
        }
    }
}

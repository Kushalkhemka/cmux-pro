import CmuxCloud
import CmuxCore
import CmuxTerminal
import GhosttyKit
import Foundation
import Observation

/// Discovers zmx sessions and commits their native terminal mapping on the main actor.
@MainActor @Observable
final class RemoteZmxController {
    private let transports = RemoteTmuxTransportRegistry()

    /// Resolves the current panel owner, rejecting callbacks from a replaced runtime.
    func binding(for surface: TerminalSurface) -> RemoteZmxBinding? {
        let terminals = (AppDelegate.shared?.surfaceCatalogWorkspaces() ?? []).flatMap {
            $0.panels.values.compactMap { $0 as? TerminalPanel }
        } + DockSplitStore.liveStores.flatMap { $0.panels.values.compactMap { $0 as? TerminalPanel } }
        return terminals.first { $0.surface === surface }?.remoteZmxBinding
    }

    func detachAll() {
        var hosts = Dictionary(transports.allHosts().map { ($0.connectionHash, $0) }, uniquingKeysWith: { first, _ in first })
        let terminals = (AppDelegate.shared?.surfaceCatalogWorkspaces() ?? []).flatMap {
            $0.panels.values.compactMap { $0 as? TerminalPanel }
        } + DockSplitStore.liveStores.flatMap { $0.panels.values.compactMap { $0 as? TerminalPanel } }
        for endpoint in terminals.compactMap({ $0.remoteZmxBinding?.endpoint }) {
            let host = sshHost(endpoint)
            hosts[host.connectionHash] = host
        }
        transports.removeAll()
        for host in hosts.values { RemoteTmuxSSHTransport.spawnControlMasterExit(host: host) }
    }

    func sshHost(_ endpoint: RemoteZmxEndpoint) -> RemoteTmuxHost {
        RemoteTmuxHost(destination: endpoint.destination, port: endpoint.port,
            identityFile: endpoint.identityFile, controlSocketNamespace: .zmx)
    }

    func list(_ endpoint: RemoteZmxEndpoint) async throws -> [RemoteZmxBinding] {
        let result = try await transports.transport(for: sshHost(endpoint))
            .run(["sh", "-c", endpoint.discoveryScript])
        guard result.succeeded else {
            throw RemoteTmuxError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return try RemoteZmxSessionList(output: result.stdout, endpoint: endpoint).bindings
    }

    /// Performs SSH preflight before creating UI, then commits layout without awaits.
    func mirror(endpoint: RemoteZmxEndpoint, session: String?, create: Bool,
                target: RemoteTmuxAttachWindowTarget, activate: Bool, title: String?) async throws -> RemoteZmxAttachOutcome {
        let host = sshHost(endpoint)
        let discovered: [RemoteZmxBinding]
        do {
            discovered = try await list(endpoint)
        } catch let error as RemoteTmuxError {
            if case .commandFailed(_, let stderr) = error,
               RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr) {
                return .authentication(host.interactiveAuthInvocation())
            }
            throw error
        }
        guard try await transports.transport(for: host).ensureMasterReady() else {
            throw RemoteTmuxError.unreachable(endpoint.destination)
        }
        try Task.checkCancellation()
        return try mirrorDiscovered(endpoint: endpoint, discovered: discovered, session: session,
            create: create, target: target, activate: activate, title: title)
    }

    /// Commits a discovered mapping atomically after SSH preflight.
    func mirrorDiscovered(endpoint: RemoteZmxEndpoint, discovered: [RemoteZmxBinding],
                          session: String?, create: Bool, target: RemoteTmuxAttachWindowTarget,
                          activate: Bool, title: String?, workspaceID: UUID? = nil,
                          callerSurfaceID: UUID? = nil) throws -> RemoteZmxAttachOutcome {
        var bindings = discovered
        var created: Set<RemoteZmxBinding> = []
        if let session {
            let binding = try RemoteZmxBinding(endpoint: endpoint, session: session)
            guard create || discovered.contains(binding) else {
                throw RemoteTmuxError.unreachable(RemoteZmxLaunch.missingMessage)
            }
            bindings = [binding]
            if !discovered.contains(binding) { created.insert(binding) }
        } else if bindings.isEmpty {
            let binding = try RemoteZmxBinding(endpoint: endpoint, session: "cmux-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20).lowercased())
            bindings = [binding]
            created.insert(binding)
        }
        guard ManagedRemoteConnectionsPolicy.isEnabled else {
            throw RemoteTmuxError.unreachable(ManagedRemoteConnectionsPolicy.disabledMessage)
        }
        guard let app = AppDelegate.shared else { throw RemoteTmuxError.windowCreationFailed }
        let allWorkspaces = app.surfaceCatalogWorkspaces()
        let stores = DockSplitStore.liveStores
        let matches: (any Panel) -> Bool = { panel in
            guard let binding = (panel as? TerminalPanel)?.remoteZmxBinding, binding.endpoint == endpoint else { return false }
            return session == nil || binding.session == session
        }
        let requestedOwner = session.flatMap { _ in allWorkspaces.first { $0.panels.values.contains(where: matches) } }
        let requestedDock = session.flatMap { _ in stores.first { $0.panels.values.contains(where: matches) } }
        let existing = requestedOwner ?? allWorkspaces.first { $0.remoteZmxEndpoint == endpoint }
            ?? allWorkspaces.first { $0.panels.values.contains(where: matches) }
        let existingDock = stores.first { $0.panels.values.contains(where: matches) }
        let existingManager = requestedOwner?.owningTabManager
            ?? requestedDock.flatMap { app.dockReferenceTabManager(for: $0) }
            ?? existing?.owningTabManager ?? existingDock.flatMap { app.dockReferenceTabManager(for: $0) }
        let existingWindow = existingManager.flatMap { app.windowId(for: $0) }
        let activeWindow = app.tabManager.flatMap { app.windowId(for: $0) }
        var bootstrap: Workspace?
        let windowID: UUID
        if target == .dedicatedNewWindow, existingWindow == nil {
            windowID = app.createMainWindow(shouldActivate: false)
            bootstrap = app.tabManagerFor(windowId: windowID)?.tabs.first
        } else {
            guard let resolved = target.resolve(existingMirrorWindowID: existingWindow,
                activeWindowID: activeWindow, isLive: { app.tabManagerFor(windowId: $0) != nil })
            else { throw RemoteTmuxError.windowCreationFailed }
            windowID = resolved
        }
        guard let manager = app.tabManagerFor(windowId: windowID) else { throw RemoteTmuxError.windowCreationFailed }
        let liveTerminals = allWorkspaces.flatMap { $0.panels.values.compactMap { $0 as? TerminalPanel } } +
            stores.flatMap { $0.panels.values.compactMap { $0 as? TerminalPanel } }
        let alreadyMapped = Set(liveTerminals.compactMap(\.remoteZmxBinding))
        if session == nil, discovered.isEmpty,
           let pending = liveTerminals.compactMap(\.remoteZmxBinding).first(where: { $0.endpoint == endpoint }) {
            bindings = [pending]
            created.removeAll()
        }
        var workspace = existing
        for binding in bindings {
            if alreadyMapped.contains(binding) {
                if let owner = allWorkspaces.first(where: { w in
                    w.panels.values.contains { ($0 as? TerminalPanel)?.remoteZmxBinding == binding }
                }), let panel = owner.panels.values.compactMap({ $0 as? TerminalPanel }).first(where: { $0.remoteZmxBinding == binding }),
                   let surface = panel.surface.surface, ghostty_surface_process_exited(surface) {
                    _ = owner.reattachZmxPanel(panelID: panel.id, create: created.contains(binding), focus: false)
                } else if let dock = stores.first(where: { dock in
                    dock.panels.values.contains { ($0 as? TerminalPanel)?.remoteZmxBinding == binding }
                }), let panel = dock.panels.values.compactMap({ $0 as? TerminalPanel }).first(where: { $0.remoteZmxBinding == binding }),
                   let surface = panel.surface.surface, ghostty_surface_process_exited(surface) {
                    _ = dock.respawnZmxPanel(panelID: panel.id, create: created.contains(binding))
                }
                continue
            }
            if workspace == nil {
                guard let newWorkspace = manager.addWorkspaceIfActive(
                    title: title ?? endpoint.destination, titleSource: .auto,
                    initialTerminalCommand: RemoteZmxLaunch.command(binding, create: created.contains(binding)),
                    initialTerminalIsRemote: true, inheritWorkingDirectory: false,
                    select: false, eagerLoadTerminal: true, autoWelcomeIfNeeded: false, autoRefreshMetadata: false
                ), let panel = newWorkspace.panels.values.first as? TerminalPanel else {
                    throw RemoteTmuxError.windowCreationFailed
                }
                newWorkspace.remoteZmxEndpoint = endpoint
                newWorkspace.adoptZmxBinding(binding, panel: panel)
                workspace = newWorkspace
            } else if let workspace, let pane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first {
                guard let panel = workspace.newTerminalSurface(inPane: pane, focus: false,
                    autoRefreshMetadata: false, suppressWorkspaceRemoteStartupCommand: true,
                    remoteZmxBinding: binding, createZmxSession: created.contains(binding)) else {
                    throw RemoteTmuxError.windowCreationFailed
                }
                workspace.adoptZmxBinding(binding, panel: panel)
                panel.surface.requestBackgroundSurfaceStartIfNeeded()
            }
        }
        if let bootstrap, manager.tabs.count > 1 { manager.closeWorkspace(bootstrap, recordHistory: false) }
        if activate, let requestedDock, let panel = requestedDock.panels.values.first(where: matches) {
            requestedDock.focusPanel(panel.id)
            _ = app.focusMainWindow(windowId: windowID)
        } else if activate, let workspace {
            manager.selectWorkspace(workspace)
            if let session, let panel = workspace.panels.values.first(where: {
                ($0 as? TerminalPanel)?.remoteZmxBinding?.session == session &&
                ($0 as? TerminalPanel)?.remoteZmxBinding?.endpoint == endpoint
            }) {
                workspace.focusPanel(panel.id)
            }
            _ = app.focusMainWindow(windowId: windowID)
        } else if activate, let existingDock,
                  let panel = existingDock.panels.values.first(where: matches) {
            existingDock.focusPanel(panel.id)
            _ = app.focusMainWindow(windowId: windowID)
        }
        var mapped = app.surfaceCatalogWorkspaces().flatMap { w in
            w.panels.values.compactMap { panel -> RemoteZmxAttachOutcome.Mapping? in
                guard let binding = (panel as? TerminalPanel)?.remoteZmxBinding, binding.endpoint == endpoint else { return nil }
                return .init(session: binding.session, workspaceID: w.id, surfaceID: panel.id)
            }
        }
        mapped += DockSplitStore.liveStores.flatMap { dock in
            dock.panels.values.compactMap { panel -> RemoteZmxAttachOutcome.Mapping? in
                guard let binding = (panel as? TerminalPanel)?.remoteZmxBinding, binding.endpoint == endpoint else { return nil }
                return .init(session: binding.session, workspaceID: dock.workspaceId, surfaceID: panel.id)
            }
        }
        return .mirrored(windowID: windowID, mappings: mapped)
    }
}

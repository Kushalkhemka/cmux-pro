import Bonsplit
import CmuxCore
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor @Suite(.serialized)
struct RemoteZmxWorkspaceTests {
    @Test(arguments: [false, true])
    func requestedDockMappingWinsOverOriginalWorkspace(otherWindow: Bool) throws {
        let previousApp = AppDelegate.shared
        let app = previousApp ?? AppDelegate()
        let previousManager = app.tabManager
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let sourceWindow = app.registerMainWindowContextForTesting(tabManager: manager)
        let dockManager = otherWindow ? TabManager(autoWelcomeIfNeeded: false) : manager
        let dockWindow = otherWindow ? app.registerMainWindowContextForTesting(tabManager: dockManager) : sourceWindow
        AppDelegate.shared = app
        app.tabManager = manager
        let dock = DockSplitStore(workspaceId: dockWindow, scope: .global, baseDirectoryProvider: { nil })
        defer {
            dock.closeAllPanels()
            for owner in [manager, dockManager] {
                for workspace in Array(owner.tabs) {
                    for id in Array(workspace.panels.keys) { _ = workspace.closePanel(id, force: true) }
                }
            }
            if otherWindow { app.unregisterMainWindowContextForTesting(windowId: dockWindow) }
            app.unregisterMainWindowContextForTesting(windowId: sourceWindow)
            app.tabManager = previousManager
            AppDelegate.shared = previousApp
        }
        let workspace = try #require(manager.selectedWorkspace)
        let endpoint = try RemoteZmxEndpoint(destination: "dock-focus.example.test")
        workspace.remoteZmxEndpoint = endpoint
        let first = try #require(workspace.panels.values.first as? TerminalPanel)
        let movedBinding = try RemoteZmxBinding(endpoint: endpoint, session: "moved")
        workspace.adoptZmxBinding(movedBinding, panel: first)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let retained = try #require(workspace.newTerminalSurface(inPane: pane, focus: false))
        let retainedBinding = try #require(retained.remoteZmxBinding)
        let transfer = try #require(workspace.detachSurface(panelId: first.id))
        dock.ensureLoaded()
        let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
        let movedID = try #require(dock.attachDetachedSurface(transfer, inPane: dockPane, focus: false))
        let otherID = try #require(dock.newSurface(kind: .terminal, inPane: dockPane, sourcePanelId: movedID, focus: true))
        #expect(dock.focusedPanelId == otherID)
        let result = try RemoteZmxController().mirrorDiscovered(endpoint: endpoint,
            discovered: [movedBinding, retainedBinding], session: "moved", create: false,
            target: .contextualWindow(sourceWindow), activate: true, title: nil)
        guard case .mirrored(let windowID, _) = result else { Issue.record("Expected native mapping"); return }
        #expect(windowID == dockWindow)
        #expect(dock.focusedPanelId == movedID)
    }

    @Test func movedMappingRestoresBeforeManagedSSHWorkspaceRouting() throws {
        let source = Workspace(title: "zmx", initialTerminalCommand: "/usr/bin/true")
        let endpoint = try RemoteZmxEndpoint(destination: "original.example.test")
        let first = try #require(source.panels.values.first as? TerminalPanel)
        let binding = try RemoteZmxBinding(endpoint: endpoint, session: "moved")
        source.adoptZmxBinding(binding, panel: first)
        let transfer = try #require(source.detachSurface(panelId: first.id))
        let destination = Workspace(title: "SSH", initialTerminalCommand: "/usr/bin/true")
        destination.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "other.example.test", port: nil, identityFile: nil, sshOptions: [],
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, preserveAfterTerminalExit: true)
        #expect(destination.usesSSHTui)
        let pane = try #require(destination.bonsplitController.allPaneIds.first)
        let movedID = try #require(destination.attachDetachedSurface(transfer, inPane: pane, focus: false))
        let snapshot = try #require(destination.sessionSnapshot(includeScrollback: false).panels.first { $0.id == movedID })
        let restoredID = try #require(destination.createPanel(from: snapshot, inPane: pane,
            snapshotWorkspaceId: destination.id, shouldRestoreSingleDefaultCloudTerminal: false))
        let restored = try #require(destination.terminalPanel(for: restoredID))
        #expect(restored.remoteZmxBinding == binding)
        #expect(restored.surface.debugInitialCommand() != nil)
        destination.remoteConfiguration = nil
        for workspace in [source, destination] {
            for id in Array(workspace.panels.keys) { _ = workspace.closePanel(id, force: true) }
        }
    }

    @Test func publicCommandlessRespawnReattachesTheMappedSession() throws {
        let previousApp = AppDelegate.shared
        let app = previousApp ?? AppDelegate()
        let previousManager = app.tabManager
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowID = app.registerMainWindowContextForTesting(tabManager: manager)
        AppDelegate.shared = app
        app.tabManager = manager
        defer {
            for workspace in Array(manager.tabs) {
                for id in Array(workspace.panels.keys) { _ = workspace.closePanel(id, force: true) }
            }
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            app.tabManager = previousManager
            AppDelegate.shared = previousApp
        }
        let workspace = try #require(manager.selectedWorkspace)
        let terminal = try #require(workspace.panels.values.first as? TerminalPanel)
        let binding = try RemoteZmxBinding(endpoint: RemoteZmxEndpoint(destination: "respawn.example.test"), session: "retained")
        workspace.adoptZmxBinding(binding, panel: terminal)
        let tabID = workspace.surfaceIdFromPanelId(terminal.id)
        let result = ControlCommandCoordinator(context: TerminalController.shared).handle(ControlRequest(
            id: .int(1), method: "surface.respawn", params: [
                "workspace_id": .string(workspace.id.uuidString),
                "surface_id": .string(terminal.id.uuidString), "focus": .bool(false),
            ]))
        guard case .ok = result else { Issue.record("Expected reattachment: \(result)"); return }
        let replacement = try #require(workspace.terminalPanel(for: terminal.id))
        #expect(replacement !== terminal)
        #expect(replacement.remoteZmxBinding == binding)
        #expect(replacement.stableSurfaceId == terminal.stableSurfaceId)
        #expect(workspace.surfaceIdFromPanelId(terminal.id) == tabID)
    }

    @Test func childExitKeepsTheMappedTabForReattachment() throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(initialTerminalCommand: "/usr/bin/true", select: false)
        let terminal = try #require(workspace.panels.values.first as? TerminalPanel)
        let endpoint = try RemoteZmxEndpoint(destination: "exited.example.test")
        workspace.adoptZmxBinding(try RemoteZmxBinding(endpoint: endpoint, session: "retained"), panel: terminal)
        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: terminal.id, runtimeSurface: terminal.surface)
        #expect(workspace.terminalPanel(for: terminal.id) === terminal)
        #expect(manager.tabs.contains { $0 === workspace })
        for tab in Array(manager.tabs) {
            tab.remoteZmxEndpoint = nil
            for id in Array(tab.panels.keys) { _ = tab.closePanel(id, force: true) }
        }
    }

    @Test func discoveryMasterIsIsolatedFromTmux() throws {
        let endpoint = try RemoteZmxEndpoint(destination: "user@host", port: 2222)
        let zmxHost = RemoteZmxController().sshHost(endpoint)
        let tmuxHost = RemoteTmuxHost(destination: endpoint.destination, port: endpoint.port)
        #expect(zmxHost.connectionHash != tmuxHost.connectionHash)
        #expect(zmxHost.controlSocketPath != tmuxHost.controlSocketPath)
        #expect(zmxHost.sshControlArguments(controlPersistSeconds: 300, batchMode: true)
            .contains("ControlPath=" + zmxHost.controlSocketPath))
        #expect(tmuxHost.controlSocketPath.contains("/ssh/tmux-"))
    }

    @Test func tabsSplitsAndRestoreKeepIndependentSessionsAndLayout() throws {
        let workspace = Workspace(title: "zmx", initialTerminalCommand: "/usr/bin/true")
        let endpoint = try RemoteZmxEndpoint(destination: "zmx-test.example.test")
        workspace.remoteZmxEndpoint = endpoint
        let first = try #require(workspace.panels.values.first as? TerminalPanel)
        let binding = try RemoteZmxBinding(endpoint: endpoint, session: "existing")
        workspace.adoptZmxBinding(binding, panel: first)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let tab = try #require(workspace.newTerminalSurface(inPane: pane, focus: false))
        let split = try #require(workspace.withSplitSpaceAdmissionBypass {
            workspace.newTerminalSplit(from: first.id, orientation: .horizontal, focus: false)
        })
        let bindings = [first, tab, split].compactMap(\.remoteZmxBinding)
        #expect(bindings.count == 3)
        #expect(Set(bindings).count == 3)
        #expect(bindings.allSatisfy { $0.endpoint == endpoint })
        let splitTabID = try #require(workspace.surfaceIdFromPanelId(split.id))
        #expect(workspace.bonsplitController.tab(splitTabID)?.title == split.remoteZmxBinding?.session)
        #expect(!workspace.panelNeedsConfirmClose(panelId: first.id))
        _ = workspace.setPanelCustomTitle(panelId: tab.id, title: "My agent")
        workspace.setPanelPinned(panelId: tab.id, pinned: true)

        let saved = try JSONDecoder().decode(SessionWorkspaceSnapshot.self,
            from: JSONEncoder().encode(workspace.sessionSnapshot(includeScrollback: false)))
        #expect(saved.remoteZmxEndpoint == endpoint)
        let restored = Workspace(title: "restored", initialTerminalCommand: "/usr/bin/true")
        let remap = restored.restoreSessionSnapshot(saved)
        #expect(restored.bonsplitController.allPaneIds.count == workspace.bonsplitController.allPaneIds.count)
        #expect(Set(restored.panels.values.compactMap { ($0 as? TerminalPanel)?.remoteZmxBinding }) == Set(bindings))
        let restoredTabID = try #require(remap[tab.id])
        #expect(restored.panelCustomTitles[restoredTabID] == "My agent")
        #expect(restored.pinnedPanelIds.contains(restoredTabID))
        workspace.remoteZmxEndpoint = nil
        restored.remoteZmxEndpoint = nil
        for id in Array(workspace.panels.keys) { _ = workspace.closePanel(id, force: true) }
        for id in Array(restored.panels.keys) { _ = restored.closePanel(id, force: true) }
    }

    @Test func movedPanelRetainsEndpointAndNewSplitsUseThatEndpoint() throws {
        let source = Workspace(title: "source", initialTerminalCommand: "/usr/bin/true")
        let endpoint = try RemoteZmxEndpoint(destination: "moved.example.test")
        let first = try #require(source.panels.values.first as? TerminalPanel)
        let binding = try RemoteZmxBinding(endpoint: endpoint, session: "move-me")
        source.adoptZmxBinding(binding, panel: first)
        let transfer = try #require(source.detachSurface(panelId: first.id))
        let destination = Workspace(title: "target", initialTerminalCommand: "/usr/bin/true")
        let pane = try #require(destination.bonsplitController.allPaneIds.first)
        let moved = try #require(destination.attachDetachedSurface(transfer, inPane: pane, focus: false))
        #expect(destination.terminalPanel(for: moved)?.remoteZmxBinding == binding)
        #expect(destination.newZmxBinding(sourcePanelID: moved)?.endpoint == endpoint)
        for id in Array(source.panels.keys) { _ = source.closePanel(id, force: true) }
        for id in Array(destination.panels.keys) { _ = destination.closePanel(id, force: true) }
    }

    @Test func dockTabsSplitsAndRestorePreserveMovedZmxMappings() throws {
        let workspace = Workspace(title: "source", initialTerminalCommand: "/usr/bin/true")
        let endpoint = try RemoteZmxEndpoint(destination: "dock.example.test")
        let terminal = try #require(workspace.panels.values.first as? TerminalPanel)
        workspace.adoptZmxBinding(try RemoteZmxBinding(endpoint: endpoint, session: "dock-existing"), panel: terminal)
        let transfer = try #require(workspace.detachSurface(panelId: terminal.id))
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        dock.ensureLoaded()
        let pane = try #require(dock.bonsplitController.allPaneIds.first)
        let movedID = try #require(dock.attachDetachedSurface(transfer, inPane: pane, focus: false))
        let tabID = try #require(dock.newSurface(kind: .terminal, inPane: pane, sourcePanelId: movedID, focus: false))
        let splitID = try #require(dock.newSplit(kind: .terminal, orientation: .horizontal,
            insertFirst: false, sourcePanelId: movedID, focus: false))
        let bindings = [movedID, tabID, splitID].compactMap { (dock.panels[$0] as? TerminalPanel)?.remoteZmxBinding }
        #expect(Set(bindings).count == 3)
        #expect(bindings.allSatisfy { $0.endpoint == endpoint })
        #expect(!dock.dockPanelNeedsConfirmClose(terminal))
        let saved = dock.sessionSnapshot(includeScrollback: false)
        let restored = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        restored.restoreSessionSnapshot(saved)
        #expect(Set(restored.panels.values.compactMap { ($0 as? TerminalPanel)?.remoteZmxBinding }) == Set(bindings))
        #expect(restored.bonsplitController.allPaneIds.count == dock.bonsplitController.allPaneIds.count)
        let previousTab = try #require(dock.surfaceId(forPanelId: movedID))
        dock.focusPanel(tabID)
        #expect(dock.focusedPanelId != movedID)
        let revived = try #require(dock.respawnZmxPanel(panelID: movedID))
        #expect(revived.surface.debugBackgroundSurfaceStartQueuedForTesting())
        #expect(revived.id == movedID)
        #expect(revived.stableSurfaceId == terminal.stableSurfaceId)
        #expect(revived.remoteZmxBinding == bindings.first)
        #expect(dock.surfaceId(forPanelId: movedID) == previousTab)
        #expect(Set(dock.panels.values.compactMap { ($0 as? TerminalPanel)?.remoteZmxBinding }) == Set(bindings))
        dock.closeAllPanels()
        restored.closeAllPanels()
        for id in Array(workspace.panels.keys) { _ = workspace.closePanel(id, force: true) }
    }
}

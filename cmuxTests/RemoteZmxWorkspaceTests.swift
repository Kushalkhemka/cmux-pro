import Bonsplit
import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor @Suite(.serialized)
struct RemoteZmxWorkspaceTests {
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
        dock.closeAllPanels()
        restored.closeAllPanels()
        for id in Array(workspace.panels.keys) { _ = workspace.closePanel(id, force: true) }
    }
}

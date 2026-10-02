import CmuxCore
import Bonsplit
import Foundation

extension Workspace {
    /// Uses the source terminal's endpoint after a move, otherwise the workspace's endpoint.
    func newZmxBinding(sourcePanelID: UUID?) -> RemoteZmxBinding? {
        guard let endpoint = sourcePanelID.flatMap({ terminalPanel(for: $0)?.remoteZmxBinding?.endpoint })
            ?? remoteZmxEndpoint else { return nil }
        return RemoteZmxLaunch.newBinding(endpoint: endpoint, scopeID: stableId)
    }

    func adoptZmxBinding(_ binding: RemoteZmxBinding, panel: TerminalPanel, setTitle: Bool = true) {
        panel.remoteZmxBinding = binding
        trackRemoteTerminalSurface(panel.id)
        panel.surface.requestBackgroundSurfaceStartIfNeeded()
        if setTitle { _ = setPanelCustomTitle(panelId: panel.id, title: binding.session, source: .auto) }
    }

    /// Reattaches the persistent process while retaining native panel and tab identity.
    @discardableResult
    func reattachZmxPanel(panelID: UUID, create: Bool = false, focus: Bool? = nil) -> TerminalPanel? {
        guard let binding = terminalPanel(for: panelID)?.remoteZmxBinding,
              let replacement = respawnTerminalSurface(panelId: panelID,
                  command: RemoteZmxLaunch.command(binding, create: create), focus: focus,
                  waitAfterCommand: true, allowTextBoxFocusDefault: focus == true) else { return nil }
        adoptZmxBinding(binding, panel: replacement, setTitle: false)
        return replacement
    }

    /// zmx supplies screen/scrollback state itself; local replay and agent resume must not run too.
    func restoreZmxPanel(_ snapshot: SessionPanelSnapshot, inPane pane: PaneID) -> UUID? {
        guard let binding = snapshot.terminal?.remoteZmxBinding else { return nil }
        let surfaceID = GhosttyApp.terminalSurfaceRegistry.surface(id: snapshot.id) == nil ? snapshot.id : UUID()
        guard let panel = newTerminalSurface(inPane: pane, focus: false,
            autoRefreshMetadata: false,
            suppressWorkspaceRemoteStartupCommand: true, restoredSurfaceId: surfaceID,
            terminalFontSizeCreationPolicy: .sessionRestore(overrideBasePoints: snapshot.terminal?.fontSize,
                representedChangeTokens: Set(snapshot.terminal?.fontSizeChangeTokens ?? [])),
            remoteZmxBinding: binding) else { return nil }
        adoptZmxBinding(binding, panel: panel, setTitle: false)
        panel.restoreExplicitInputState(snapshot.terminal?.hasReceivedExplicitInput ?? false)
        panel.restoreSessionTextBoxDraft(snapshot.terminal?.textBoxDraft)
        return panel.id
    }
}

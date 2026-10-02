# Remote zmx sessions

`cmux ssh-zmx <SSH alias or user@host>` discovers zmx sessions on a remote
machine. When run inside cmux, it adds terminal tabs to the caller’s workspace
and pane, keeping the terminal that ran the command. Outside cmux, it opens
or reuses a native workspace for that endpoint. Each session is a terminal tab. cmux owns the tabs, splits, titles, pinning, order, and focus;
zmx owns each shell's persistent process and terminal state.

```sh
cmux ssh-zmx dev
cmux ssh-zmx dev --session agent-one
cmux ssh-zmx dev --session agent-two --create
cmux ssh-zmx dev --list
cmux ssh-zmx dev --workspace workspace:2
cmux --json ssh-zmx dev
```

An empty host starts one independently named session. New terminal tabs and
splits create independent zmx sessions on the same endpoint. Closing a tab,
workspace, or window detaches its SSH client; it does not kill the session.
Commands and working directories supplied for new terminal tabs or splits apply
on the remote machine. They are used only for initial creation; reconnect and
restore reattach the existing process without rerunning its command.
Moving a terminal preserves its mapping. Renaming a native tab or workspace
changes its local title; zmx session names stay unchanged.

cmux's session snapshot saves the endpoint and per-terminal session name along
with its normal layout. Relaunch reconnects the saved terminals. zmx restores
the running process and screen; cmux does not replay stale local scrollback or
launch a second copy of an agent. A missing saved session is reported and is
not deliberately recreated. Explicitly use `--session NAME --create` to create
it again. Repeat `ssh-zmx` to discover new sessions or reattach ended clients;
live mappings in the destination workspace are reused. A mapping in another
workspace keeps its layout; the caller’s workspace gets its own local view of
the same remote process. This does not create another remote session.
`--workspace` explicitly selects a destination. `--new-window` bypasses the
caller’s workspace and uses the endpoint’s separate mapping window.

SSH transport failures reconnect with backoff from one to fifteen seconds.
Successful detach, a shell exiting, and remote command errors stop the loop.
The terminal remains open to show the result. A manual terminal respawn with
no command reconnects its saved zmx session. Supplying a replacement command or
working directory to respawn is rejected; use a new terminal tab or split to
start another remote process.

## SSH and namespaces

The feature uses the normal SSH configuration, host-key checks, and identities.
Discovery uses cmux's SSH ControlMaster transport machinery with a separate zmx
socket namespace, so its cleanup does not close tmux masters. Each terminal
uses an independent SSH connection and remote zmx daemon, avoiding the shared
master's session limit and traffic contention. Key or SSH-agent authentication
is best for many terminals; password and hardware-key authentication may prompt
for each independent connection. Input and resize use the native terminal PTY
path rather than tmux's control-mode protocol.

```sh
cmux ssh-zmx dev --port 2222 --identity ~/.ssh/dev_key
cmux ssh-zmx dev --zmx-path /opt/zmx/bin/zmx --zmx-dir /run/user/1000/zmx
cmux ssh-zmx dev --name "VM agents" --new-window --no-focus
```

Install [zmx](https://github.com/neurosnap/zmx) on the remote machine first.
The remote PATH includes `$HOME/.local/bin`. `--zmx-path` accepts `zmx` or an
absolute remote path. `--zmx-dir` is an absolute remote socket directory and
is part of the mapping identity. Discovery and attach clear inherited
`ZMX_SESSION` and `ZMX_SESSION_PREFIX` so names address the same namespace and
attachment cannot switch an unrelated inherited client.

## Socket API

The local v2 methods are `remote.zmx.sessions`, `remote.zmx.mirror`, and
`remote.zmx.window`. They take `host`, optional `port`, `identity_file`,
`zmx_path`, and `zmx_dir`. Mirror/window also accept `session`, `create`,
`activate`, `workspace_name`, and window routing. `remote.zmx.mirror` uses
`workspace_id` as the destination and `surface_id` to select the caller’s pane.
With `caller_context: true`, the surface’s current owner takes precedence over a
stale shell workspace ID after a tab move. Explicit CLI `--workspace` skips
caller inference. A Dock caller maps into its owning main workspace; a window
Dock uses the selected workspace of that Dock’s window. A closed explicit destination causes an error rather than
routing to another workspace.
`create` applies only to an explicitly requested session. Mirror responses
include session names, workspace IDs, and surface IDs.

These methods are unavailable through a remote CLI relay because they launch
SSH on the Mac. Arbitrary imported session files have their zmx mappings
removed; trusted saves from this installation retain them. Managed policy
disabling remote connections also prevents zmx startup.

## Scope

zmx supplies no remote windows or split tree to mirror. The native cmux layout
is therefore the saved source of truth. Discovery is explicit; rerunning the
command adds new sessions without rearranging existing tabs. Existing tmux
processes are not migrated to zmx. Run each independently displayed agent in
its own zmx session to avoid sharing a single multiplexer daemon.

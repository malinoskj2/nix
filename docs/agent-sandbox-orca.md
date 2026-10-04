# Orca terminals in an agent sandbox

In a local Orca worktree, launch an agent in an existing named sandbox with:

```sh
agent-sandbox-exec sandbox-skintrader codex
agent-sandbox-exec sandbox-skintrader claude
```

The first argument is the suffix of the `agent-sandbox@<suffix>.service` user
unit. The command starts that unit if necessary, waits for its container, and
executes the agent in the current worktree path. Orca's pane, worktree, terminal,
launch-token, and hook environment travels with the agent process. Further
arguments go to the selected agent.

The sandbox image uses the desktop `orca-ide` CLI. A read-only bind of
`~/.config/orca` gives it the live runtime metadata and Unix socket, so Orca
commands can reach the desktop without the SSH relay. This mount is available
after the named sandbox is recreated with the updated image; existing running
containers retain their previous mounts and CLI.

For each agent launch, the command opens a private Unix socket under
`/run/user/$UID/agent-sandbox-orca`, which is bind mounted into the sandbox.
The host proxy forwards only to Orca's current `127.0.0.1` hook port; it reads
the endpoint file for each connection so an Orca restart can change that port.
The agent's curl shim sends only Orca hook URLs through this socket. Other
requests use normal curl. Orca's hook token still authenticates each event.
The socket and proxy are removed when the agent exits. Hook files are seeded
into the sandbox if missing, and Codex's hook trust entries are added without
replacing other sandbox configuration.

The bridge was checked from an isolated Docker container against the live
Orca listener. An unsigned request received HTTP 403, and a signed Codex
`SessionStart` event from a test agent pane received HTTP 204 and appeared in
Orca's persisted status. A separate test confirmed the proxy follows an
endpoint port change.

The direct launch remains experimental. The local Orca process cannot see the
agent process or its sandbox session files. Agent recognition, session history,
and resume need verification and further integration before this replaces the
SSH setup.

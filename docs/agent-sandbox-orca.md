# Orca terminals in an agent sandbox

In a local Orca worktree, launch an agent in an existing named sandbox with:

```sh
agent-sandbox-exec sandbox-skintrader codex
agent-sandbox-exec sandbox-skintrader claude
agent-sandbox-exec sandbox-skintrader zcode
agent-sandbox-exec sandbox-skintrader muse
```

The first argument names the sandbox, the suffix of the
`agent-sandbox@<suffix>.service` user unit that the SSH helper still uses for
its long-lived container. Every invocation creates its own fresh instance of
that sandbox: a new container from the sandbox image, named
`agent-sandbox-<suffix>-h<id>`, with the agent as the container's main
process. Harnesses on one service never share a runtime, the container lives
exactly as long as its harness, so the last harness to quit takes its whole
instance down, and a later launch starts from a fresh container. Only state
mapped from the host carries over between instances: the persistent sandbox
home, the shared project directories and the other bind mounts. The
container's writable layer, its `/tmp` and any Docker volumes are discarded
when it stops. Orca's pane, worktree, terminal, launch-token, and hook
environment travels with the agent process. Further arguments go to the
selected agent.

The sandbox image uses the desktop `orca-ide` CLI. A read-only bind of
`~/.config/orca` gives it the live runtime metadata and Unix socket, so Orca
commands can reach the desktop without the SSH relay.

For each agent launch, the command opens a private Unix socket under
`/run/user/$UID/agent-sandbox-orca`, which is bind mounted into the sandbox.
The host proxy forwards only to Orca's current `127.0.0.1` hook port; it reads
the endpoint file for each connection so an Orca restart can change that port.
The agent's curl shim sends only Orca hook URLs through this socket. Other
requests use normal curl. Orca's hook token still authenticates each event.
The socket and proxy are removed when the agent exits. Each direct launch syncs
Orca's managed hook scripts and settings into the sandbox, including changes
from an Orca update. Codex's managed hook trust hashes are refreshed while
preserving other sandbox configuration and per-hook enabled choices.

The bridge was checked from an isolated Docker container against the live
Orca listener. An unsigned request received HTTP 403, and a signed Codex
`SessionStart` event from a test agent pane received HTTP 204 and appeared in
Orca's persisted status. A separate test confirmed the proxy follows an
endpoint port change.

The direct launch remains experimental. The local Orca process cannot see the
agent process or its sandbox session files. Agent recognition, session history,
and resume need verification and further integration before this replaces the
SSH setup.

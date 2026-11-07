# Orca terminals in an agent sandbox

On `home`, the Nix-built Orca configures the Claude, Codex and Muse launch
buttons to use a sandbox command. Linux launches use `agent-sandbox-exec`.
On Darwin execution hosts, the command searches `PATH` in order and invokes
the first executable file matching `sandbox-*`, passing the harness name
(`claude`, `codex` or `muse`) followed by Orca's launch arguments. Matches
within a PATH directory follow shell glob order. If no matching executable
exists, the launch fails with an error. Restart Orca after rebuilding to
load these overrides.

From a repository or a local Orca worktree, launch an agent with:

```sh
agent-sandbox-exec codex
agent-sandbox-exec claude
agent-sandbox-exec muse
```

The sandbox name is derived from the Git repository name: `j2bar` becomes
`sandbox-j2bar`. This works from subdirectories, and linked worktrees use the
main repository's name. Run the command inside a Git repository. The Zsh
alias also lets you use `sandbox codex`, for example.

The sandbox name is the suffix of the `agent-sandbox@<suffix>.service` user
unit that the SSH helper still uses for its long-lived container.
Every invocation creates its own fresh instance of
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

Each container also publishes sandbox ports `8080` through `8084` on five
available host loopback ports, starting the search at `18080`. Agents choose an
unused port from `$AGENT_PREVIEW_PORTS` and bind the server to `0.0.0.0`.
`AGENT_PREVIEW_URL_8080` through `AGENT_PREVIEW_URL_8084` give the corresponding
host URLs for links opened in Orca's host-side browser or a host browser. Browser
checks inside the sandbox use the sandbox port instead. These links work only
while the preview server and its container are running. After rebuilding the
config, start a new sandbox to pick up the mappings.

Orca saves local clipboard image pastes under `/tmp/agent-media`, which is
shared with the sandbox at the same path. The sandbox's private `/tmp` cannot
read host files saved directly there. This is separate from the host image
clipboard mirror, which makes image data available to Wayland clients inside
the sandbox. After updating Orca, restart the desktop app for the paste path
change to take effect; existing sandboxes already mount the media directory.

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

## Container indicators

The Nix-built Orca carries `terminal-container-indicators.patch`. Each running
container reports its instance name over OSC 777 (`orca-container;name=...`)
from its entrypoint, after setup. The host launcher sends `orca-container;clear`
when it exits, including failed launches. The report travels with that terminal's
output, so another terminal in the same worktree never inherits the badge.

Orca shows a box icon beside that agent's sidebar row, in its terminal tab and
in its pane header. Hovering gives the container name. A tab with split panes
shows a layers icon when its reported environments differ or only some panes
have reported containers. A pane without a report has no container icon; this
does not claim it is running on the host. These are launcher lifecycle reports,
not checks of Claude or Codex permission settings.

Reports survive title changes and renderer reattachment while the owning Orca
runtime remains alive. The patched terminal daemon forwards reports even when
hidden terminal output is thinned. PTY exit drops the renderer's report. Restart
Orca and start fresh agent terminals after rebuilding; existing containers and
unpatched execution hosts do not supply this integration. The direct Linux
`agent-sandbox-exec` launcher is instrumented; other launchers need to emit the
same start/clear reports to show a badge.

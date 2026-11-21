# Orca terminals in an agent sandbox

On `home`, the Nix-built Orca configures the Claude, Codex and
Antigravity launch buttons to use a sandbox command. Linux launches use `agent-sandbox-exec`.
On Darwin execution hosts, the command searches `PATH` in order and invokes
the first executable file matching `sandbox-*`, passing the harness name
(`claude`, `codex` or `antigravity`) followed by Orca's launch
arguments. Matches
within a PATH directory follow shell glob order. If no matching executable
exists, the launch fails with an error. Restart Orca after rebuilding to
load these overrides.

Native Chat sessions show a box icon and **Sandbox** label on their chat tab,
worktree agent row and dashboard row when their recorded launch used the declared
sandbox command. This labels the session's launch route, independently of its
permission mode and the workspace's host. It is not a container health indicator.
The launch choice is saved on reservation and retained across reconnects and
operation replays; a new owner records its new launch choice. Older sessions with
no launch provenance stay unlabelled until their next launch or resume after
rebuilding and restarting Orca. Terminal sessions use their existing live container
reports instead.

From a repository or a local Orca worktree, launch an agent with:

```sh
agent-sandbox-exec codex
agent-sandbox-exec claude
agent-sandbox-exec antigravity   # or agy
```

The sandbox name is derived from the Git repository name: `j2bar` becomes
`sandbox-j2bar`. This works from subdirectories, and linked worktrees use the
main repository's name. Run the command inside a Git repository. The Zsh
alias also lets you use `sandbox codex`, for example.

Sandboxes start without their headless displays. `agent-sandbox-exec --display
claude` (or `sandbox --display claude`) brings up sway and the nested Hyprland
at startup; otherwise agents start them with `sandbox-display up` when a task
needs one.

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
when it stops.

The persistent home doesn't keep everything. `agent-sandbox-clean` deletes it
all except the agent and Steam logins, `.ssh`, `.orca-relay`, Steam's own
directory, sccache and the Unreal shader cache, and empties the sandboxes'
`/tmp` root. It refuses while a sandbox is running, apart from the shared Codex
server, which it stops. The `agent-sandbox-clean` user timer runs it hourly
once a week has passed since the last clean, so it lands at the first idle
hour. `agent-sandbox-kill --clean` stops every sandbox and cleans straight
away.

Orca's pane, worktree, terminal, launch-token, and hook
environment travels with the agent process. Further arguments go to the
selected agent.

Each container also publishes sandbox ports `8080` through `8084` on five
available host ports, starting the search at `18080`. They are published on
every interface, so any device on the LAN can open a running preview without
signing in. Agents choose an unused port from `$AGENT_PREVIEW_PORTS` and bind
the server to `0.0.0.0`. `AGENT_PREVIEW_URL_8080` through
`AGENT_PREVIEW_URL_8084` give the corresponding URLs on the host's LAN address,
found from its default route when the sandbox starts, or on `127.0.0.1` when
there is none. The same URLs open in a host browser, Orca's host-side browser,
the sandbox's browser and on other devices. For the loopback fallback, the
entrypoint forwards each host port to its sandbox port on the container's
loopback with `socat`. These links work only
while the preview server and its container are running. After rebuilding the
config, start a new sandbox to pick up the mappings.

Orca saves local clipboard image pastes under `/tmp/agent-media`, which is
shared with the sandbox at the same path. The sandbox's private `/tmp` cannot
read host files saved directly there. This is separate from the host image
clipboard mirror, which makes image data available to Wayland clients inside
the sandbox. After updating Orca, restart the desktop app for the paste path
change to take effect; existing sandboxes already mount the media directory.

Agent-generated screenshots, recordings and other development captures go in the
current repository or worktree root's globally Git-ignored `.tmp/` directory.
Repository mounts already share these files at the same absolute host paths.

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
preserving other sandbox configuration and per-hook enabled choices. Orca's
`~/.gemini/config/hooks.json` for Antigravity is copied as it is, and the
workspaces Orca pre-trusts in the host's agy `settings.json` are added to the
sandbox's, so agy's trust menu can't swallow a drafted prompt.

The bridge was checked from an isolated Docker container against the live
Orca listener. An unsigned request received HTTP 403, and a signed Codex
`SessionStart` event from a test agent pane received HTTP 204 and appeared in
Orca's persisted status. A separate test confirmed the proxy follows an
endpoint port change.

The direct launch remains experimental. The local Orca process cannot see the
agent process directly. The hook bridge translates process IDs, in the header
and in the form field Antigravity's hook posts, and Codex and Antigravity
transcript paths to their host locations. Orca reads the first record of agy's
transcript to tell the root conversation it resumes from a subagent's, so
without that translation a sandboxed agy session would have no resume ID. The Nix-built Orca also recognizes
`~/.local/share/agent-sandbox/home/.codex` as a local account home for history,
resume and **Continue in chat**. Usage Insights' `extraCodexFolders` setting is
separate and does not register an account home with Orca.

After rebuilding, restart Orca to load the recognized account home. Existing
terminal sessions with host-translated transcript paths can then continue in
Chat without copying or moving their history. Chat passes that account's
`CODEX_HOME` through the launcher, which mounts it writable at the same absolute
host path. Older sessions still reporting the container's `~/.codex` path need
to be resumed in a terminal with the current launcher first.

## Prompt cache in child worktrees

Workers in child Orca worktrees are short-lived, so the sandbox's `claude`
wrapper gives them Claude Code's 5-minute prompt cache instead of the 1-hour
cache a subscription gets automatically. When Orca's session, terminal or pane
environment is present, it runs `orca-ide worktree current --json` in the
launch directory, and if the worktree has a `parentWorktreeId` it prepends
`--settings '{"promptCacheTtl":"5m"}'`. Top-level cards, the main checkout,
directories outside Orca and launches without Orca's environment keep the
automatic choice, and a `CLAUDE_CODE_PROMPT_CACHE_TTL` in the environment still
wins. The lookup has a 3-second limit and is skipped on failure. Orca launches
on hosts without the sandbox command run plain `claude` and keep the automatic
TTL. A running session keeps the TTL it started with until it is relaunched or
resumed.

Codex and Antigravity have no setting for this. Codex sends no prompt
cache lifetime unless a turn asks for its longer `30m` or `12h` options, which
nothing in its CLI or config requests, so it already gets the API's default.

## Chat interface

Codex and Claude can use Orca's **Chat** interface with the same sandbox launch
commands as the CLI interface. The Nix-built Orca accepts the exact declarative
command as a program and argument vector, including its quoted shell script.
Edited commands still use Orca's normal literal-command validation. Rebuild and
restart Orca to pick up `structured-sandbox-launch.patch`.

Chat's Codex app-server and Claude stream-json protocols use pipes, without a
TTY. Sandbox setup writes diagnostics to stderr and reserves stdout for the
agent protocol. Chat launches pass the sealed Orca session identity and the
selected `CODEX_HOME` or `CLAUDE_CONFIG_DIR` into the container. That account
directory is mounted writable at the same absolute path so authentication,
transcripts and resume stay with the account Orca selected. The rest of Orca's
state remains read-only, except the per-chat scratch directory used for inline
artifacts. Claude's selected authentication environment is forwarded only to
Claude.

Model/account probes may run outside a Git repository. When they supply an
account directory, the launcher gives them a fresh `sandbox-codex-chat` or
`sandbox-claude-chat` instance; it never falls back to running the agent on the
host. Closing or cancelling the provider process removes its container.
Container badges remain a terminal integration; Chat does not receive terminal
escape sequences.

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

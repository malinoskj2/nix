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
main repository's name. Run the command inside a Git repository, or in an
Orca bot's home: a bot in `~/.orca/bots/elma` runs in `sandbox-bot-elma`, for
every agent and probe, with its home writable and the same project mounts as
any other sandbox. Bot homes are recognized by their resolved path, so a
symlink into one works and a symlink out of one is refused. Orca's resumes of
a bot's sessions go back to its sandbox whatever account Orca selected. Only
the bots listed in `pkgs/agent-sandbox/host-bots.nix`, Tohru, run and resume
on the host. The Zsh
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
host ports that stay with the sandbox's identity across restarts: the bot for
a bot's sandbox, the worktree for one started in a Git repository, the chat
account sandbox, or the instance name. `agent-sandbox-preview-ports` gives each
identity a block from `19000` to `20999`, picked from its hash and moved to the
next free block on a collision, and records it in
`~/.local/share/agent-sandbox/preview-ports`; a removed worktree gives its
block back. When the block is in use, such as by a second sandbox of the same
worktree, that launch searches for free ports from `18080` instead, as
disposable siblings always do. They are published on
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
config, start a new sandbox to pick up the mappings. When
`bot-sandbox-refresh` restarts a bot's sandbox, it mails the bot an Orca status
message saying its running servers and `/tmp` are gone, with its preview URLs.

Orca saves local clipboard image pastes under `/tmp/agent-media`, which is
shared with the sandbox at the same path. The sandbox's private `/tmp` cannot
read host files saved directly there. Sandboxes get no other view of the
host's clipboard, display or screenshots. After updating Orca, restart the desktop app for the paste path
change to take effect; existing sandboxes already mount the media directory.

Agent-generated screenshots, recordings and other development captures go in the
current repository or worktree root's globally Git-ignored `.tmp/` directory.
Repository mounts already share these files at the same absolute host paths.

## Orca runtime access

The sandbox image uses the desktop `orca-ide` CLI, but a sandbox never sees
Orca's profile, its runtime token, its session database or its Electron state.
Each launcher starts `agent-sandbox-orca-relay` on the host, in a private
directory under `/run/user/$UID/agent-sandbox-orca-relay`. The container gets
that directory's profile, read-only, at Orca's own path (`$ORCA_USER_DATA_PATH`,
normally `~/.config/orca`). It holds an `orca-runtime.json` naming the relay's
socket with a placeholder token, and Orca's CLI shim, both refreshed every
second from the desktop's, so an Orca restart or update reaches running
sandboxes. Chat's attachment and paste folders are mounted read-only beside
them, and a Chat's scratch directory and pinned account home writable at their
own paths.

The relay reads the desktop's `orca-runtime.json` for each connection and
streams Orca's answers back, keepalives included. It doesn't pass requests
through. It builds each request it forwards from scratch:

- the request's ID, method, contract version and invocation IDs;
- params that match the method's reviewed list, with nothing the list leaves out;
- the real token;
- caller evidence naming this sandbox.

That evidence comes from the `ORCA_AGENT_SESSION_ID`, `ORCA_TERMINAL_HANDLE`,
`ORCA_PANE_KEY` and `ORCA_AGENT_LAUNCH_TOKEN` that Orca's launch gave the
launcher on the host. A request whose own evidence or caller params (`--from`,
`--terminal`, the pane key, the caller session) name anyone else is refused,
and so is any request carrying a paired Orca's Run or another execution host. A
sandbox started without an Orca session can read listings but can't act as
anyone.

Every method has its own entry. A method missing from the list, including any
method a later Orca adds, is refused with a `forbidden` error the CLI prints, and so
is a known method carrying a parameter its entry doesn't list:

| Allowed | Refused |
| --- | --- |
| `status`, repo, worktree, project and bot listings, `worktree current`, `skills get` | Settings, accounts, pairing, plugins, automations, skill installs, SSH hosts and updates |
| `worktree create`, without a startup command, startup environment or setup script | `terminal create`, `send`, `split`, `list` and `close`; `agent list`; session listings and transcripts |
| `worktree set`, `activate` and `rm` on the sandbox's own worktree and its descendants | Every other worktree |
| `terminal show`, `read` and `wait`, and titles, on the sandbox's own terminal and its workers' | Every other terminal |
| Mail (`check`, `send`, `ask`, `reply`, `inbox`) as the sandbox itself; Runs, Tasks and gates it coordinates | `orchestration dispatch`, `reset` and `run-list`; typing into a worker's terminal; peer methods; `send --file` |
| `worker-start`, `worker-show`, `read`, `transcript`, `stop`, `release`, `retain` and `abandon` on its own and its workers' Dispatches | Any other Dispatch, active or finished |
| Opening, navigating, listing and closing its own preview tabs in Orca's browser | Reading, scripting or clicking any page; cookies, profiles, uploads; every other tab |
| A bot's own chats, items, memory and replies, in that bot's sandbox | Other bots; connector sign-in and keys; Google; file attachments |

Ownership is read from Orca's orchestration database, which the relay opens
read-only on the host:

- A root coordinator owns every Dispatch in the Runs it coordinates.
- A worker owns its own Dispatch and the Dispatches it created, and so on
  through its workers' workers.
- Owned Tasks and terminals are those Dispatches' Tasks and terminals.
- Owned worktrees are the sandbox's own worktree, its workers' worktrees, and
  any worktree whose chain of parents reaches one of them.

`worker-list` and `task-list` answers keep only owned entries, and `inbox` is
always this sandbox's own. If the database can't be read, every
ownership-checked call is refused.

Some allowed calls are narrowed on the way:

- Workers and worktree agents start only as Claude, Codex, Antigravity or
  OpenCode, the agents Orca launches in a sandbox. A `worker-start` without
  `--agent` starts the sandbox's own agent.
- New worktrees skip setup scripts, and `worktree rm` skips archive hooks,
  since a repository's committed `orca.yaml` would otherwise run on the host.

Orca's browser is there for one job: showing the human a sandbox's preview.
`tab create` and `goto` take only this sandbox's `$AGENT_PREVIEW_URL_*`
addresses. `goto` and `tab close` must name, with `--page`, a tab the sandbox
opened; without one Orca would act on the user's current tab. Tabs open in an
isolated profile, *Agent sandbox previews*, with no sign-ins; the relay creates
it once with Orca's own profile call. Every command that reads or drives a page
is refused, since the relay can't hold an open page to its origin. Agents test
pages with the Chromium and Playwright in their sandbox.

The relay checks only the address a tab opens at. A served preview page can
still redirect itself, or be clicked through, to any other site; it gets there
with the isolated profile's empty cookie jar, never the user's.

### What sandboxed agents can't do through Orca

These are deliberate limits, not faults:

- Google: every `google.*` method (Gmail, Calendar, Drive, Docs, Sheets,
  contacts) is refused, for bots too.
- Bot and mail attachments: `orchestration send --file`, and files on bot
  item writes and comments, are refused, since Orca would read those paths on
  the host. Text-only items, comments and replies work.
- Browser inspection: snapshots, screenshots, `eval`, clicks, typing, console
  and network reads, cookies, profiles, uploads and the current tab are all
  refused. Only the preview tabs above can be opened, navigated, listed and closed.
- Listings of other agents: `terminal list`, `agent list`, session listings
  and transcripts, `run-list` and other parties' inboxes.

`settings.get` is refused, so `skills get` leaves out the artifact-publishing
part of its guides even when artifact sharing is on.

Orca's WebSocket transport (`ws://0.0.0.0:6768`) answers only paired devices'
tokens, so without the runtime token or a pairing a sandbox can't use it, and
the launcher no longer forwards `ORCA_PAIRING_CODE` or `ORCA_REMOTE_PAIRING`.
The relay's log is `relay.log` in its directory; it names each method and every
refusal, never parameters.

For each agent launch, the command opens a private Unix socket in its own
directory, `/run/user/$UID/agent-sandbox-orca/session.*`. That directory, and
no other launch's, is bind-mounted into the sandbox. The launcher refuses a
socket path outside such a directory.
The host proxy forwards only to Orca's current `127.0.0.1` hook port and puts
Orca's current hook token on each event; it reads the endpoint file for each
connection, since an Orca restart changes both.
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

### Open risks

These aren't closed yet:

- **SSH workspaces.** A sandbox reached over SSH talks to Orca through the
  remote's own bridge in `~/.orca-relay`, which this relay doesn't cover.
  Closing it needs the same scoped relay on the SSH side, or the bridge
  pinned to one sandbox's identity and method list.
- **Repository configuration that host agents load.** Orca runs some agents on
  the host for its own features, such as a bot's tool sign-in with
  `claude mcp login` in the bot's folder. Those agents load `.claude/` settings,
  hooks and `.mcp.json` from that folder, and a sandbox can write them in any
  repository or bot home it mounts read-write. Closing it needs those host
  runs to ignore project settings (`--setting-sources user` and no project MCP),
  or to run in a sandbox too.
- **Ownership by terminal handle.** Orca records who created a Dispatch by
  terminal handle. A handle reused by a later, unrelated Dispatch would carry
  the earlier owner's rights over Dispatches it then creates. Orca issues new
  handles per session, so this needs a reused retained terminal.

## Orca's own Git on the host

Orca runs Git on the desktop, as jesse, in every repository and worktree it
shows: status and diff polling, commits, worktree creation and removal, pull,
clone, fetch and push. Sandboxes can write those repositories' `.git/config`,
`.git/info/attributes`, worktree config and `.gitattributes`, and plain Git
runs programs they name. Orca's `git`, `gh` and `glab` calls therefore go
through a wrapper (`pkgs/orca-ade/host-git.sh`, selected by
`ORCA_HOST_GIT_PATH`). `gh` and `glab` find it as `git` on their PATH, so the
Git they run is covered too.

The wrapper never reads repository config to decide what to override: a
sandbox can change it between the wrapper's read and Git's own. Instead every
call gets the same protections, from system, global and Orca's command-line
config only.

- **Pinned programs.** `core.fsmonitor=false`, `core.pager=cat`, no
  `core.alternateRefsCommand`, and the global value or Git's default for
  `core.askPass`, `core.sshCommand` and every `gpg.*` program. Credential
  helpers, URL-scoped ones included, are emptied and only the system and
  global helpers are added back. Editors are `:`, and `diff`, `log` and `show`
  get `--no-ext-diff`.
- **Transports.** On the host, Git may only use `https`, `http` and `ssh`
  (`GIT_ALLOW_PROTOCOL`), so a remote helper the repository selects with
  `remote.*.vcs` or a `<transport>::<address>` URL, `ext::`, and local
  transports that would run `uploadpack` are all refused, whatever
  `protocol.*.allow` says.
- **Only what needs the network or the credential helpers runs on the host:**
  fetch, push, ls-remote, credential, `remote update`/`prune`/`show`/`set-head`,
  `version`, and the host halves of pull, clone, `remote add -f` and
  `worktree add`. So does `worktree list`, which only reads the
  administrative files and would show every worktree outside the repository
  as prunable from the jail. None of them reads attributes, runs a diff
  driver or formats commits. Help never
  runs on the host: any `--help`, `--man`, `--web` or `--info` sends the call
  to the jail, since help starts the repository's `man.<tool>.cmd` or
  `browser.<tool>.cmd`. Host commands run with every repository hook switched
  off: `core.hooksPath` is the global value or
  `/dev/null`, and `hook.<event>.enabled=false` for every event. That needs
  Git 2.56, so the wrapper uses `pkgs.unstable.git`. No command, on the host
  or in the jail, starts automatic housekeeping (`gc.auto=0`,
  `maintenance.auto=false`): on the host gc and prune run
  `gc.recentObjectsHook`, a list that a command-line value can't empty, and
  in the jail gc prunes worktrees it can't see. Alternates are listed with `core.alternateRefsCommand=true`.
- **Pushes** run only the `pre-push` hooks that system and global config
  name, such as the Betterleaks scan, from a hooks directory in the store,
  plus the global `core.hooksPath`'s `pre-push` if one is set. The repository
  can't change, disable or add to them.
- **Everything else** (status, diff, log, show, reflog, rev-list, rev-parse,
  config, branch, tag, add, commit, checkout, merge, rebase, stash, prune,
  repack, `pack-refs`, `multi-pack-index`, worktrees, `cat-file`, help, and any command the wrapper
  doesn't know) runs in a bubblewrap jail. Outside a repository, a directory
  that is or contains the home directory isn't bound, so global config still
  reads there. Filters,
  diff and merge drivers, fsmonitor and hooks still run there, but with no
  network, an empty read-only `/home`, `$HOME`, `/run` and `/mnt`, an empty
  `/tmp`, a cleared environment, and only the repository's work tree and Git
  directories writable, so they reach nothing a sandbox can't already reach.
  A write anywhere else fails instead of vanishing with the jail. Global Git
  config and the global excludes and attributes files are visible read-only.
- **Pull, clone and `worktree add`** are split: the fetch, or the clone or
  worktree without a checkout, runs on the host, then the merge
  (`pull . <fetched ref>`) or the checkout runs in the jail. A new worktree
  stays locked until its checkout is done, as with Git's own `worktree add`.
- **`worktree prune` does nothing** and succeeds, with a note on stderr. On
  the host, Git's prune deletes inside whatever an administrative directory
  under `worktrees/` links to. In the jail, a worktree outside the repository
  that moves or is still being added looks deleted. `gc` and `maintenance`,
  whatever their tasks, do nothing the same way, since both prune worktrees,
  and in the jail even `gc.worktreePruneExpire=never` doesn't keep a worktree
  without an index. Orca runs neither. Removing a
  worktree from Orca still deletes its own entry. `worktree move`, `remove`, `lock` and
  `unlock` bind the worktree's parent directory, and `repair` binds the
  worktrees it names.
- **`init <directory>`** creates the directory and runs from inside it, so the
  repository lands where Orca asked.
- **Exposed paths.** The jail only binds the work tree Git finds from Orca's
  directory without repository config: the nearest directory with a `.git`,
  or the work tree Orca passes. It also binds a Git directory inside that
  work tree, inside an enclosing `.git` (submodules), or a linked worktree's
  directory under the `worktrees/` of a common directory named `.git` or
  `*.git`. Anything else, such as a `core.worktree` or `gitdir:` pointing
  elsewhere, is refused, and so is any
  path that is or contains the home directory or Tohru's home. Each directory
  is opened and checked once, then bound by its descriptor, so swapping a
  path for a symlink afterwards changes nothing.
- **`push --no-verify`** is refused, like the Betterleaks push gate does for
  the PATH Git.

Terminals and the agents Orca starts aren't affected: their `git` is whatever
their shell finds. Orca on SSH and WSL hosts runs Git there, not through this
wrapper. The jail needs unprivileged user namespaces on the desktop; without
them those calls fail rather than run unconfined.

Limits:

- **Hooks and filters that need the network, the home directory or `/tmp`**
  fail in the jail: signed commits through a GPG agent, Git LFS downloads,
  hooks that call a server, alternates under `$HOME`, `commit -F` with a file
  in `/tmp`. Orca itself passes none of these. Use a terminal for those.
- **Repository hooks never run on host-side commands**, `pre-push` included,
  and a `post-checkout` hook sees the jail's checkout of `HEAD` rather than
  the worktree or clone that created it.
- **Worktrees directly in the home directory** can't be removed or moved
  from Orca, since that would expose the home directory.
- **`worktree repair` without paths** only repairs worktrees inside the
  repository.
- **Stale worktree entries** for worktrees deleted outside Orca stay in
  `.git/worktrees/` and show as `prunable` in `git worktree list`. Nothing
  prunes them automatically, nix-land included, and neither `gc` nor
  `maintenance` runs through Orca. Prune by hand in a host terminal, after
  stopping every sandbox and agent that can write the repository, since a
  writer could swap an entry for a symlink after the check: check that no
  entry is a symlink (`find .git/worktrees -maxdepth 1
  -type l` prints nothing), preview with `git worktree prune -n -v`, then run
  `git worktree prune`.
- **Writes outside the repository** fail: `config --global` changes,
  `init --separate-git-dir`, `init` in the home directory itself, and output
  files such as `archive -o ~/x.tar`.
- **Local remotes** (`file://` or a path) can't be fetched, pulled or cloned
  from Orca.
- **Remote URLs**, `insteadOf`, proxies and TLS settings in repository config
  still decide where Orca fetches and pushes, so a sandbox can redirect them,
  including the credentials a trusted helper sends there. Betterleaks still
  scans each push.
- A pull's merge commit names its source as the local repository.
- **Git you run yourself.** A `git status` you type on the host, in a
  repository a sandbox can write, gets none of this.

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
commands as the CLI interface. The declarative Command is
`~/.orca/nix/bin/orca-sandbox-launch orca-sandbox <agent>`, using Orca's native
literal executable and argv validation. Home Manager installs the portable
wrapper locally; the packaged orcad template installs it at that same
home-relative path on POSIX SSH hosts. The wrapper strips the provenance marker
and keeps the existing Darwin/Linux launcher selection and argument forwarding.
Automatic resume routing is unchanged.

Chat's Codex app-server and Claude stream-json protocols use pipes, without a
TTY. Sandbox setup writes diagnostics to stderr and reserves stdout for the
agent protocol. Chat launches pass the sealed Orca session identity and the
selected `CODEX_HOME` or `CLAUDE_CONFIG_DIR` into the container. That account
directory is mounted writable at the same absolute path so authentication,
transcripts and resume stay with the account Orca selected, and so is the
per-chat scratch directory used for inline artifacts. The rest of Orca's state
is not mounted (see [Orca runtime access](#orca-runtime-access)). Claude's selected authentication environment is forwarded only to
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

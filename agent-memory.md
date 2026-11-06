# Running many agents without running out of RAM

Research from 2026-10-31, based on web sources. Nothing here was tested
locally. Items marked _unverified_ come from one source or couldn't be
confirmed.

## Summary

- A healthy Claude Code process is small, about 0.3–0.9 GB RSS. An idle
  session averages about 167 MB, working sessions have a median of 238 MB
  and a p90 of about 1 GB.
- Memory runs out because of what the agents launch: builds and linkers,
  a full set of MCP servers per session, language servers, headless
  browsers, and leak regressions.
- So the number of heavy jobs running at once matters more than the number
  of agents.
- No orchestrator limits RAM per agent: claude-squad, Conductor, Crystal,
  uzi, vibe-kanban, Orca, Sculptor and container-use all start a full set
  of processes per worktree. The limits have to come from cgroups, locks
  and wrappers outside the tool.

## Actionable items, highest value first

| # | Action | Why it's worth it | Effort | Where it would go |
|---|--------|-------------------|--------|-------|
| 1 | Global build lock (`flock` on a shared path) enforced by a PreToolUse hook, with `cargo check` exempt | Cargo builds are what overflow the 20G limit; CLAUDE.md rules alone get ignored | Medium | `pkgs/agent-sandbox` (wrapper + hook) |
| 2 | Run builds as `choom -n 800 -- cargo …` | When memory runs out, the kernel kills the build instead of an agent | Low | The same cargo wrapper |
| 3 | Per-agent memory cap: `MemoryMax` with swap capped too and kill on OOM, no `MemoryHigh` | Stops one runaway process from taking down every sandbox; throttling stalls agents without killing anything | Medium | `agent-sandbox.sh` / entrypoint, or `CLAUDE_CODE_TOOL_MEMORY_LIMIT` |
| 4 | Dev profile `debug = "line-tables-only"`, dependencies `debug = false` | Debug info is what makes linking heavy | Low | `CARGO_PROFILE_DEV_*` env in the sandbox |
| 5 | Cap `CARGO_BUILD_JOBS` at about CPUs/4 per agent | Fewer rustc processes running at once | Low | Sandbox env |
| 6 | Run Playwright and other stateless MCP servers once over HTTP; trim the rest with `--strict-mcp-config` | MCP processes are 37–68% of each session's memory, duplicated per session and subagent | Medium | Sandbox plugin MCP config |
| 7 | Stop/SessionEnd hook that kills orphaned headless Chrome and MCP servers | One report found about 10 GB left behind after sessions ended | Low | Sandbox plugin hooks |
| 8 | No rust-analyzer in agent worktrees (or `ra-multiplex`) | 2–13 GB per instance, one per worktree | Low | Agent LSP config |
| 9 | `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` | Kept an idle session's memory flat in one A/B test of a known leak | Trivial | Sandbox env |
| 10 | Lower `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` (default 20) and set `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` | Each subagent can start its own full set of MCP servers | Trivial | Sandbox env (_unverified_ names) |
| 11 | Before a build starts, check `/run/agent-sandbox-cgroup` has 6G+ free | Holds a build back until there's room, instead of letting it fail mid-way | Medium | The same wrapper as #1 |
| 12 | Restart long-running sessions periodically (`claude -c`) | Leaks outside the JS heap; `--max-old-space-size` doesn't cap them | Habit | — |
| 13 | Use `command grep` in agent shells, or a hook that blocks `{0,N}{0,N}` patterns | The embedded ugrep blows up exponentially on those patterns | Low | Hook or CLAUDE.md |
| 14 | Codex: one background or multi-agent session at a time, same cgroup cap | Reports of 18–29 GB OOMs and leaked process trees | Low | Codex config |
| 15 | Host: earlyoom with `--prefer rustc\|ld`, `--avoid claude\|codex\|Hyprland` | Only protects the desktop; it can't see the 20G sandbox limit | Low | `hosts/home` |
| 16 | zswap rather than zram | Memory in zram isn't charged to any cgroup, so it undermines the 20G limit | Low | `hosts/home` kernel params |
| 17 | Shared FIFO jobserver across sandboxes | Finer-grained than a lock, but nobody has shown it working across separate cargo runs, and a killed rustc leaks its token | High | Skip unless #1 is too coarse |

Doing #1, #2, #4, #5 and #9 together would remove most of the out-of-memory
risk with little work.

## Details

### Builds

- Builds competing for the CPU ran "up to 300% slower" in one report, and
  three agents already saturated the CPU in another. Running builds one
  after another costs little. A shared `CARGO_TARGET_DIR` already makes
  builds wait on Cargo's lock.
- Cargo can't limit how many linkers run at once, only total jobs
  (rust-lang/cargo#9157).
- `codegen-units = 1` saved about 1–1.5 GB in one report, at the cost of
  slower builds. No evidence was found that mold uses less memory.
- Shared jobserver: `mkfifo /shared/js`, write N tokens into it, then
  `CARGO_MAKEFLAGS="-j --jobserver-auth=fifo:/shared/js"`. Cargo ignores
  `-j` when it inherits a jobserver. _Unverified_ across separate cargo
  runs.
- Block's `agent-task-queue` is an MCP server that runs builds through a
  first-in-first-out queue. Agents use it only if CLAUDE.md tells them to
  use it instead of Bash.

### cgroups and OOM

- Docker leaves `memory.oom.group` off, so on OOM the kernel kills a single
  process, the one with the highest `oom_score`.
- Raising `oom_score_adj` needs no privileges. Lowering it on agents needs
  `CAP_SYS_RESOURCE`.
- `MemoryHigh` throttling:
  - In a t3code benchmark, 12 agents on 12.9 GiB stalled under
    `MemoryHigh` and none finished; 8 agents were fine.
  - A Zenn post dropped `MemoryHigh` because a runaway process stalled at
    the threshold instead of being killed. Its setup: each claude scope at
    `MemoryMax=8G`, `MemorySwapMax=0`, `OOMPolicy=kill`, under a slice
    capped at 30G.
- If builds get their own child cgroup, set `memory.oom.group=1` on it so a
  failed build dies completely. A swap cap that's too small can leave the
  build stuck in D state. _Unverified_ whether sub-cgroups can be created
  inside the containers.
- The AgentCgroup paper measured Claude Code memory bursts of 0.5–4 GB
  lasting 1–2 s, too fast for daemons that watch memory pressure (PSI) to
  catch.
- earlyoom and nohang watch host memory, not the sandbox cgroup.
  systemd-oomd on the sandbox slice would kill a whole sandbox at once.

### Claude Code

- `CLAUDE_CODE_TOOL_MEMORY_LIMIT=4G` (2.1.233+) caps the commands a
  session runs. `CLAUDE_CODE_TOOL_MEMORY_CGROUP_EXCLUDE=none` (2.1.246+)
  also counts MCP, LSP, hook and child-agent processes.
- `CLAUDE_CODE_WARN_MEMORY_FREE_GIB=4` warns the model when free memory
  drops below 4 GiB.
- `CLAUDE_CODE_NO_FLICKER=1` keeps memory flat in long conversations,
  according to the docs.
- Settings above: _unverified_ against the installed 2.1.302, whose binary
  doesn't contain environment variable names as plain text.
- Idle leak outside the JS heap: idle sessions grew 0.4–1 GB per minute on
  2.1.170–2.1.221 (#67433, open).
- Embedded ugrep blowup: two bounded repeats like `{0,16}` in one pattern
  used 1.05 GB, and OOM kills reached 5–21 GB (#84960). Kill a runaway with
  `pkill -f ugrep`.
- MCP servers aren't shared between sessions; requests for that were
  closed as duplicates. Orphaned servers reached about 13 GB in one report
  (#26658).

### Codex

- Codex's team says the CLI itself uses little memory and the child
  processes are the problem. They declined a per-session memory limit and
  suggested containers (#11523).
- Reports of cgroup OOMs at 18–29 GB (#21233), 75 GB+ with
  `multi_agent=true` (#20740), and leaked process trees of 791–1,319
  processes.
- MCP servers can be switched off per server with `enabled = false`, or
  connected over HTTP with `url`.

### Sharing across worktrees

- MCP:
  - Playwright as one HTTP server: `npx @playwright/mcp --port 8931`, then
    `{"url":"http://localhost:8931/mcp"}` in each instance.
  - mcp-ondemand claims 6.8 GB down to 0.9 GB for 5 sessions
    (_unverified_).
- Cargo:
  - A shared target dir compiles dependencies once, but build scripts can
    bake in another worktree's path.
  - Cargo 1.91's `build.build-dir` keeps intermediate artifacts separate.
- pnpm `enableGlobalVirtualStore` (experimental) turns `node_modules` into
  mostly symlinks. Run installs one at a time.
- No tool was found that shares one dev server across agents.

### Agent count vs RAM

- About 8 lightweight agents fit in 13–16 GB; 12 thrashed.
- On 16 GB Macs people settle on 2–3 agents that build.
- One user ran 6 agents doing builds and typechecks on a 10 GB server; it
  froze from swap thrashing without any OOM kill.
- One HN user capped a Rust agent fleet at 5 workers on 24 cores.
- Anthropic suggests 3–5 parallel sessions.

## Sources

- https://github.com/anthropics/claude-code/issues/18859
- https://github.com/anthropics/claude-code/issues/67433
- https://github.com/anthropics/claude-code/issues/84960
- https://github.com/anthropics/claude-code/issues/26658
- https://github.com/anthropics/claude-code/issues/28860
- https://github.com/anthropics/claude-code/issues/15487
- https://code.claude.com/docs/en/tools-reference
- https://code.claude.com/docs/en/env-vars
- https://code.claude.com/docs/en/mcp
- https://jyoung.dev/blog/claude-code-parallel-sessions-memory/
- https://github.com/openai/codex/issues/21233
- https://github.com/openai/codex/issues/20740
- https://github.com/openai/codex/issues/11523
- https://codex.danielvaughan.com/2026/04/18/subagent-mcp-resource-leak-process-trees/
- https://zenn.dev/tjst_t/articles/260219-claude-code-cgroup-memory-limit?locale=en
- https://github.com/pingdotgg/t3code/discussions/21288
- https://arxiv.org/html/2602.09345v2
- https://chrisdown.name/2026/03/24/zswap-vs-zram-when-to-use-what.html
- https://labs.iximiuz.com/challenges/kill-container-on-child-process-oom-event-docker
- https://braindetox.kr/en/posts/memoryhigh_vs_memorymax_build_throttle_linux.html
- https://github.com/rust-lang/cargo/issues/9157
- https://github.com/recodeee/gitguardex/pull/601
- https://github.com/ansman/agent-task-queue
- https://engineering.block.xyz/blog/the-missing-piece-for-local-ai-development
- https://news.ycombinator.com/item?id=49920896
- https://news.ycombinator.com/item?id=50084416
- https://github.com/rust-lang/rust-analyzer/discussions/20871
- https://dev.to/alex_iolan/six-ai-agents-froze-my-production-server-each-one-did-the-right-thing-4bo6
- https://omg.dev/tools/coding-agent-capacity
- https://github.com/microsoft/playwright-mcp
- https://github.com/rfjakob/earlyoom
- https://pnpm.io/next/git-worktrees
- https://support.claude.com/en/articles/14554000-claude-code-power-user-tips

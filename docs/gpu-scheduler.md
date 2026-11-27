# GPU reservations

`gpu-run` coordinates the home desktop's GPU 0 across the host and all agent
sandboxes. It allows concurrent workloads with declared peak VRAM budgets,
and exclusive workloads for video generation and demanding games. It is
cooperative admission control: programs that bypass the launcher can still use
the GPU, and a reservation does not impose a driver memory limit.

```sh
gpu-run --vram 4GiB --name "small model" -- python small-model.py
gpu-run --exclusive --name "video generation" -- python generate-video.py
gpu-game --name "game" -- game-command
gpu-status
gpu-status --json
```

Use a conservative peak estimate, including weights, inference/KV caches,
activations, temporary allocations and a safety margin for the chosen context,
batch size or resolution. The scheduler does not estimate these for you. Known
peaks can use shared reservations even for larger models; unknown workloads and
video generation should use `--exclusive`. An oversized
shared request fails rather than waiting forever. `--timeout 60` limits time in
the queue; otherwise a request waits until admitted or interrupted. Commands
inside an existing reservation run directly; nested reservations are rejected.

## Waiting in the background

An Orca worker whose request queues behind other reservations shouldn't hold a
foreground tool call open, and a worker that just ends its turn is reported to
its coordinator as stopped. `gpu-run --background` covers both:

```sh
gpu-run --background --vram 12GiB --name "upscale pass" -- python upscale.py
gpu-run --background --wake-on-grant --exclusive --name "video" -- python generate.py
```

It finds the worker's Dispatch from Orca (`--orca-dispatch` overrides it),
starts a detached coordinator and returns once the request is queued, printing
the lease, the log path (`--log` sets it) and the PID that cancels it. The
coordinator runs an ordinary foreground `gpu-run` as its child, so admission,
supervision, timeouts and the nesting rule are unchanged. While that child is
queued or running, the coordinator holds an
`orca orchestration check --peek --wait` on the worker's mailbox, filtered to a
type workers never receive: Orca counts a held waiter as a deliberate rest, and
the filter leaves every other message to normal delivery. When the child exits
it releases the waiter and sends a `status` message to the worker's own
`dispatch:` mailbox with the exit status, duration and the log's tail, which
wakes Claude and Codex workers alike. `--wake-on-grant` also sends one when the
reservation starts. Outside an Orca worker `--background` refuses; run
`gpu-run` as the harness's own background command instead.

For a demanding Steam game, set its Properties → General → Launch Options to:

```text
gpu-game --name "Gears E-Day" -- %command%
```

The launcher is installed in Steam's environment. Put it before any existing
launch wrapper so admission happens before Proton or the game allocates VRAM.
Games without this launch option do not reserve a slot. GameMode remains
responsible for CPU policy; its hooks cannot gate GPU allocations before launch.

## Queue and memory policy

- Running work finishes normally. A game request goes ahead of waiting model
  work, and blocks new model admissions until its turn is over. Games are FIFO
  among themselves; ordinary requests are FIFO. An exclusive request at the head
  blocks later shared requests, so a stream of small jobs cannot starve it.
- Shared admission counts each active job at the greater of its declared peak
  budget and attributed GPU usage. Unused budget remains reserved for inference,
  even while the model is idle or has not loaded yet. Memory outside active
  leases is counted separately, with a minimum 4096 MiB desktop allowance.
  For example, on a 32 GiB GPU, a model using 20 GiB with a 24 GiB peak budget
  can share with a 2 GiB job: 24 + 2 + 4 = 30 GiB. Loading more weights or
  inference buffers does not consume another reservation for the same job.
- A socket-activated host user service queries NVIDIA compute-process memory and
  reads each same-user process's `GPU_LEASE_ID` from host `/proc`. Workers from
  all sandbox PID namespaces can therefore be attributed without exposing host
  `/proc` inside containers. Only memory tagged with a currently running lease
  gets credit. Unknown processes, retired leases, missing metrics and unreadable
  process environments remain outside the leases. The socket accepts no commands
  or client-supplied paths and is accessible only to the user.
- If the host attribution service is unavailable or its response is invalid,
  admission falls back to adding all active peak budgets to measured GPU usage
  (or desktop headroom, whichever is larger). This deliberately double-counts
  loaded models until attribution is restored. If aggregate telemetry also
  fails, admission waits. Existing older clients keep their conservative policy.
- 4096 MiB is reserved for desktop use. Exclusive admission requires no active
  leases and measured usage at or below that allowance. The desktop, browser,
  OBS and display servers continue to run; exclusive means exclusive among
  participating workloads. It does not guarantee the entire physical VRAM.
- NVIDIA telemetry is checked under the admission lock before each grant.
  `gpu-status` reports memory, attributed allocations, running reservations,
  waiting jobs and the reason each job is blocked. Telemetry is a snapshot,
  not hardware isolation: jobs must honor their peak budgets.

Keep the command running until GPU cleanup is complete. Persistent model servers
must run inside their reservation for their whole resident lifetime. For a
per-request integration, unload the model before allowing the reserved command
to exit. Suspending a process does not free VRAM. Unloading is the workload's
responsibility; `qwen-opencode` below is the one model server here that
holds a reservation only while it is in use.

## Interactive Qwen in OpenCode

`qwen-opencode [--uncensored] [--moe] [--idle-minutes N] [opencode args...]` opens the
OpenCode TUI (`opencode --standalone`) on the same pinned Qwen GGUFs as the
`qwen-prompt` skills, with the same readiness checks: a model that isn't ready
fails before anything starts, with no download or fallback. Arguments after its
own leading options go to OpenCode unchanged.

OpenCode talks to a small proxy on a loopback port that stays fixed for the
session. The model loads on the first request: the proxy starts
`gpu-run --vram 26GiB -- llama-server ...` and holds requests until it is
healthy, queueing normally behind games or other work. A streaming request
that waits gets SSE comments every 15 seconds so OpenCode's header timeout never
fires. Listing models doesn't load anything. After `--idle-minutes` (default 5,
or `QWEN_OPENCODE_IDLE_MINUTES`) without a request in flight, it stops
llama-server, which frees the VRAM and ends the reservation; OpenCode stays
open and the next request books the GPU again. Quitting OpenCode, a signal or
a crash of either process stops llama-server and releases the reservation:
gpu-run and OpenCode are started with a parent-death signal, and llama-server
gets one from gpu-run. Nothing but the opening line reaches OpenCode's
terminal: server output, the proxy's access log and its errors go to
a log of the session's own under `~/.local/state/qwen-prompt/`, such as
`qwen-opencode-regular-moe-<date>-<time>-<pid>.log`, which moves to a single
`.1` backup at 8 MiB. Each launcher keeps its 10 newest session logs. A client closing its connection logs nothing. When something failed,
one line naming the log is printed after OpenCode exits.

The context is 64k tokens with an f16 KV cache, one slot and full offload.
Qwen3.8 27B is hybrid: only 16 of its 65 layers use attention, with 4 KV heads
of 256, so the cache costs 64 KiB per token, 4 GiB at 64k. With a 63,750-token
prompt the regular model peaked at about 24.2 GiB (26,083 MiB on the GPU
against a 1,902 MiB desktop baseline); the uncensored weights are 1.3 GB
smaller. 26 GiB leaves about 2 GiB of margin and still fits the 28.5 GiB
the scheduler allows a shared request.

`--moe` (on `qwen-opencode` and `qwen-prompt`, with or without `--uncensored`)
swaps the dense 27B for Qwen3.8-Flash-Next, a 512-expert mixture-of-experts
model, served through [Strata](https://github.com/Niko1221/Strata) instead of
llama.cpp. It uses the GSQ-RCO IQ3_XXS files (`qwen3.8-flash-next`, or SC117's
abliteration `qwen3.8-flash-next-uncensored` with `--uncensored`).
Both keep an int8 KV cache in VRAM.

The 42.9 GB (about 40 GiB) of routed experts don't fit the card, so it runs
Strata's resident low-RAM mode (`--resident-experts`): the GPU caches a fixed
number of the most-used experts and page-locked system RAM holds the rest. The
28.8 GB n-gram table stays on disk and is read a few rows per token. Every GiB
of experts taken off the card goes into RAM, so `qwen-opencode --moe` offers
four VRAM profiles as models in OpenCode's model list:

| Model | Context | Booking | Peak VRAM | Pinned RAM | Prompt tok/s | Generation tok/s |
| --- | --- | --- | --- | --- | --- | --- |
| `flash-next-20g` (default) | 256k | 23 GiB | 22.0 GiB | 32 + 4 GiB | 5,740 | 80 |
| `flash-next-16g` | 256k | 17 GiB | 16.0 GiB | 36 + 1 GiB | 4,180 | 40 |
| `flash-next-12g` | 128k | 13 GiB | 11.6 GiB | 36 + 1 GiB | 3,040 | 45 |
| `flash-next-8g` | 64k | 9 GiB | 8.0 GiB | 34 + 1 GiB | 980 | 26 |

Pinned RAM is the expert budget plus the parked-conversation cache. Peaks and
speeds were measured on the regular model with an 8.6k-token prompt and 512
tokens out; time to the first token was 1.5, 2.1, 2.9 and 8.9 s. The 16G run
used a 4 GiB conversation cache, which doesn't change VRAM or speed. The KV
cache for the whole context is allocated at load, so a longer prompt shouldn't
raise the peak, but full-context prompts and the uncensored model haven't been
measured; each booking leaves 1 to 1.4 GiB over its measured peak. Each booking is a shared `--vram` request,
so Flash-Next runs next to other GPU work, but the lower profiles take most of
the sandboxes' 64 GiB of RAM. An expert budget short of what the GPU doesn't
hold reads the rest from the SSD and swaps the host, so the budgets aren't
trimmed further. `qwen-prompt --moe` uses the default profile at 16k.

The proxy reads the model ID from each request. Picking another profile in
OpenCode waits for any request still being served, unloads Strata and starts it
again under the new profile's booking; requests for the new profile queue
behind the reload, which takes about 20-30 seconds plus any wait for the GPU.
The `qwen` model, which OpenCode uses as its small model for titles, takes
whichever profile is loaded (the default when none is) and has the smallest
context, so it never triggers a reload. Only one Flash-Next runs at a time
across all sandboxes, since two would not fit in RAM: each `--moe` server
holds `~/.cache/qwen-prompt/strata/serve.lock`, and another one waits for it
before booking the GPU, which is up to `--idle-minutes` after the other one
was last used. The idle unload frees both the VRAM and the pinned RAM.

The first `--moe` launch for a model builds Strata's pack in
`~/.cache/qwen-prompt/strata/<shard>/`, before booking the GPU: the tensor
index, the tokenizer and a 43 GB `experts.bin` the resident mode copies from.
A build runs once at a time and only publishes a complete pack.

In Orca's agent picker, OpenCode on `home` runs
`orca-sandbox-launch orca-sandbox opencode`, which `agent-sandbox-exec` turns
into `qwen-opencode --uncensored` in the repository's sandbox, where the
scheduler directory and `$MODEL_ROOT` are mounted. Orca's OpenCode status
plugin posts to Orca's loopback port with `fetch`, which the container can't
reach, so sandboxed OpenCode panes show no working or done status.

## Shared leases and lifecycle

The host and sandboxes bind the same `/run/user/<uid>/gpu-scheduler` directory.
A short `flock` on `admission.lock` serializes updates. Each queued or running
request holds a separate locked JSON record. The launcher supervises its command
and adopts detached descendants, keeping the reservation until all of them exit.
The lease descriptor is also inherited by the command. Ordinary interrupts are
forwarded to the command's process group; its exit status is preserved.

After a process exits or is killed, records with no surviving lock holders are
reaped by the next scheduler command. No daemon restart can forget active leases.
Never remove the directory, admission lock, or lease files while workloads are
running: replacing an inode splits the coordination domain. This is a local
filesystem protocol for one user and one GPU, not a distributed lock service.
Programs must not escape supervision into unrelated existing services. A force
kill of a supervisor whose workers close inherited descriptors can lose the
reservation; measured memory remains a secondary check, not hardware isolation.

The sandbox launcher creates and binds the host directory into new containers.
A sandbox missing that mount fails closed rather than creating a private queue.
`GPU_SCHEDULER_DIR` exists for isolated tests; all production workloads use the
default shared directory.

## Agent configuration and rollout

Claude's global GPU rule and Codex's global `AGENTS.md` include the same policy:
reserve before GPU work, estimate peak VRAM, use exclusive mode when uncertain,
wait rather than bypass, and unload before releasing. The sandbox's system
Claude instructions include it too.

Build and apply the `home` configuration through the normal NixOS workflow, then
restart sandboxes to pick up the package and shared mount, restart agent sessions
to load the instructions, and set launch options on demanding Steam games.
Building alone does not activate these changes.
The `gpu-scheduler-telemetry.socket` user unit must be active for attribution;
an updated host and newly started sandboxes use it through the shared scheduler
directory. `systemctl --user status gpu-scheduler-telemetry.socket` checks it.

## Verification

```sh
python3 -m unittest discover -s pkgs/gpu-scheduler -v
nix build .#gpu-scheduler .#checks.x86_64-linux.gpu-scheduler .#checks.x86_64-linux.qwen-prompt
nix build .#nixosConfigurations.home.config.system.build.toplevel
```

Tests use a fake NVIDIA memory probe and real processes and file locks. They
cover concurrent grants, exclusive barriers, game priority, cancellation,
telemetry failure, descendant lifetime and command exit status without loading
models or allocating GPU memory. `qwen-opencode`'s tests use fake gpu-run,
llama-server and OpenCode to cover idle unload, reacquisition, a queued request
cancelled at exit, and cleanup after quitting, SIGTERM, SIGHUP and SIGKILL.

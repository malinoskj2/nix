# Resource scheduler

`resource-run` submits a foreground workload to one host Slurm instance. CPU, RAM
and GPU reservations are allocated together by Slurm. A root-owned policy service
keeps new jobs held until live desktop headroom permits release. It does not grant
independent leases or infer completion from a missing client, PID or journal entry.
The Nix module is opt-in: building this package does not activate it or replace the
existing GPU scheduler.

## Commands

```sh
resource-run --cpu 8 --ram 8GiB --name 'project build' --category build -- make -j8
resource-run --cpu 2 --ram 6GiB --vram 4GiB --name 'small inference' --category inference -- ./infer
resource-run --cpu 4 --ram 12GiB --exclusive --vram 20GiB --name 'large inference' -- ./infer
resource-run --cpu 8 --ram 8GiB --exclusive --priority game --category game --name 'game' -- ./game
resource-status --json
resource-control cancel FULL_JOB_ID --revision JOB_REVISION --confirm
resource-control terminate FULL_JOB_ID --revision JOB_REVISION --confirm
resource-control run-next FULL_JOB_ID --revision JOB_REVISION --confirm
resource-control force-run FULL_JOB_ID --revision JOB_REVISION --confirm
resource-control run-host FULL_JOB_ID --revision JOB_REVISION --confirm
resource-control run-sandbox FULL_JOB_ID --revision JOB_REVISION --confirm
resource-control pause --confirm
resource-control resume --confirm
```

CPU units are **Slurm CPUs**, governed by the configured node topology and
`CR_Core_Memory`, not a claim of physical core-equivalents. On an SMT node core
allocation can round a thread request up to a whole core. `--ram` and `--vram`
accept positive decimal MiB/GiB and round upward to MiB; RAM is required. Labels (up to160 UTF-8 bytes)
are required and must exclude secrets. Raw command arguments and environments
never appear in status, lifecycle events or the Slurm job name/script.

`--exclusive` allocates the whole GPU relative to managed jobs. An explicit
`--vram` is the preferred peak admission budget; exclusivity does not reserve the
entire workstation or prevent desktop GPU use. Without `--vram`, the requested
peak is unknown. At admission the service freezes a budget equal to current free
VRAM minus the safety margin, capped by configured device capacity. Public status
reports `requested.vram_mib: null`, `vram_estimate: "all-available"` and the separate
`allocation.vram_mib`. This is available capacity, not a measured or guaranteed
workload peak. The allocation does not shrink while running. Missing GPU telemetry
blocks GPU admission. CPU-only work can run without NVIDIA telemetry.

The child receives `RESOURCE_JOB_ID`, `RESOURCE_CPU`, `RESOURCE_RAM_MIB` and
`RESOURCE_VRAM_MIB`, plus `RESOURCE_CPUSET` describing actual allowed CPUs; GPU jobs also receive `GPU_LEASE_ID` for migration. These are
budget descriptions, not permission for additional arbitrary work. Nested
acquisition is rejected. Additional work must fit all existing budgets or be
submitted after that reservation ends. There is no automatic cloud fallback.

`--timeout SECONDS` cancels a job if it remains queued past the deadline and waits
for authoritative Slurm cleanup. The client streams bounded stored output and
returns the workload exit code, including signal-derived codes. Ctrl-C requests
cancellation/termination and waits for Slurm. Connection loss reports the immutable
job ID: inspect or cancel that ID, rather than resubmitting and duplicating work.
The job continues safely if its client disappears.

## Admission, pressure and games

The policy uses host `MemAvailable`, never swap, and NVIDIA device free memory.
For each resource it subtracts the safety margin and **unused** portions of
existing reservations from currently available memory. Managed actual usage is
credited only when attributable to the Slurm cgroup. Missing attribution gives no
credit. This avoids both optimistic reuse of idle reservations and subtraction of
actual usage twice. GPU compute utilization is a separate reading, not a proxy
for free VRAM or reserved compute.

Defaults are 4GiB RAM headroom, 3GiB VRAM headroom, 12 background Slurm CPUs and a
10-second healthy interval. The home host overrides normal CPU capacity to 28,
matching the idle sandbox pool's logical CPU count. Memory PSI full avg10 >=1 percent or RAM below the
margin holds new admissions. Existing allocations remain reserved. Pressure is
sampled every two seconds; this is admission policy, not protection from every
external allocation between samples. Slurm cgroups enforce CPU placement and RAM,
including no swap allowance. VRAM shards are cooperative MiB budgets: neither
shards nor a whole GPU allocation physically fence VRAM. A process can overrun its
request; device aggregate usage still counts against the next admission.

Games go ahead of queued background work; active work is not preempted. Interactive
priority goes ahead of recent background jobs, while a non-game job waiting 60
seconds gains an age fence ahead of newly arriving interactive jobs. Within that
ordering the head job protects its place when running jobs finishing could make
it fit. When measured available RAM/VRAM plus attributable running-job memory
would still be insufficient, smaller eligible jobs may pass it. CPU-only work
may also pass a GPU job blocked by external GameMode or missing GPU telemetry.
The game CPU cap still applies. Unknown managed allocations or missing relevant
memory attribution preserve the barrier. All automatic admissions retain pressure,
stability, capacity and headroom checks, and release at most one job per tick.
Each admission records `bypassed_job_ids`; blocked jobs explain why they allow
backfill. The decision is recalculated every tick, so a job regains its place as
soon as host conditions improve. This is FIFO/aging across identities, not
Slurm account fair-share: all actual Slurm bootstrap jobs run as root and original
agent/worktree identities are retained in the API and journal.

A queued/running managed game or a root-owned external GameMode marker reduces
new background CPU capacity to four Slurm CPUs by default. The game's own request
uses the normal capacity. Existing background jobs receive proportional cgroup
`cpu.max` quotas with an aggregate ceiling of four CPU-seconds per second and
`cpu.weight=25`. After gaming, quotas restore to `max` and weight100. CPU placement
still comes from Slurm; the older `agent-sandbox.slice` affinity does not constrain
these jobs. GameMode affinity requests remain constrained by the Slurm cpuset;
a disjoint V-Cache pinning request can fail without moving the workload outside
its allocation. Slurm CPU reservations do not promise a particular CCD.
The root GameMode service owns `/run/resource-scheduler-game-active`;
while present it also blocks new GPU admissions. Missing/unwritable Slurm CPU
controllers during gaming produces explicit status errors and stops admissions.
CPU-only jobs may pass a job blocked specifically by a running exclusive GPU
allocation (or a GPU trial). GPU ordering is retained. All CPU/RAM, pressure, pause
and unknown-allocation checks still apply; memory shortages do not gain this
exception merely because a job also requests GPU resources.

The policy never suspends processes or claims suspension frees memory.

## Workload calibration and profiles

Exploration is an explicit, repeatable sandbox trial, still supervised by Slurm.
It does not require an accurate peak estimate and does not bypass the scheduler:

```sh
resource-run --explore --gpu --project e-day-ports \
  --profile marcus-runtime --variant representative-scenes-1080p-v1 \
  --ram 12GiB --name "Marcus calibration" --category game -- command
resource-profile --project e-day-ports \
  --profile marcus-runtime --variant representative-scenes-1080p-v1
```

Without overrides a trial requests 2 CPUs, 4GiB host RAM and, with `--gpu`, an
initial 1GiB shared VRAM allocation. Without `--gpu` or `--vram`, it is CPU-only.
CPU/RAM retain Slurm enforcement, swap is not added capacity, and the trial has a
30-minute wall limit. GPU shards remain cooperative: a trial can exceed its initial
VRAM allocation and affect another GPU user before the next sample. Existing shared
work continues; only one GPU trial runs at a time and subsequent GPU admissions
wait for it to establish its peak. CPU-only backfill remains available. No trial
bypasses an existing exclusive allocation, a pressure hold or desktop headroom.
The backend cancels only the trial if RAM/GPU headroom is breached, memory pressure
rises, or required aggregate telemetry disappears, and waits for Slurm cleanup.
This sampled intervention cannot promise protection from instantaneous GPU spikes.

Inspect the result and adjust workload settings or the next request, rather than
retrying every failure with more memory. `ram_oom` requires a Slurm OOM state or
cgroup OOM-kill evidence. `gpu_oom_reported` means a recognized application error
in captured stderr, not independently verified GPU exhaustion. Other outcomes are
`command_failed`, `time_limit`, `cancelled` or `exploration_headroom`. There are no
automatic reruns. Three unsuccessful exploratory attempts for the same variant
block further probes; an explicitly budgeted successful run resets that count.
Changed settings may use a new variant; an unchanged workload must not rotate
identifiers to bypass the bound. Output and the actual exit status remain available.

Explicit profile identity is a `(project, profile, variant)` tuple, using 1–80
safe identifier characters per component. Include model/version, input dimensions,
batch/context settings or representative scenes in the variant. No fuzzy command
matching, command-line storage, environment capture or secrets enter profiles.
The owner-authenticated `resource-profile` command lists profiles or looks up an
exact tuple. Up to 128 profiles are retained in root-owned scheduler state, across
restarts and job-history pruning; updates and completion bookkeeping are atomic.
Normal runs can attach the same `--profile` and `--variant` to refine the evidence.
Otherwise new runs receive an automatic private workload signature, described below.

Recommendations use the largest successful observed peak plus 25% or 512MiB,
whichever is larger, rounded up to 256MiB. They are advisory: subsequent runs still
declare their own CPU/RAM/VRAM requests. A latest failed run suppresses suggestions.
RAM needs a measured peak; GPU needs at least two attributed samples with no missing
running samples and full graphics/compute process attribution. Missing values and
short unsampled jobs yield unknown recommendations, never zero GPU estimates.
CPU-only runs suggest no GPU reservation. A GPU trial that never exercises the
device does not produce a GPU budget suggestion. A complete process inventory
can establish zero current usage during idle/loading phases; incomplete inventories
remain unknown. GPU polling can still miss brief peaks;
representative input coverage remains the caller's responsibility. Unmanaged host
and sandbox overrides do not train profiles. Profile identifiers, trial badges and
failure classifications appear in the plugin inspector; trial allocations are
excluded from reservation-accuracy statistics.

Automated runtime inspection is ordinary background shared work. Human game
priority/exclusivity is reserved for actual interactive gaming or a genuine need
for the entire device. Marcus's previous exclusive allocation cannot be silently
converted or shrunk by these changes: future launches use a shared explicit budget
or calibration, and an existing session must finish or be deliberately restarted.
Riso's budget should similarly be established from representative measured work,
not inferred from its name.

## Explicit waiting-job controls

All four controls require the immutable ID, current revision, owner authorization
and explicit confirmation. Only unreleased queued Slurm jobs are eligible:

- `run-next` moves a job to the front, keeping all admission checks. The latest
  explicit reorder wins; `queue_position` exposes the resulting waiting order.
- `force-run` releases it to Slurm immediately, bypassing queue order, manual
  admission pause, pressure and headroom policy. Requested resource budgets remain
  intact, and Slurm can still leave it pending if its hard allocation limits do
  not fit. An unknown-size exclusive GPU job retains the full configured usable
  GPU budget when forced. This is not proof that the command started.
- `run-host` cancels the held Slurm job and waits for Slurm to confirm cancellation,
  then launches an **unmanaged host process**, outside Slurm and outside the
  submitting sandbox. It runs as the original unprivileged UID/GID, with the
  original working directory, command and environment; those dependencies must
  exist on the host. No CPU/RAM/VRAM admission budget or headroom protection applies.

- `run-sandbox` follows the same confirmed cancellation handoff but runs in the
  **original submitting sandbox**, outside Slurm. Only sandbox-origin jobs qualify.
  The trusted namespace bridge validates the running container and immutable
  runtime, then enters its mount, network, IPC, UTS and PID namespaces before
  dropping privileges. Missing or invalid sandboxes fail; execution never falls
  back to the host. No queue resource reservation or budget enforcement applies.

Unmanaged processes run in a unique root-created transient systemd service using
an immutable privileged bootstrap, followed by privilege drop and `no_new_privs`.
No submitted command or environment enters systemd unit arguments. The subreaper
and systemd control group retain descendant lifetime and termination, but do not
reserve resource capacity. The same job ID, bounded stdout/stderr stream and files
remain available to the submitting CLI and plugin. `execution: "host"` or `"sandbox"` and
`systemd_unit` identify the execution mode; its `allocation` is null. Its usage is external
to Slurm, and it never contributes to queue reservation totals or game CPU quotas.
Original submission origin remains recorded. Processes receive
`RESOURCE_EXECUTION_MODE=unmanaged-host` and `RESOURCE_HOST_JOB_ID`, not reservation
or sandbox-instance markers for host execution. Sandbox execution instead receives
`RESOURCE_EXECUTION_MODE=unmanaged-sandbox`, `RESOURCE_SANDBOX_JOB_ID` and the
validated `AGENT_SANDBOX_INSTANCE`; reservation markers are removed in both modes.
Sandbox processes remain in the transient service cgroup for cleanup, not the
container or Slurm cgroup. Runtime records and captured stdout/stderr stay on the
host; command-created files use the sandbox filesystem and its existing mounts.

Launch intent is persisted before systemd submission. A lost response or missing
unit produces Unknown, never an automatic second launch. Cancel during the Slurm
handoff prevents launch; terminate after launch stops the whole service and waits
for authoritative terminal state. Payloads are removed only after confirmed
completion. These controls are explicit human overrides, never an automatic agent
fallback for unavailable resources. A service restart reconciles existing host
units rather than launching replacements.

## Execution and trust boundary

A single root daemon exposes `/run/resource-scheduler/control.sock`, mode0600 and
owned by the configured workstation UID/GID. `SO_PEERCRED` enforces the owner for
reads and controls. Sandboxes bind the socket directory, not Slurm credentials,
Munge keys or controller ports. The partition uses `RootOnly=YES` with `EnforcePartLimits=ALL`; `AllowGroups=root`
alone is insufficient because Slurm can otherwise accept an ineligible job into
the pending queue.
Clients cannot lower service policy or supply administrative Slurm arguments.
All agents of that same UID are one security principal: they can inspect/cancel
each other's jobs after an explicit confirmation and current job revision. Agent
names are attribution, not a separate authorization boundary.

The daemon stores caller cwd/environment/argv in a root-only per-job payload.
Slurm receives a held root bootstrap with a UUID-only name/comment and a fixed
immutable Nix-store Python command. The bootstrap uses Python isolated mode and
an immutable package-generated tool PATH; only the unit's trusted `SLURM_CONF`
is retained during privileged subprocess operations. Caller environment is not
used for privileged imports, executable lookup or namespace entry.

For a Docker sandbox, the bootstrap validates its exact `agent-sandbox-*` name,
running init, configured UID:GID and read-only host `/nix/store` bind. It pins root
and mount/network/IPC/UTS/PID namespace descriptors, checks init start time for PID
reuse and verifies the interpreter and bootstrap inode match the host immutable
store. `nsenter` joins those namespaces, **never the container's cgroup or user
namespace**. The trusted inner bootstrap clears supplementary groups, sets GID
and UID, enables `no_new_privs`, then restores caller environment/cwd and starts
the command. A subreaper inside the destination PID namespace waits for all
adopted descendants, including detached children. Slurm retains cgroup ownership
and performs cancellation cleanup. Host execution uses the same privilege drop
without namespace entry. A missing or mismatched sandbox fails normal Slurm execution instead
of falling back to the host. The explicit `run-host` control above is a separate
user-authorized execution mode.

Keep model servers in the foreground under this allocation until unload/exit.
Servers started by an independent Docker/Nix/systemd daemon can escape the job
cgroup. In particular, Nix daemon builds have their own processes: the reservation
still covers the client's lifetime and external RAM use is counted conservatively,
but the wrapper cannot claim Slurm CPU/RAM enforcement on those daemon children.
Do not detach a persistent model service through another daemon and then release
its budget. Such services require a dedicated lifetime adapter before use.

Optional cooperative model instrumentation, from inside the running reservation:

```sh
resource-model loading --name 'local model'
# load model in this allocation
resource-model ready --name 'local model'
resource-model busy --name 'local model'
resource-model idle --name 'local model'
# actually unload before reporting:
resource-model unloaded --name 'local model'
```

These owner-reported events record loading duration/residency separately from
GPU measurements. They do not unload a server or prove it is idle. The API
advertises `unload:false`; no unsafe generic unload action is offered. Automatic
idle unloading/checkpointing requires model-server support and remains unavailable.

## API v1 and status

The Unix protocol is one UTF-8 newline-terminated JSON request/response per
connection, request limit1MiB, three-second input deadline. Authenticate before
parsing. Request envelope is `{"version":1,"action":"status"}`. Response envelope
is `{"ok":true,"data":...}` or `{"ok":false,"error":"..."}`. The CLI prints bare
compact status JSON so Orca does not need socket privileges different from the
owner. `RESOURCE_SCHEDULER_SOCKET` chooses a client transport path, not a policy.

Status fields:

- `schema_version:1`, `policy_version`, durable monotonic `revision`, Unix
  `generated_at`, `connected`, `mode`, `capabilities`, `errors`.
- `jobs`: every active/queued/unknown job; `history`: newest bounded completions.
  Each includes immutable UUID `id`, per-job `revision`, safe `label`, `owner_uid`,
  `agent`, `worktree`, `project`, `origin`, `category`, `priority`, sharing `mode`,
  `slurm_job_id`, lifecycle `state`, timestamps, `wait_reason`, `exit_code`,
  `cleanup`, `requested`, `allocation`, `vram_estimate`, `observed`, `model`, and
  recent structured `events`. `systemd` correlation is through Slurm's cgroup
  path/job ID under its stepd scope, not a fabricated per-job systemd unit.
- `requested`: `cpu`, `ram_mib`, `vram_mib`; unknown exclusive peak is null.
  `allocation.vram_mib` is null before release and the frozen budget afterward.
  `observed`: nullable `cpu_percent`, `cpu_usec`, `ram_mib`, `ram_peak_mib`,
  `vram_mib`, `vram_peak_mib`, `gpu_utilization_percent`, `oom_kill`,
  `attribution_confidence`, and sample timestamp. Device utilization is not
  attributed to a job; `gpu_utilization_percent` stays null without evidence.
- CPU telemetry includes `logical_cpus` for whole-host usage gauges, separate from
  the configured Slurm `capacity` and `effective_background_capacity`. Missing
  host topology remains null. `host_actual`, `actual` and `external` are logical
  CPU equivalents, not percentages or reserved CPU counts.
- `telemetry`: `sampled_at`, `errors`, CPU/RAM/GPU readings, PSI CPU/memory/I/O,
  swap used, declared reservations and managed actual usage. CPU also exposes
  configured `capacity`, `effective_background_capacity`, `game_active` and
  `game_protection_errors`. Missing data is null, never a zero utilization claim.
- `truncated`: `events` boolean and number of omitted oldest `history` records.
  Public events keep the newest eight per job and omit bulky snapshots; private
  state keeps64, journal carries full admission snapshots. Responses stay below
  900000 bytes before envelope; history/events compact first, preserving every
  active job. Submission is capped at256 nonterminal jobs.

The daemon runs sequential reconciliation/release: at most one held allocation
is released per poll, and another waits until Slurm accounts for the previous
one. Native Slurm pending/running/completing/terminal state is authoritative.
Unknown/missing allocation identity blocks admissions and retains reservations.
A release does not imply a workload started. No estimated queue position/finish
time is fabricated.

Controls use actions `cancel|terminate`, immutable `id`, exact job `revision` and
`confirm:true`. Queued cancellation and running termination are distinct. The
reply marks the action pending; terminal cleanup is confirmed only by Slurm.
`pause|resume` requires `confirm:true` and affects admission, not running processes.
Changing priority after submission is not yet supported (`priority:false`).
Safe recent lifecycle events are included in status; no arbitrary journal text
or job stdout is exposed in that API. The foreground client uses owner-only
`output` with byte offsets and <=32KiB per stream per request. `submit` transports
the private payload and requested metadata. `model-event` reports cooperative
`loading|ready|busy|idle|unloaded` with job ID and safe model label.

## Persistence, diagnostics and bounds

Private state is atomically written/fsynced separately from journal. UUID and
payload are durable before `sbatch`; an interrupted submission is recovered by
Slurm's UUID name, never by guessing a new allocation. If Slurm has lost an old
allocation beyond its controller retention, it becomes `unknown` and requires
operator investigation. It is not marked complete from elapsed time or PID absence.
A daemon restart does not cancel Slurm jobs or reassign their IDs. Reconciliation and
controls also verify the native Slurm UUID job name, rejecting a reused numeric
allocation ID rather than acting on an unrelated job.

Structured native journald events use `SYSLOG_IDENTIFIER=resource-scheduler`,
`RESOURCE_EVENT`, `RESOURCE_JOB_ID`, `RESOURCE_POLICY_VERSION` and JSON `MESSAGE`.
Events cover submission, wait-reason changes, admission/start, model reports,
cancellation, pressure holds, CPU protection, completion and active samples every
30seconds. Final summaries carry queue/runtime, result, cleanup and peak readings.
Use, for example:

```sh
journalctl SYSLOG_IDENTIFIER=resource-scheduler RESOURCE_JOB_ID=FULL_JOB_ID -o json
resource-status --json > resource-summary.json
```

The Nix service config owns persistent journal size/age retention. Defaults for
private completed history are500 jobs; each stream stores at most8MiB, events64
per job, and private execution payloads are removed on terminal cleanup. Eviction
removes old output/result directories. Output is not included in exported status.
Export compact summaries before the bounded store/journal rotates when long-term
analysis is required. Sampling can miss short GPU peaks; memory.peak and cpu.stat
are collected from the job cgroup where available, including final bootstrap
readings. Host CPU activity uses `/proc/stat` deltas across two samples; managed
CPU activity comes from cgroup CPU time deltas divided by elapsed time. Both use
logical CPU-seconds per second, not physical core performance. External CPU is
derived only when both measurements are available. GPU `external_mib` is device
usage minus measured managed compute-process usage when attributable. Swap
`pages_in`/`pages_out` are cumulative kernel counters, not invented rates. Unknown metrics/gaps remain explicit. There is no automatic policy tuning.

## Nix service and migration contract

`pkgs.callPackage ./pkgs/resource-scheduler/package.nix {}` supplies
`resource-run`, `resource-status`, `resource-control`, `resource-model`,
`resource-profile`, `resource-job`, `resource-notify` and
`resource-scheduler`. The daemon entrypoint is
`resource-scheduler daemon --config /path/to/policy.json`. JSON keys/defaults are
listed in `DEFAULTS` in `resource_scheduler.py`; privileged settings come only
from that root-owned configuration. Required binaries are pinned by the package:
Python, Slurm CLI, Docker and util-linux; NVIDIA tools use the host driver path
or `/run/current-system/sw/bin`, where NixOS installs `nvidia-smi`.

Single-node requirements: Slurm `select/cons_tres`, `CR_Core_Memory`,
`GresTypes=gpu,shard`, node `Gres=gpu:1,shard:<physicalMiB>`, paired GPU/shard
`gres.conf` entries for the same NVIDIA device (one shard=1MiB), task/cgroup,
proctrack/cgroup and cgroupv2 core/RAM/device constraints, no swap, CPU controller
enabled, jobacct_gather/cgroup, root-only resource partition, no preemption/requeue,
`RootOnly=YES` plus `EnforcePartLimits=ALL`, and controller retention long enough
for daemon recovery. Root bootstrap jobs
must not run caller shell code before privilege drop. Do not expose Munge into
sandboxes or create another CPU/GPU scheduling ledger.

Cutover requires draining legacy GPU reservations, stopping/rebuilding old client
sandboxes, installing the new service/config/client mount and selecting
`/etc/resource-scheduler/mode=slurm`. Startup refuses locked legacy records; it
does not delete them. This gate alone cannot stop an old unmodified client in an
unrestarted sandbox, so refreshing all clients is required before activation.
The legacy GPU package accepts `unifiedScheduler` and dispatches by that marker;
without it legacy behavior is unchanged, and a Slurm marker with no adapter fails
closed. Compatibility requests add1Slurm CPU/4GiB RAM with a warning: use
`resource-run` to provide better peak estimates. `gpu-game` becomes game priority
with whole-GPU allocation. The old telemetry service must be disabled at cutover.
Rollback also requires draining the active authority first. Never run both queues
against physical capacity at once.

## Verification and outstanding activation checks

`python3 -m unittest discover -s pkgs/resource-scheduler -v` and the package's
`tests.scheduler` derivation exercise joint contention, no double counting,
compatible overlap, missing telemetry, game/exclusive ordering, dynamic exclusive
budgets with desktop use, pressure stability, quotas/restore/failure, immutable
control IDs/revisions, cancellation confirmation, recovery, native exit parsing,
secret exclusion, malformed/oversized requests and worst-case public status bounds.
The existing GPU scheduler tests remain unchanged and must pass.

The expanded NixOS VM check passed against Slurm25.11.8 in63.68seconds. It uses
real Slurm, cgroupv2 and Docker with a fake
non-GPU device to verify host/sandbox execution, privilege dropping, exact exit
status, limits, cleanup, daemon restart, nonroot raw-submission rejection,
socket/key permissions and CPU gaming protection. It also
verifies real Slurm shard/whole-GPU allocation exclusion using the fake
device. It does not prove physical NVIDIA device behavior, actual VRAM attribution, desktop
responsiveness, sustained pressure, or host deployment/migration. Real GPU
acceptance must use the existing shared GPU reservation and an isolated test
configuration; production admission stays on the existing authority until the
explicit cutover. Do not infer real-device safety from simulated telemetry.

## Job inspection and completion delivery

`resource-run` prints the immutable job ID, final state, actual exit code and an
inspection command. It returns the command's exit code. Reattach to an existing
job without resubmitting:

```sh
resource-job inspect JOB_ID
resource-job inspect JOB_ID --json
resource-job logs JOB_ID --follow
resource-job logs JOB_ID --stream stderr
resource-job wait JOB_ID --timeout 120 --json
resource-job notifications
resource-job ack JOB_ID --confirm
```

Inspection includes requests, allocation, observed usage, outcome, lifecycle
events and output metadata. Logs preserve stdout/stderr and support byte offsets
(`--stdout-offset`, `--stderr-offset`). `logs --json` emits newline-delimited
response objects with chunks, next offsets and output metadata. Stored output is
capped at 8 MiB per stream; metadata reports known truncation. Output is retained
with the job, not an unlimited archive. Successful log reads exit zero; `wait`
returns the job's exit code. Observation timeout returns 124 without cancelling
or resubmitting the job.

New submissions preserve the submitting Orca session identity. The foreground
client heartbeats a 30-second waiter lease and acknowledges terminal results;
normal foreground completions do not generate redundant notifications. A detached
completion becomes eligible after both that lease and a 10-second completion
grace expire. `resource-job wait` can reattach and acknowledge the result.

The unprivileged `resource-job-notifications` user service resolves the exact
local structured Orca session and sends a completion message with inspection
commands. It never launches a replacement agent or retries the workload. Session
matching does not use project names, paths or terminal titles. Terminal-only,
missing or ambiguous sessions fall back to the plugin's **Completions to review**
inbox. Delivery acceptance is not proof the agent has read or acted on a message.

The scheduler persists a delivery claim before contacting Orca. A lost receipt
or restart during sending leaves an uncertain outcome in the inbox rather than
blindly waking the agent again. Orca being unavailable before a send leaves the
notification pending for a later attempt. Pre-upgrade history is not replayed.
Use **Mark reviewed** or `resource-job ack` after handling an inbox outcome.
Unresolved outcomes retain their job and output through normal history pruning;
500 unresolved outcomes block new submissions until reviewed (already admitted
jobs can still finish). This is bounded retention, not an exactly-once transport
guarantee. Notifications do not authorize retries or resuming cancelled tasks.

## Optional repository and Orca ownership labels

Workers should declare ownership when it applies and is known. None of these
flags is required for submission:

```sh
resource-run --cpu 2 --ram 4GiB --project riso-scene-workflow \
  --repo riso-scene-workflow --worktree-name "Vue app" \
  --parent-worktree-name "UI migration" --name "Vue checks" -- npm test
```

The queue shows the repository and parent, with `↳ Vue app` beneath the parent.
Top-level worktrees omit `--parent-worktree-name` and show their own name directly.
Names are saved with the job, so history keeps the submitted context even if an
Orca card is later renamed or closed. Names are searchable and appear in the job
inspector and confirmation modal. Old clients and jobs without labels still work.

`--worktree ID` optionally supplies the exact Orca worktree identity when
`ORCA_WORKTREE_ID` is absent; that identity supports the existing Open worktree
control. Display names never substitute for identity or change admission policy.
Use the session CLI's `worktree current --json` and, for a child, inspect its
`parentWorktreeId` using `worktree show --worktree id:ID --json`. Do not infer
parentage from branches or folder layout. Omit unknown metadata; outside Orca,
repository-only declarations are valid. `--project` retains its separate stable
logical/profile key. New display labels accept 1–160 UTF-8 bytes without control
characters and must not contain secrets.

## Adaptive RAM admission and automatic workload learning (policy 5)

This is generic: no repository, application or model names appear in policy code.
Home enables `services.resourceScheduler.adaptiveRam`; other hosts remain strict
by default. `resource-run --memory-policy strict` retains full unused peak RAM
reservations for that job. `--memory-policy adaptive` uses adaptive accounting
only on a host that enables it. Neither flag changes CPU or GPU admission, Slurm
`--mem`, the hard cgroup RAM limit, or automatic retries.

Admission starts with `MemAvailable`, subtracting the existing desktop reserve,
running-job growth allowances, a host memory-growth buffer, and the **full**
incoming RAM request. No swap is counted. Pending/unknown jobs still prevent a
second release. The sum of full Slurm RAM allocations must also fit the configured
Slurm `RealMemory`; estimated spare host RAM cannot override this second limit.

A running adaptive job retains its full unused allowance for at least 30 seconds
of uninterrupted cgroup observations and at least three samples. Missing current
or peak readings, stale readings, strict jobs and unresolved profile OOMs retain
full unused allowances. Thereafter its additional allowance is:

```
baseline = max(current RAM, lifetime observed peak, learned full-run peak)
margin = max(1 GiB, 25% of baseline, recent positive growth rate × 15 seconds)
allowance = min(unused hard limit, max(0, baseline + margin - current RAM))
```

The growth rate is the maximum positive rate in up to 32 recent observations.
The independent host buffer projects the latest decrease in MemAvailable over
15 seconds; this deliberately errs conservatively during concurrent growth.
The lifetime peak remains protected even after unloading or between phases.
New admissions stop on unavailable memory PSI, full PSI avg10 ≥1%, some PSI
avg10 ≥5%, unavailable/stale memory readings, or desktop headroom shortage.
The existing healthy-period gate applies before resuming after pressure. Running
ordinary jobs are never killed or suspended by this policy. Existing opted-in
exploration retains its separately documented emergency cleanup behavior.

**This is intentional, bounded-risk host memory overcommit.** An unobserved late
phase or synchronized growth can still exhaust available host RAM. The numbers
above are policy choices, not kernel guarantees. In particular, closing admission
does not reclaim RAM from already-running jobs. Use strict mode for jobs where
this risk is inappropriate, and for commands whose heavy work runs through an
external daemon/server and is not attributable to the submitting cgroup.

Automatic identity uses a versioned HMAC of exact argv, repository/project scope,
relative working directory, requested CPU parallelism, category, and host versus
sandbox execution. Git common-directory discovery occurs in the client, never
in the privileged daemon; linked worktrees share repository scope. Without Git,
the working directory scopes the fallback. Explicit logical project IDs override
the inferred repository key. The daemon keeps its random HMAC key only in private
persistent state. Arguments, shell snippets and credentials are not copied into
public profiles. `auto-v1` is reserved for this generated namespace. Automatic
identity intentionally does not guess which arguments are input-size settings.
Changed arguments split histories; environment, file contents and executable
updates can change behavior without changing the signature. Supply explicit
versioned variants when these matter. No automatic phase labeling is claimed.

Each exact identity retains up to 32 complete successful RAM peaks and durations.
Adaptive estimates use the maximum from the last 30 days after at least three
complete runs. This is an evidence threshold, not a statistical confidence claim.
Failed, cancelled, missing-telemetry and unmanaged runs cannot lower estimates.
Confirmed RAM OOM immediately disables reduced allowances for matching workloads
before further admission; three complete successes are required to restore them.
Profiles remain bounded at 128. Inactive automatic records may be evicted; active
and explicit records are protected. If all slots are protected, automatic learning
is omitted for the new job rather than refusing ordinary work. Existing historical
jobs are not retrospectively assigned invented workload identities.

The plugin reports RAM admission policy, job growth allowance, host growth buffer,
and Slurm RAM capacity separately from actual usage and reserved limits. Inspect
an individual job to see its allowance basis and matching completed sample count.
Deploy through the normal authorized system switch; the source change alone does
not change admission for the live queue. Old queued scripts keep their original
client/helper paths; they gain the daemon's accounting, but only new clients can
perform Git scope discovery.

### Research informing the policy

Three independent GPT-6.1 Sol reviews informed this implementation. The practical
choice is conservative peak/growth accounting rather than an opaque predictor:

- [Linux MemAvailable](https://docs.kernel.org/filesystems/proc.html) is already an estimate including reclaimable memory; don't subtract current usage twice or count swap as RAM.
- [Linux PSI](https://docs.kernel.org/accounting/psi.html) reports experienced stalls, not future memory demand.
- [cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html) distinguishes observed peaks, throttling and hard limits; observed peaks are not future bounds.
- [Slurm consumable resources](https://slurm.schedmd.com/cons_tres.html) still schedules allocated RAM. We neither inflate RealMemory nor raise AllowedRAMSpace.
- [Kubernetes VPA](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/pkg/recommender/logic/recommender.go) and [Google Autopilot](https://john.e-wilkes.com/papers/2020-EuroSys-Autopilot.pdf) support learning from peak histories with margins and explicit risk tradeoffs; our small-history estimator intentionally makes no p99 claim.
- [Git common-directory semantics](https://git-scm.com/docs/git-rev-parse) allow worktree-independent repository identity without reading remote URLs.

### Experimental permissive large-GPU lane

`services.resourceScheduler.largeGpuLane` enables one deliberately permissive
large-job lane (enabled in the home configuration). It is generic: exclusive GPU
jobs and jobs requesting at least 8 GiB (or half of configured device VRAM,
whichever is smaller) qualify, or a
worker can declare `--large-gpu` for a known large workload. Strict-memory jobs
and exploratory probes do not qualify; `--large-gpu --memory-policy strict` is
rejected. A declared large job still needs a positive GPU request.

The first large job precedes ordinary queued work and may be released despite
ordinary pressure holds, startup guards, expected memory demand, and unused RAM
or VRAM reservations. It does **not** need its declared peak to fit current free
memory. Another large job waits while any large job is pending, running or
unresolved. Small work still uses normal admission. Operator pause and confirmed
cancellation remain authoritative. Human run-next/force controls retain their
explicit override semantics; the automatic single-slot rule is not a prohibition
on deliberate human overrides.

Only critical resource gates remain: at least **1 GiB available host RAM** and
**512 MiB free GPU memory**, memory PSI full avg10 below **10%** and some avg10
below **50%**, fresh available telemetry, and reconciled Slurm identities. These
are deliberately aggressive experimental policy values, not a guarantee against
OOM or desktop stalls. They differ from the 4 GiB desktop reserve used by ordinary
admission. Nothing automatically terminates another owner's work to make room.

Policy 6 runs this lane through a **managed systemd service outside Slurm's
reservation accounting**. The same queue remains the sole admission authority.
The service enforces the original CPU quota and hard RAM limit, forbids swap,
and retains foreground descendant cleanup, output, profiles and notifications.
GPU VRAM remains cooperative, not a physical fence. The original submitting
sandbox is preserved; a missing sandbox fails instead of falling back to the host.
This differs from the explicitly unmanaged Run on host / Run in sandbox overrides.

For queued or released-but-unstarted Slurm jobs, the daemon first holds the
allocation, verifies its UUID and held state, persists the transition, cancels it,
and waits for confirmed cancellation before starting the command once. Critical
headroom and operator pause are checked again immediately before startup. A job
that has already started in Slurm is never migrated. On restart, ambiguous service
starts are reconciled rather than retried. Turning the lane off holds any transition
that has not launched yet. Existing Slurm force-run overrides retain their meaning.

Pending ordinary Slurm grants retain their full budget allowances but no longer
impose an unconditional hold on every later job. Slurm RAM capacity counts only
Slurm allocations; managed lane jobs still count in host growth, CPU and GPU
admission accounting. This does not make every waiting job admissible: a zero-VRAM
submission is CPU-only, and a 12 GiB RAM request can still legitimately wait for
host headroom. Declare a positive VRAM budget and `--large-gpu` for a known large
runtime when applicable; the daemon never infers this from repository names.

[systemd resource controls](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control)
provide `CPUQuota`, `MemoryMax` and `MemorySwapMax`;
[`OOMPolicy=kill`](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#OOMPolicy=) enables whole-job OOM handling. This avoids
inflating Slurm capacity or shrinking a job's hard limit to force admission.

### Numeric project exceptions (policy 7)

`services.resourceScheduler.largeLaneProjectIds` is an operator-configured list
of decimal project fingerprints. `resource-status --json` and `resource-job inspect`
expose each job's `lane_project_id`. The identifier is derived generically from
its exact stable `--project` value using the versioned SHA-256 namespace and the
first 128 bits, rendered in decimal. It is an identifier, not an authentication
secret. Worktrees sharing that project value share the identifier. No project
names or command-name heuristics appear in the admission implementation.

Allowlisted projects automatically qualify even with a zero-VRAM request or an
exploratory submission. They share the **same one active slot** with every other
large-lane workload; there is not one slot per identifier. Explicit strict-memory
submissions still opt out. Existing queued jobs qualify without resubmission;
running Slurm jobs are not moved. Removing an identifier does not free the slot
occupied by a managed lane job that is still running.

Exploratory exceptions retain their 30-minute limit, failure/profile reporting,
and stop on the lane's critical resource thresholds or unavailable telemetry.
Their cleanup targets the systemd service, never the cancelled Slurm allocation.
CPU/RAM limits, original execution namespace, operator pause and startup checks
remain unchanged. The home configuration holds the numeric selections only.

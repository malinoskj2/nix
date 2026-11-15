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
The policy never suspends processes or claims suspension frees memory.

## Explicit waiting-job controls

All three controls require the immutable ID, current revision, owner authorization
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

Unmanaged processes run in a unique root-created transient systemd service using
an immutable privileged bootstrap, followed by privilege drop and `no_new_privs`.
No submitted command or environment enters systemd unit arguments. The subreaper
and systemd control group retain descendant lifetime and termination, but do not
reserve resource capacity. The same job ID, bounded stdout/stderr stream and files
remain available to the submitting CLI and plugin. `execution: "host"` and
`systemd_unit` identify this mode; its `allocation` is null. Its usage is external
to Slurm, and it never contributes to queue reservation totals or game CPU quotas.
Original submission origin remains recorded. Processes receive
`RESOURCE_EXECUTION_MODE=unmanaged-host` and `RESOURCE_HOST_JOB_ID`, not reservation
or sandbox-instance markers. Runtime files and output stay on the host.

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
`resource-run`, `resource-status`, `resource-control`, `resource-model` and
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

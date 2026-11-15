# GPU coordination

These legacy rules apply before `/etc/resource-scheduler/mode` contains `slurm`.
After the drained cutover, follow the shared workstation resource rules and use
`resource-run`; compatibility GPU commands must forward to that same authority.

- Before loading a local model, rendering with the GPU, running GPU-heavy tests, or launching a game, acquire a reservation through the shared scheduler. Ordinary browsers and compositors do not need reservations.
- For workloads with a known peak, run `gpu-run --vram 4GiB --name "job description" -- command`, replacing the budget with a conservative estimate including model weights, inference/KV caches, activations, temporary working memory and a safety margin for the chosen context, batch size or resolution. Shared reservations may run concurrently when their peak budgets fit; do not budget only the memory needed to load the weights. Use `gpu-run --exclusive --name "job description" -- command` for video generation or uncertain requirements. Games use `gpu-game --name "game" -- command`.
- Keep the reserved command in the foreground through GPU cleanup. Persistent model servers must stay inside their reservation until stopped or fully unloaded; pausing a process does not release VRAM. Run commands directly when already inside a reservation (`GPU_LEASE_ID` is set); do not acquire a nested reservation.
- Wait for queued reservations. Use `gpu-status` (or `gpu-status --json`) to explain who holds the GPU and why a job is waiting. Games take priority over queued model work; active jobs finish normally.
- Never bypass the scheduler because utilization looks low, change `GPU_SCHEDULER_DIR`, delete lease files, reduce desktop headroom, or stop someone else's workload to obtain a slot. If the scheduler or shared sandbox mount is unavailable, report the problem and stop GPU work.

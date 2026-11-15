// Deterministic, synthetic data. Never imported by the production worker or production entry.
const NOW = 1794747600;
const id = (n) => String(n).padStart(32, '0');
const job = (n, patch) => ({ id: id(n), revision: 1, label: `Workload ${n}`, owner_uid: 1000, agent: 'Codex', worktree: '/home/jesse/projects/nix', project: 'nix', origin: 'workstation', category: 'build', priority: 'background', mode: 'shared', state: 'queued', created_at: NOW - 120, started_at: null, ended_at: null, slurm_job_id: String(8000 + n), requested: { cpu: 4, ram_mib: 4096, vram_mib: 0 }, observed: null, wait_reason: '', exit_code: null, cleanup: null, ...patch });
export function fixture(name = 'overlap') {
  const base = { schema_version: 1, policy_version: '1', revision: 42, generated_at: NOW, connected: true, mode: 'normal', capabilities: { cancel: true, terminate: true, force_run: true, run_next: true, run_host: true, run_sandbox: true, pause: true, resume: true, priority: false, unload: false }, telemetry: { sampled_at: NOW, cpu: { capacity: 12, reserved: 8, actual: null, external: null }, ram: { total_mib: 31744, available_mib: 6144, reserved_mib: 14336, managed_actual_mib: null, headroom_mib: 4096 }, gpu: { total_mib: 32768, used_mib: 15360, free_mib: 17408, reserved_mib: 12288, managed_actual_mib: null, utilization_percent: 73, headroom_mib: 3072 }, pressure: {}, errors: [] }, jobs: [], history: [], errors: [] };
  if (name === 'empty') { base.telemetry.cpu.reserved = 0; base.telemetry.ram.reserved_mib = 0; base.telemetry.gpu.reserved_mib = 0; return base; }
  base.jobs = [
    job(1, { label: 'NixOS rebuild', state: 'running', created_at: NOW - 720, started_at: NOW - 540, requested: { cpu: 6, ram_mib: 8192, vram_mib: 0 }, observed: { cpu_percent: 481, ram_peak_mib: 6291, vram_peak_mib: null, attribution_confidence: 'cgroup high-water mark' } }),
    job(2, { label: 'Portrait · on-demand inference', state: 'running', category: 'inference', agent: 'Claude', project: 'studio', worktree: '/home/jesse/projects/studio/portrait', started_at: NOW - 180, requested: { cpu: 2, ram_mib: 6144, vram_mib: 12288 }, observed: null }),
    job(3, { label: 'Integration verification', origin: 'agent-sandbox-test', requested: { cpu: 6, ram_mib: 10240, vram_mib: 0 }, wait_reason: 'Needs 10 GiB RAM; 6 GiB is available before safety headroom and unused reservations.' }),
    job(4, { label: 'Scene render · exclusive', category: 'render', agent: 'Claude', worktree: '/home/jesse/projects/studio/scene', project: 'studio', mode: 'exclusive', requested: { cpu: 4, ram_mib: 8192, vram_mib: 32768 }, wait_reason: 'Waiting for exclusive GPU access; a managed GPU workload is still running.' })
  ];
  base.history = [job(5, { label: 'Package unit tests', state: 'completed', created_at: NOW - 3600, started_at: NOW - 3500, ended_at: NOW - 3200, exit_code: 0, cleanup: 'complete' }), job(6, { label: 'Render validation', category: 'render', state: 'failed', created_at: NOW - 2700, started_at: NOW - 2600, ended_at: NOW - 2400, exit_code: 1, cleanup: 'complete' })];
  for (const item of [...base.jobs, ...base.history]) {
    item.events = [{ timestamp: item.created_at, event: 'submission' }];
    if (item.started_at) item.events.push({ timestamp: item.started_at, event: 'start', queue_seconds: item.started_at - item.created_at });
    if (item.wait_reason) item.events.push({ timestamp: NOW - 2, event: 'waiting', reason: item.wait_reason, snapshot: base.telemetry });
    if (item.ended_at) item.events.push({ timestamp: item.ended_at, event: 'completion', exit_code: item.exit_code, cleanup: item.cleanup });
  }
  if (name === 'ram') base.jobs = [base.jobs[0], base.jobs[2]];
  if (name === 'vram') { base.jobs = [base.jobs[1], job(7, { label: 'Texture inference', category: 'inference', requested: { cpu: 2, ram_mib: 2048, vram_mib: 24576 }, wait_reason: 'Needs 24 GiB VRAM; 14 GiB remains after desktop headroom.' })]; }
  if (name === 'exclusive') base.mode = 'exclusive_pending';
  if (name === 'game') { base.mode = 'game_pending'; base.jobs.push(job(8, { label: 'Game session', category: 'game', priority: 'game', mode: 'exclusive', requested: { cpu: 4, ram_mib: 8192, vram_mib: 32768 }, wait_reason: 'Game has priority over queued background GPU work; active jobs finish normally.' })); }
  if (name === 'resident') { base.jobs[1].label = 'Model server · residency reservation'; base.jobs[1].wait_reason = ''; base.telemetry.gpu.utilization_percent = 0; base.errors.push('Model residency state is unavailable. A running reservation may cover an idle model server; zero device compute does not release its budget.'); }
  if (name === 'partial') { base.telemetry.gpu = {}; base.telemetry.errors = ['NVIDIA telemetry unavailable; GPU values are unknown.']; }
  if (name === 'hold') base.mode = 'manual_hold';
  return base;
}
export const fixtureTime = NOW * 1000;
export const jobId = id;

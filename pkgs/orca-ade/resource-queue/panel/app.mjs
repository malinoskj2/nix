import { render } from './view.mjs';
import { journalQuery, freshness, eligibleActions } from '../src/model.mjs';
const app = document.getElementById('app');
const state = { snapshot: null, loading: true, error: '', tab: 'queue', filters: {}, selected: null, showFilters: false, samples: [], identities: [], logs: [], logsError: '', logsPaused: false, pending: false, confirm: null, fixture: false };
let timer, attempt = 0, loading = false, disposed = false, lastFocus;
// Keep pointer targets alive through mouse-up/click when a poll completes mid-press.
const activePointers = new Set();
let redrawDeferred = false;
app.addEventListener('pointerdown', (event) => activePointers.add(event.pointerId));
function releasePointer(event) {
  activePointers.delete(event.pointerId);
  if (!activePointers.size && redrawDeferred) requestAnimationFrame(() => {
    if (redrawDeferred && !disposed) draw();
  });
}
window.addEventListener('pointerup', releasePointer);
window.addEventListener('pointercancel', releasePointer);
window.addEventListener('blur', () => {
  activePointers.clear();
  if (redrawDeferred && !disposed) draw();
});
function draw() {
  if (activePointers.size) { redrawDeferred = true; return; }
  redrawDeferred = false;
  const active = document.activeElement;
  const focus = active?.id;
  const focusSelector = active?.dataset.action ? `[data-action="${CSS.escape(active.dataset.action)}"]` : active?.dataset.job ? `[data-job="${CSS.escape(active.dataset.job)}"]` : active?.dataset.filter ? `[data-filter="${CSS.escape(active.dataset.filter)}"]` : null;
  const range = active?.selectionStart == null ? null : [active.selectionStart, active.selectionEnd];
  const inspectorScroll = app.querySelector('.inspector')?.scrollTop;
  app.innerHTML = render(state);
  app.setAttribute('aria-busy', String(state.loading));
  if (state.confirm) for (const child of app.children) child.inert = !child.classList.contains('dialog-backdrop');
  if (focus) {
    const next = document.getElementById(focus);
    next?.focus({ preventScroll: true });
    if (range) next?.setSelectionRange?.(...range);
  }
  if (!focus && focusSelector) app.querySelector(focusSelector)?.focus({ preventScroll: true });
  if (state.confirm && !app.querySelector('[role="dialog"]')?.contains(document.activeElement)) {
    (app.querySelector('[role="dialog"] button:not(:disabled)') || app.querySelector('[role="dialog"]'))?.focus({ preventScroll: true });
  }
  const inspector = app.querySelector('.inspector');
  if (inspector && inspectorScroll) inspector.scrollTop = inspectorScroll;
}
const request = (name, input = {}) => {
  if (!globalThis.orca?.plugin) return Promise.reject(new Error('Open this panel in Orca to connect to the scheduler.'));
  return orca.plugin.request(name, input, { timeoutMs: 12_000 });
};
function observe(snapshot) {
  const last = state.samples.at(-1);
  if (last?.at === snapshot.at) return;
  if (last && Date.parse(snapshot.at) - Date.parse(last.at) > 10_000) state.samples.push({ at: snapshot.at, gap: true });
  state.samples.push({ at: snapshot.at, running: snapshot.jobs.filter((j) => j.state === 'running').length, waiting: snapshot.jobs.filter((j) => j.state === 'waiting').length, ramReserved: snapshot.capacity.ram.reserved, ramActual: snapshot.capacity.ram.actual, vramReserved: snapshot.capacity.gpu.reserved, vramActual: snapshot.capacity.gpu.actual });
  state.samples = state.samples.slice(-60);
}
async function refresh() {
  if (loading || state.fixture || disposed) return;
  loading = true;
  try {
    const snapshot = await request('queue.status');
    state.snapshot = snapshot;
    state.error = '';
    state.loading = false;
    attempt = 0;
    observe(snapshot);
    if (state.selected && !snapshot.jobs.some((j) => j.id === state.selected)) { state.selected = null; state.confirm = null; }
    if (state.selected && !state.logsPaused) await readLogs();
  } catch (error) {
    state.error = error.message;
    state.loading = false;
    attempt = Math.min(attempt + 1, 4);
    if (!state.samples.at(-1)?.gap) state.samples = [...state.samples, { at: new Date().toISOString(), gap: true }].slice(-60);
  } finally { loading = false; draw(); }
}
// v1 has no event subscription. Poll only while visible, bounded 2s to 30s with backoff.
async function poll() {
  clearTimeout(timer);
  if (disposed || state.fixture) return;
  if (document.visibilityState !== 'hidden') await refresh();
  timer = setTimeout(poll, Math.min(30_000, 2000 * 2 ** attempt));
}
async function readLogs() {
  const job = state.snapshot?.jobs.find((item) => item.id === state.selected);
  state.logs = job?.logs?.slice(-100) ?? [];
  state.logsError = state.logs.length ? '' : 'No lifecycle events retained.';
}
function confirm(action, jobId = state.selected) {
  const job = state.snapshot.jobs.find((j) => j.id === jobId);
  if (state.fixture || state.error || freshness(state.snapshot) !== 'live') return;
  if (!eligibleActions(state.snapshot, ['cancel', 'terminate', 'force-run', 'run-next', 'run-host', 'run-sandbox'].includes(action) ? job : null).includes(action)) return;
  const info = {
    'run-sandbox': { title: `Run “${job?.label}” in the sandbox?`, description: 'Cancel the waiting Slurm allocation, then run this command in its original submitting sandbox, outside Slurm.', consequence: 'No queue resource reservation, CPU/RAM/VRAM budget enforcement or headroom checks apply. The sandbox must still be running; failure to enter it stops execution. Output and termination remain available here.' },
    'run-host': { title: `Run “${job?.label}” on the host?`, description: 'Cancel the waiting Slurm allocation, then run this command directly on the host as your user, outside the sandbox and Slurm.', consequence: 'CPU, RAM, VRAM and headroom are not reserved or limited. The working directory and command dependencies must be accessible on the host. Output and termination remain available here.' },
    'force-run': { title: `Run via Slurm now: “${job?.label}” now?`, description: 'Release this job to Slurm immediately, overriding queue order, admission pause, pressure and headroom checks.', consequence: 'This can cause resource contention or memory pressure. Requested budgets and Slurm allocation limits still apply; the job may remain pending until Slurm can allocate it.' },
    'run-next': { title: `Run “${job?.label}” next?`, description: 'Move this job to the front of the waiting queue.', consequence: 'Normal resource, pressure and headroom checks still apply. Running jobs continue.' },
    cancel: { title: `Cancel “${job?.label}”?`, description: 'Remove this queued workload from admission.', consequence: 'The submitting command will receive the scheduler cancellation result.' },
    terminate: { title: `Terminate “${job?.label}”?`, description: 'Ask the scheduler to stop this running workload and its tracked descendants.', consequence: 'In-progress work may be lost. Resources remain reserved until the scheduler confirms cleanup.' },
    pause: { title: 'Pause new admissions?', description: 'Jobs already running will continue. Waiting jobs remain queued.', consequence: 'This does not suspend processes or reclaim memory.' },
    resume: { title: 'Resume new admissions?', description: 'Let the scheduler admit eligible queued work again.', consequence: 'Resource and desktop headroom checks still apply.' }
  }[action];
  state.confirm = { ...info, action, ...(['cancel', 'terminate', 'force-run', 'run-next', 'run-host', 'run-sandbox'].includes(action) ? { id: job.id, revision: job.revision, owner: `${job.owner.agent} / ${job.owner.worktree}` } : {}) };
  lastFocus = document.activeElement;
  draw();
  app.querySelector('[data-action="dismiss"]')?.focus();
}
async function execute() {
  if (!state.confirm || state.pending || state.fixture) return;
  state.pending = true;
  draw();
  try {
    const { action, id, revision } = state.confirm;
    const result = await request('queue.control', { action, ...(id ? { id, revision } : {}), confirm: true });
    if (result.accepted !== true) throw new Error('Scheduler did not confirm acceptance. Refresh before trying again.');
    state.snapshot = result.snapshot;
    state.confirm = null;
    state.actionMessage = 'Scheduler accepted the request. The panel shows its confirmed state.';
    state.error = '';
  } catch (error) {
    state.actionMessage = `Action failed: ${error.message}`;
    state.confirm = null;
    await refresh();
  } finally { state.pending = false; draw(); }
}
async function copy(text) {
  try { await navigator.clipboard.writeText(text); state.actionMessage = 'Copied to clipboard.'; }
  catch { state.actionMessage = 'Clipboard unavailable. Select the job ID or journal query to copy it.'; }
  draw();
}
function selectTab(tab) {
  state.tab = tab;
  state.selected = null;
  state.logs = [];
  state.logSearch = '';
  state.actionMessage = '';
  draw();
  document.getElementById(`tab-${tab}`)?.focus({ preventScroll: true });
}
app.addEventListener('click', async (event) => {
  const tab = event.target.closest('[data-tab]');
  if (tab) { selectTab(tab.dataset.tab); return; }
  const row = event.target.closest('[data-job], [data-related], [data-notification-job]');
  if (row) {
    if (row.dataset.notificationJob) state.tab = 'history';
    state.selected = row.dataset.job || row.dataset.related || row.dataset.notificationJob;
    state.logs = [];
    state.logSearch = '';
    await readLogs();
    draw();
    app.querySelector('.inspector')?.scrollIntoView({ block: 'nearest' });
    return;
  }
  const control = event.target.closest('[data-action]');
  if (!control || control.disabled) return;
  const action = control.dataset.action;
  const job = state.snapshot?.jobs.find((j) => j.id === state.selected);
  switch (action) {
    case 'refresh': await refresh(); break;
    case 'ackNotification': try { await request('queue.ackNotification', { id: control.dataset.notificationId, confirm: true }); await refresh(); } catch (error) { state.actionMessage = error.message; draw(); } break;
    case 'filters': state.showFilters = !state.showFilters; draw(); break;
    case 'clearFilters': state.filters = {}; draw(); break;
    case 'closeInspector': state.selected = null; draw(); break;
    case 'copyId': await copy(job.id); break;
    case 'copyJournal': await copy(journalQuery(job.id)); break;
    case 'openOwner': try { await request('queue.openOwner', { path: job.owner.worktree }); } catch (error) { state.actionMessage = error.message; draw(); } break;
    case 'logs': state.logsPaused = !state.logsPaused; if (!state.logsPaused) await readLogs(); draw(); break;
    case 'refreshLogs': await readLogs(); draw(); break;
    case 'dismiss': state.confirm = null; draw(); lastFocus?.focus(); break;
    case 'confirm': await execute(); break;
    default: if (['cancel', 'terminate', 'force-run', 'run-next', 'run-host', 'run-sandbox', 'pause', 'resume'].includes(action)) confirm(action, control.dataset.queueJob);
  }
});
app.addEventListener('keydown', (event) => {
  if (!event.target.matches('[role="tab"]')) return;
  const tabs = [...app.querySelectorAll('[role="tab"]')];
  const index = tabs.indexOf(event.target);
  const next = { ArrowRight: (index + 1) % tabs.length, ArrowLeft: (index + tabs.length - 1) % tabs.length, Home: 0, End: tabs.length - 1 }[event.key];
  if (next == null) return;
  event.preventDefault();
  selectTab(tabs[next].dataset.tab);
});
app.addEventListener('input', (event) => {
  if (event.target.id === 'job-search') { state.filters.search = event.target.value; draw(); }
  if (event.target.id === 'log-search') { state.logSearch = event.target.value; draw(); }
});
app.addEventListener('change', (event) => { if (event.target.dataset.filter) { state.filters[event.target.dataset.filter] = event.target.value; draw(); } });
document.addEventListener('keydown', (event) => {
  if (!state.confirm) return;
  if (event.key === 'Escape' && !state.pending) { state.confirm = null; draw(); lastFocus?.focus(); }
  if (event.key === 'Tab') {
    const buttons = [...app.querySelectorAll('[role="dialog"] button:not(:disabled)')];
    const first = buttons[0], last = buttons.at(-1);
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
    if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
  }
});
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') void poll(); else clearTimeout(timer); });
window.addEventListener('pagehide', () => { disposed = true; clearTimeout(timer); });
// Fixture rendering has a separate entry page; the production panel never reads query parameters.
export function showFixture(snapshot, options = {}) {
  clearTimeout(timer);
  Object.assign(state, { fixture: true, snapshot, loading: false, samples: [], error: '', ...options });
  if (state.selected) void readLogs();
  draw();
}
draw();
if (globalThis.orca) {
  request('queue.identities').then((result) => { state.identities = result.workspaces; draw(); }).catch(() => {});
  void poll();
} else { state.loading = false; state.error = 'Open this panel in Orca to connect to the scheduler.'; draw(); }

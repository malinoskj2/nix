import { test } from 'node:test';
import assert from 'node:assert/strict';
import { adaptStatus } from '../src/adapter.mjs';
import { eligibleActions } from '../src/model.mjs';
import { render } from '../panel/view.mjs';
import { fixture, fixtureTime } from './fixtures.mjs';
const page = (snapshot, patch = {}) => render({ snapshot, filters: {}, samples: [], identities: [], logs: [], ...patch }, fixtureTime);

test('waiting rows offer all run paths and reorder without nesting interactive controls', () => {
  const html = page(adaptStatus(fixture()));
  assert.match(html, /data-action="force-run"[^>]*>Run via Slurm/);
  assert.match(html, /data-action="run-host"[^>]*>Run on host/);
  assert.match(html, /data-action="run-sandbox"[^>]*>Run in sandbox/);
  assert.match(html, /data-action="run-next"[^>]*>Run next/);
  assert.match(html, /<\/button><div class="waiting-actions">/);
  const stale = page(adaptStatus(fixture()), { error: 'offline' });
  assert.match(stale, /data-action="run-host"[^>]*disabled/);
  assert.match(stale, /data-action="run-sandbox"[^>]*disabled/);
});

test('host handoff stays unmanaged through running and unknown states with termination available', () => {
  for (const state of ['pending', 'running', 'unknown']) {
    const raw = fixture();
    Object.assign(raw.jobs[2], { execution: 'host', host_phase: 'starting', state, allocation: null });
    const snapshot = adaptStatus(raw), job = snapshot.jobs[2];
    assert.deepEqual(eligibleActions(snapshot, job, fixtureTime), ['terminate']);
    assert.equal(job.effectiveBudget.ram, null);
    const html = page(snapshot, { selected: job.id });
    assert.match(html, /Host · unmanaged/);
    assert.match(html, /Requested resource budgets are not enforced/);
    assert.match(html, /Submitted from/);
  }
});

test('host handoff can be cancelled before launch and finished host work has no actions', () => {
  const raw = fixture();
  Object.assign(raw.jobs[2], { execution: 'host', host_phase: 'cancelling-slurm', state: 'pending' });
  let snapshot = adaptStatus(raw);
  assert.deepEqual(snapshot.jobs[2].actions, ['cancel', 'terminate']);
  raw.jobs[2].state = 'completed';
  snapshot = adaptStatus(raw);
  assert.deepEqual(snapshot.jobs[2].actions, []);
});

test('unmanaged host results do not enter reservation accuracy statistics', async () => {
  const { diagnostic, historyMetrics, orderJobs } = await import('../src/model.mjs');
  const snapshot = adaptStatus(fixture());
  const job = { ...snapshot.jobs[0], execution: 'host', state: 'completed', measured: { ram: 8, vram: 2 } };
  assert.equal(diagnostic(snapshot, job).jobs[0].execution, 'host');
  const metrics = historyMetrics([job]);
  assert.equal(metrics.count, 1);
  assert.equal(metrics.ramSamples, 0);
  assert.equal(metrics.queueSamples, 0);
  const [first, second] = snapshot.jobs.slice(2);
  first.queuePosition = 2; second.queuePosition = 1;
  assert.equal(orderJobs([first, second])[0].id, second.id);
});

test('sandbox run action requires a sandbox origin and advertised capability', () => {
  for (const origin of ['host', 'workstation', '', 'agent-sandbox-', 'agent-sandbox-test/invalid']) {
    const raw = fixture(); raw.jobs[2].origin = origin;
    assert.ok(!adaptStatus(raw).jobs[2].actions.includes('run-sandbox'));
  }
  const raw = fixture();
  assert.ok(adaptStatus(raw).jobs[2].actions.includes('run-sandbox'));
  delete raw.capabilities.run_sandbox;
  assert.ok(!adaptStatus(raw).jobs[2].actions.includes('run-sandbox'));
});

test('sandbox handoff and results stay unmanaged with lifecycle controls', async () => {
  const { diagnostic, historyMetrics } = await import('../src/model.mjs');
  for (const state of ['pending', 'running', 'unknown', 'completed', 'failed', 'cancelled']) {
    const raw = fixture();
    Object.assign(raw.jobs[2], { execution: 'sandbox', host_phase: 'starting', state, allocation: null });
    const snapshot = adaptStatus(raw), job = snapshot.jobs[2];
    assert.equal(job.execution, 'sandbox');
    assert.equal(diagnostic(snapshot, job).jobs[0].execution, 'sandbox');
    assert.deepEqual(job.actions, ['pending', 'running', 'unknown'].includes(state) ? ['terminate'] : []);
    assert.equal(job.effectiveBudget.ram, null);
    const html = page(snapshot, { selected: job.id });
    assert.match(html, /Sandbox · unmanaged/);
    assert.match(html, /Running in the submitting sandbox outside Slurm/);
    assert.doesNotMatch(html, /Running on the host outside Slurm and the sandbox/);
    assert.match(html, /Requested resource budgets are not enforced/);
    const metrics = historyMetrics([job]);
    assert.equal(metrics.ramSamples, 0);
    assert.equal(metrics.queueSamples, 0);
  }
  const raw = fixture();
  Object.assign(raw.jobs[2], { execution: 'sandbox', host_phase: 'cancelling-slurm', state: 'pending' });
  assert.deepEqual(adaptStatus(raw).jobs[2].actions, ['cancel', 'terminate']);
});

test('exploratory profiles and outcomes are visible without claiming a peak guarantee', async () => {
  const raw = fixture();
  Object.assign(raw.jobs[0], { explore: true, profile: { project: 'nix', name: 'probe', variant: 'v1' }, failure: 'gpu_oom_reported' });
  const snapshot = adaptStatus(raw), job = snapshot.jobs[0];
  const html = page(snapshot, { selected: job.id });
  assert.match(html, /Exploratory/);
  assert.match(html, /starting budget, not a measured peak/);
  assert.match(html, /nix \/ probe \/ v1/);
  assert.match(html, /gpu oom reported/);
  const { historyMetrics, diagnostic } = await import('../src/model.mjs');
  assert.equal(diagnostic(snapshot, job).jobs[0].profile.name, 'probe');
  assert.equal(historyMetrics([{ ...job, state: 'completed' }]).ramSamples, 0);
  raw.jobs[0].profile.name = '<img src=x onerror=alert(1)>';
  assert.doesNotMatch(page(adaptStatus(raw), { selected: job.id }), /<img src=x/);
});

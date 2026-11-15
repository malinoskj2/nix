import { test } from 'node:test';
import assert from 'node:assert/strict';
import { adaptStatus } from '../src/adapter.mjs';
import { eligibleActions } from '../src/model.mjs';
import { render } from '../panel/view.mjs';
import { fixture, fixtureTime } from './fixtures.mjs';
const page = (snapshot, patch = {}) => render({ snapshot, filters: {}, samples: [], identities: [], logs: [], ...patch }, fixtureTime);

test('waiting rows offer both run paths and reorder without nesting interactive controls', () => {
  const html = page(adaptStatus(fixture()));
  assert.match(html, /data-action="force-run"[^>]*>Run via Slurm/);
  assert.match(html, /data-action="run-host"[^>]*>Run on host/);
  assert.match(html, /data-action="run-next"[^>]*>Run next/);
  assert.match(html, /<\/button><div class="waiting-actions">/);
  const stale = page(adaptStatus(fixture()), { error: 'offline' });
  assert.match(stale, /data-action="run-host"[^>]*disabled/);
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

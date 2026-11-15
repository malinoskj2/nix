import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { adaptStatus } from '../src/adapter.mjs';
import { diagnostic, filterJobs } from '../src/model.mjs';
import { capacityCard, render } from '../panel/view.mjs';
const capture = JSON.parse(readFileSync(new URL('./backend-status-v1.json', import.meta.url)));
const raw = (name) => structuredClone(capture.scenarios[name]);
const html = (snapshot) => render({ snapshot, selected: snapshot.jobs[0]?.id, filters: {}, samples: [], identities: [], logs: [] }, Date.parse(snapshot.at));

test('actual two-sample backend counters retain correct CPU-equivalent and GPU GiB units', () => {
  const snapshot = adaptStatus(raw('telemetry_measured'));
  assert.equal(snapshot.capacity.cpu.actual, 1);
  assert.equal(snapshot.capacity.cpu.hostActual, 9.6);
  assert.equal(snapshot.capacity.cpu.hostTotal, 16);
  assert.equal(snapshot.capacity.cpu.external, 8.6);
  assert.equal(snapshot.capacity.cpu.attribution, 'sampled-kernel-counters');
  assert.equal(snapshot.jobs[0].measured.cpu, 100);
  assert.equal(snapshot.capacity.gpu.actual, 4);
  assert.equal(snapshot.capacity.gpu.external, 10);
  assert.match(capacityCard('cpu', snapshot.capacity.cpu), /1 CPU equiv\./);
  assert.match(capacityCard('cpu', snapshot.capacity.cpu), /9\.6 CPU equiv\./);
  assert.doesNotMatch(capacityCard('cpu', snapshot.capacity.cpu), /100 %/);
  assert.match(html(snapshot), /<td>100 %<\/td>/);
});

test('first sample and missing attribution remain unknown rather than invented zero or external usage', () => {
  const snapshot = adaptStatus(raw('telemetry_first_sample'));
  assert.equal(snapshot.capacity.cpu.actual, null);
  assert.equal(snapshot.capacity.cpu.hostActual, null);
  assert.equal(snapshot.capacity.cpu.external, null);
  assert.equal(snapshot.capacity.cpu.attribution, 'unavailable');
  const input = raw('telemetry_measured');
  input.telemetry.cpu.actual = null;
  input.telemetry.cpu.external = null;
  input.telemetry.gpu.managed_actual_mib = null;
  input.telemetry.gpu.external_mib = null;
  const partial = adaptStatus(input);
  assert.equal(partial.capacity.cpu.hostActual, 9.6);
  assert.equal(partial.capacity.cpu.external, null);
  assert.equal(partial.capacity.gpu.external, null);
});

test('swap values are cumulative pages and used GiB, never rates or admission capacity', () => {
  const snapshot = adaptStatus(raw('telemetry_measured'));
  assert.deepEqual(snapshot.swap, { pagesIn: 13, pagesOut: 7 });
  assert.equal(snapshot.capacity.ram.swapUsed, 0.5);
  assert.match(capacityCard('ram', snapshot.capacity.ram), /0.5 GiB/);
  const input = raw('telemetry_measured'); delete input.telemetry.swap;
  assert.deepEqual(adaptStatus(input).swap, { pagesIn: null, pagesOut: null });
});

test('all actual model lifecycle states retain owner-reported provenance and known load timing', () => {
  for (const state of ['loading', 'ready', 'busy', 'idle', 'unloaded']) {
    const snapshot = adaptStatus(raw(`model_${state}`));
    const model = snapshot.jobs[0].model;
    assert.equal(model.state, state);
    assert.equal(model.name, 'Fixture model');
    assert.equal(model.provenance, 'owner-reported');
    assert.ok(snapshot.jobs[0].events.some((event) => event.label === `model ${state} · owner-reported`));
    assert.equal(model.loadSeconds, state === 'loading' ? null : 3);
    assert.ok(!snapshot.unsupported.includes('Model residency telemetry'));
    const page = html(snapshot);
    assert.match(page, /Model lifecycle · owner-reported/);
    assert.match(page, /Owner-reported/);
    assert.doesNotMatch(page, /data-action="unload"|data-action="model"/);
  }
});

test('reported unload does not release the visible reservation or assert verified unloading', () => {
  const snapshot = adaptStatus(raw('model_unloaded'));
  assert.equal(snapshot.jobs[0].state, 'running');
  assert.equal(snapshot.capacity.gpu.reserved, 4);
  assert.equal(snapshot.capacity.gpu.actual, 4);
  assert.match(html(snapshot), /Reported unloaded/);
  assert.ok(snapshot.unsupported.includes('Managed model unloading'));
  assert.equal(filterJobs(snapshot.jobs, { search: 'Fixture model' }).length, 1);
  const exported = diagnostic(snapshot, snapshot.jobs[0]);
  assert.equal(exported.jobs[0].model.provenance, 'owner-reported');
  assert.equal(exported.capacity.cpu.hostActual, 9.6);
  assert.equal(exported.swap.pagesIn, 13);
});

test('supported-but-empty reports and malformed provenance remain explicit unknowns', () => {
  const input = raw('telemetry_measured');
  assert.equal(input.capabilities.model_reports, true);
  let snapshot = adaptStatus(input);
  assert.equal(snapshot.jobs[0].model, null);
  assert.ok(!snapshot.unsupported.includes('Model residency telemetry'));
  assert.doesNotMatch(html(snapshot), /class="model-report"/);
  input.jobs[0].model = { label: 'untrusted', state: 'ready', attribution_confidence: 'observed' };
  snapshot = adaptStatus(input);
  assert.equal(snapshot.jobs[0].model, null);
});

test('model exports and HTML use an allowlist and escape safe owner labels', () => {
  const input = raw('model_idle');
  input.jobs[0].model.label = '<img src=x onerror=alert(1)>';
  input.jobs[0].model.environment = { TOKEN: 'secret' };
  const snapshot = adaptStatus(input);
  assert.match(html(snapshot), /&lt;img/);
  assert.doesNotMatch(html(snapshot), /<img/);
  assert.ok(!JSON.stringify(diagnostic(snapshot)).includes('secret'));
});

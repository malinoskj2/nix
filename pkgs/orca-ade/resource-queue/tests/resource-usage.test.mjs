import { test } from 'node:test';
import assert from 'node:assert/strict';
import { resourceUsage } from '../src/model.mjs';
import { adaptStatus } from '../src/adapter.mjs';
import { capacityCard, render } from '../panel/view.mjs';
import { fixture, fixtureTime } from './fixtures.mjs';

test('host RAM includes other usage with no queue reservations and excludes reclaimable memory', () => {
  const item = { total: 32, available: 12, actual: 0, reserved: 0 };
  assert.deepEqual(resourceUsage('ram', item), { total: 32, used: 20, managed: 0, external: 20, unattributed: 0 });
  const card = capacityCard('ram', item);
  assert.match(card, /20<small> \/ 32 GiB/);
  assert.match(card, /class="usage-external" style="width:62.5%"/);
  assert.match(card, /Queue reserved<\/dt><dd>0 GiB/);
});

test('all three resources partition measured usage without adding reservations', () => {
  const cases = [
    ['cpu', { total: 12, hostTotal: 32, hostActual: 16, actual: 4, external: 12, reserved: 8 }],
    ['ram', { total: 32, available: 16, actual: 4, reserved: 24 }],
    ['gpu', { total: 32, used: 16, actual: 4, external: 12, reserved: 24 }],
  ];
  for (const [key, item] of cases) {
    assert.deepEqual(resourceUsage(key, item), { total: 32, used: 16, managed: 4, external: 12, unattributed: 0 });
    const card = capacityCard(key, item);
    assert.match(card, /class="usage-managed" style="width:12.5%"/);
    assert.match(card, /class="usage-external" style="width:37.5%"/);
    assert.match(card, /role="img" aria-label="[^"]*queue 4 [^"]*outside queue 12/);
  }
});

test('missing attribution keeps the whole host reading and shows an unattributed segment', () => {
  const snapshot = adaptStatus(fixture('overlap'));
  const usage = resourceUsage('ram', snapshot.capacity.ram);
  assert.equal(usage.used, 25);
  assert.equal(usage.managed, null);
  assert.equal(usage.external, null);
  assert.equal(usage.unattributed, 25);
  assert.match(capacityCard('ram', snapshot.capacity.ram), /class="usage-unattributed"/);
  assert.doesNotMatch(capacityCard('ram', snapshot.capacity.ram), /class="usage-external"/);
});

test('partial and inconsistent samples do not manufacture an external partition', () => {
  assert.deepEqual(resourceUsage('gpu', { total: 32, used: 16, actual: 4, external: null }),
    { total: 32, used: 16, managed: 4, external: null, unattributed: 12 });
  for (const item of [
    { total: 32, available: 24, actual: 10 },
    { total: 32, available: null, actual: 10 },
    { total: 32, available: 40, actual: 10 },
  ]) {
    const usage = resourceUsage('ram', item);
    assert.equal(usage.managed, null);
    assert.equal(usage.external, null);
    assert.doesNotMatch(capacityCard('ram', item), /NaN|width:-|usage-managed"|usage-external"/);
  }
});

test('older CPU telemetry never substitutes queue capacity for host capacity', () => {
  const snapshot = adaptStatus(fixture('overlap'));
  snapshot.capacity.cpu.hostActual = 16;
  const card = capacityCard('cpu', snapshot.capacity.cpu);
  assert.equal(snapshot.capacity.cpu.hostTotal, null);
  assert.match(card, /16<small> \/ Unknown/);
  assert.match(card, /class="unknown-meter"/);
  assert.match(card, /Queue CPU capacity<\/dt><dd>12 Slurm CPUs/);
});

test('zero usage is empty and over-capacity samples cannot overflow the meter', () => {
  assert.doesNotMatch(capacityCard('gpu', { total: 32, used: 0, actual: 0, external: 0 }), /style="width:/);
  const card = capacityCard('gpu', { total: 32, used: 40, actual: 10, external: 30 });
  assert.match(card, /width:25%/);
  assert.match(card, /width:75%/);
  assert.match(card, /40<small> \/ 32 GiB/);
});

test('Resources has one shared legend and separates queue trends from whole-host cards', () => {
  const snapshot = adaptStatus(fixture('overlap'));
  const page = render({ snapshot, tab: 'resources', filters: {}, samples: [], identities: [], logs: [] }, fixtureTime);
  assert.equal((page.match(/Resource usage legend/g) || []).length, 1);
  assert.match(page, /Queue usage<\/span>.*Other \/ system<\/span>.*Unattributed<\/span>/);
  assert.match(page, /Queue reserved <span class="legend run"><\/span>Queue measured/);
});

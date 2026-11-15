// Run in the browser integration test page via Orca eval (never imported by production).
export async function check() {
  const results = [];
  const assert = (value, message) => { if (!value) throw new Error(message); results.push(message); };
  const settle = async () => { for (let i = 0; i < 5; i++) await new Promise(requestAnimationFrame); };
  const press = async (selector) => { const el = document.querySelector(selector); assert(!!el, `Found ${selector}`); el.click(); await settle(); };
  await settle();
  assert(document.body.textContent.includes('● Live'), 'Live test bridge renders connected');
  await press('[data-job="00000000000000000000000000000003"]');
  assert(document.querySelector('.inspector').textContent.includes('Needs 10 GiB RAM'), 'Inspector retains exact wait reason');
  await press('[data-action="cancel"]');
  assert(window.testBridge.controls.length === 0, 'Opening confirmation sends no command');
  assert(document.querySelector('[role="dialog"]'), 'Disruptive action requires confirmation');
  assert(document.activeElement.dataset.action === 'dismiss', 'Focus starts on safe dismissal');
  await press('[data-action="confirm"]');
  assert(window.testBridge.controls.length === 1, 'Confirmed action sends one command');
  assert(window.testBridge.controls[0].revision === 1, 'Confirmed command carries job revision');
  assert(document.querySelector('.inspector').textContent.includes('Cancelled'), 'Confirmed lifecycle replaces queued state');
  assert(!document.querySelector('.inspector [data-action="cancel"]'), 'Terminal job has no cancellation control');
  const input = document.getElementById('job-search');
  input.focus(); input.value = 'nixos'; input.dispatchEvent(new Event('input', { bubbles: true })); await settle();
  assert(document.querySelectorAll('.queue-section .job-row').length === 1, 'Search filters active queue');
  assert(document.activeElement.id === 'job-search', 'Typing retains input focus across redraw');
  input.value = ''; document.getElementById('job-search').value = ''; document.getElementById('job-search').dispatchEvent(new Event('input', { bubbles: true })); await settle();
  window.testBridge.disconnect();
  await press('[data-action="refresh"]');
  assert(document.body.textContent.includes('Connection interrupted'), 'Disconnect is visible');
  assert(document.body.textContent.includes('NixOS rebuild'), 'Disconnect preserves last known running jobs');
  assert(!document.querySelector('[data-action="pause"]'), 'Disconnected queue cannot pause admissions');
  window.testBridge.reconnect();
  await press('[data-action="refresh"]');
  assert(document.body.textContent.includes('● Live'), 'Reconnect recovers live view');
  await press('[data-action="pause"]');
  await press('[data-action="confirm"]');
  assert(document.body.textContent.includes('New admissions paused'), 'Confirmed admission hold rendered');
  assert(document.querySelector('[data-action="resume"]'), 'Resume appears only after confirmed hold');
  assert(document.documentElement.scrollWidth <= window.innerWidth, 'No horizontal overflow');
  return { passed: results.length, results };
}

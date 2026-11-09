const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const S = require('../src/lib/sync');
const tick = () => new Promise(resolve => setImmediate(resolve));

function options() {
  const html = fs.readFileSync(require.resolve('../options/options.html'), 'utf8');
  const elements = Object.fromEntries([...html.matchAll(/<(?:input|button|span)\b([^>]*\bid="([^"]+)"[^>]*)>/g)].map(([, attrs, id]) => [id, {
    type: /type="([^"]+)"/.exec(attrs)?.[1], value: '', checked: false, checkValidity() { return this.valid !== false; }, reportValidity() { return this.valid !== false; }, closest() { return null; }, focus() {},
  }]));
  const store = { settings: { token: 'saved', discordEnabled: false } }, sent = [], writes = [];
  const context = { LF: { sync: S }, document: { getElementById: id => elements[id] }, confirm: () => false,
    chrome: { storage: { local: { get: async () => structuredClone(store), set: async values => { writes.push(values); Object.assign(store, values); } } },
      runtime: { sendMessage: async m => { sent.push(m); return { ok: true, unlocked: true }; } } } };
  vm.runInNewContext(fs.readFileSync(require.resolve('../options/options.js'), 'utf8'), context);
  return { context, elements, store, sent, writes };
}

test('testing unsaved settings does not enable capture, and invalid settings cannot be saved', async () => {
  const ui = options(); await tick();
  ui.elements.token.value = 'new-token';
  ui.elements.discordEnabled.checked = true;
  ui.elements.debugEnabled.checked = true;
  ui.elements.debugToken.value = 'short';
  let debugRevealed = false;
  ui.elements.debugToken.closest = () => ({ setAttribute: () => { debugRevealed = true; } });
  await ui.elements.test.onclick();
  assert.equal(ui.writes.length, 0);
  assert.equal(ui.sent[0].connection.token, 'new-token');
  assert.equal(ui.store.settings.discordEnabled, false);
  assert.match(ui.elements.msg.textContent, /Save to apply/);
  await ui.elements.save.onclick();
  assert.equal(ui.writes.length, 0);
  assert.ok(debugRevealed);
  ui.elements.debugEnabled.checked = false;
  ui.elements.port.valid = false;
  await ui.elements.save.onclick();
  assert.equal(ui.writes.length, 0);
  ui.elements.port.valid = true;
  await ui.elements.save.onclick();
  assert.equal(ui.writes.length, 0);
  ui.context.confirm = () => true;
  await ui.elements.save.onclick();
  assert.equal(ui.store.settings.discordEnabled, true);
});

test('deletion requires confirmation and goes through the background queue', async () => {
  const ui = options(); await tick();
  await ui.elements.clear.onclick();
  assert.equal(ui.sent.length, 0);
  ui.context.confirm = () => true;
  await ui.elements.clear.onclick();
  assert.equal(ui.sent[0].type, 'lifenizer-clear');
  assert.equal(ui.writes.length, 0);
  assert.equal(ui.elements.clear.disabled, false);
});

test('save reveals an invalid advanced field before showing native validation', async () => {
  const ui = options(); await tick();
  let open = false;
  ui.elements.maxDays.valid = false;
  ui.elements.maxDays.closest = selector => { assert.equal(selector, 'details'); return { setAttribute: () => { open = true; } }; };
  ui.elements.maxDays.reportValidity = () => { assert.ok(open); return false; };
  await ui.elements.save.onclick();
  assert.ok(open);
  assert.equal(ui.writes.length, 0);
});

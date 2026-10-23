const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const M = require('../src/lib/messages');
const tick = () => new Promise(resolve => setImmediate(resolve));

test('observer baselines attach/navigation, ignores historical rendering, captures fresh messages, obeys opt-out', async () => {
  const sent = []; let nodes = [], observe, changed;
  const settings = { discordEnabled: true };
  const location = { hostname: 'discord.com', pathname: '/channels/@me/123' };
  const item = (channel, id, time) => ({ id: `chat-messages-${channel}-${id}`, querySelector: selector => selector.startsWith('[id^="message-content-') ? { textContent: `Message ${id}` } : selector === 'time[datetime]' ? { getAttribute: () => time } : null });
  nodes = [item('123', '1', '2020-01-01T12:00:00Z')];
  const context = {
    chrome: { storage: { local: { get: async () => ({ settings }) }, onChanged: { addListener: fn => { changed = fn; } } }, runtime: { sendMessage: async m => { sent.push(m); return { ok: true }; } } },
    LF: { messages: M }, location,
    document: { querySelectorAll: () => nodes, title: 'Chat | Discord' },
    MutationObserver: class { constructor(callback) { observe = callback; } observe() {} },
    queueMicrotask, addEventListener() {}, Date, Set, Promise,
  };
  vm.runInNewContext(fs.readFileSync(require.resolve('../src/content/messages.js'), 'utf8'), context);
  await tick();
  assert.equal(sent.filter(m => m.type === 'lifenizer-messages').length, 0);
  nodes.push(item('123', '2', new Date(Date.now() + 1000).toISOString())); observe(); await tick();
  assert.equal(sent.find(m => m.type === 'lifenizer-messages').messages[0].id, '2');
  observe(); await tick(); assert.equal(sent.filter(m => m.type === 'lifenizer-messages').length, 1);
  nodes.push(item('123', '3', '2020-01-01T12:00:00Z')); observe(); await tick();
  assert.equal(sent.filter(m => m.type === 'lifenizer-messages').length, 1);
  location.pathname = '/channels/@me/456'; nodes = [item('456', '4', new Date(Date.now() + 1000).toISOString())]; observe(); await tick();
  assert.equal(sent.filter(m => m.type === 'lifenizer-messages').length, 1);
  nodes.push(item('456', '5', new Date(Date.now() + 2000).toISOString())); observe(); await tick();
  assert.equal(sent.filter(m => m.type === 'lifenizer-messages').length, 2);
  settings.discordEnabled = false; changed({ settings: {} }, 'local'); await tick();
  nodes.push(item('456', '6', new Date(Date.now() + 3000).toISOString())); observe(); await tick();
  assert.equal(sent.filter(m => m.type === 'lifenizer-messages').length, 2);
});

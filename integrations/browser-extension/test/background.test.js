const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const S = require('../src/lib/sync');
const M = require('../src/lib/messages');
const P = require('../src/lib/payload');
const tick = () => new Promise(resolve => setImmediate(resolve));
function background() {
  let handler;
  const store = { settings: { token: 'pair', discordEnabled: true } }, requests = [];
  const event = { addListener() {} };
  const runtime = { id: 'extension-id', getURL: path => `chrome-extension://extension-id/${path}`, onMessage: { addListener: fn => { handler = fn; } }, onInstalled: event, onStartup: event };
  const ext = { runtime, storage: { local: { get: async keys => { const result = typeof keys === 'string' ? { [keys]: store[keys] } : Object.fromEntries(keys.map(k => [k, store[k]])); return result; }, set: async values => Object.assign(store, values) }, onChanged: event }, alarms: { onAlarm: event, clear: async () => {}, create() {} } };
  const context = { chrome: ext, LF: { sync: S, messages: M, payload: P }, URL, Date, Promise, Set, AbortSignal, setTimeout, clearTimeout, fetch: async (url, opts) => { requests.push([url, opts]); throw Error('app offline'); } };
  vm.runInNewContext(fs.readFileSync(require.resolve('../src/background.js'), 'utf8'), context);
  return { store, requests, send: (message, sender) => new Promise(resolve => { if (!handler(message, sender, resolve)) resolve(undefined); }) };
}
const message = { platform: 'discord', threadId: '123', threadTitle: 'Friends', id: '456', text: 'Hello', createdAt: '2026-10-23T12:00:00Z' };
const sender = { id: 'extension-id', frameId: 0, tab: { id: 7 }, url: 'https://discord.com/channels/@me/123' };

test('background rejects page control, bad origins, subframes and mismatched threads', async () => {
  const bg = background();
  assert.equal(await bg.send({ type: 'lifenizer-ping' }, sender), undefined);
  for (const bad of [{ ...sender, id: 'another-extension' }, { ...sender, url: 'https://evil.test/' }, { ...sender, frameId: 1 }]) {
    assert.equal(await bg.send({ type: 'lifenizer-messages', platform: 'discord', messages: [message] }, bad), undefined);
  }
  assert.equal((await bg.send({ type: 'lifenizer-messages', platform: 'discord', messages: [{ ...message, threadId: '999' }] }, sender)).error, 'invalid-messages');
  assert.equal(bg.requests.length, 0); assert.equal(bg.store.messages, undefined);
});

test('background serializes concurrent tab enqueues, dedupes and retains offline data', async () => {
  const bg = background();
  const send = id => bg.send({ type: 'lifenizer-messages', platform: 'discord', messages: [{ ...message, id }] }, sender);
  const responses = await Promise.all([send('1'), send('2'), send('1')]);
  assert.ok(responses.every(r => r.ok)); await tick(); await tick();
  assert.equal(bg.store.messages.length, 2); assert.ok(bg.store.messages.every(m => !m.sent));
  assert.ok(bg.requests.every(([url]) => url === 'http://127.0.0.1:47615/v1/messages'));
  bg.store.settings.discordEnabled = false;
  assert.equal((await send('3')).error, 'disabled'); assert.equal(bg.store.messages.length, 2);
});

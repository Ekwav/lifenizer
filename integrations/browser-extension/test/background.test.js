const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const S = require('../src/lib/sync');
const M = require('../src/lib/messages');
const P = require('../src/lib/payload');
const tick = () => new Promise(resolve => setImmediate(resolve));
function background(options = {}) {
  let handler, finish;
  const finished = new Promise(resolve => { finish = resolve; });
  const store = { settings: { token: 'pair', discordEnabled: true, ...options.settings } }, requests = [], tabs = [];
  const event = { addListener() {} };
  const runtime = { id: 'extension-id', getURL: path => `chrome-extension://extension-id/${path}`, onMessage: { addListener: fn => { handler = fn; } }, onInstalled: event, onStartup: event };
  const ext = { runtime, tabs: { create: async opts => { tabs.push(opts); throw Error('unexpected collection'); } }, storage: { local: { get: async keys => { const result = typeof keys === 'string' ? { [keys]: store[keys] } : Object.fromEntries(keys.map(k => [k, store[k]])); return result; }, set: async values => { Object.assign(store, values); if (values.status?.running === false) finish(); } }, onChanged: event }, alarms: { onAlarm: event, clear: async () => {}, create() {} } };
  const context = { chrome: ext, LF: { sync: S, messages: M, payload: P }, URL, Date, Promise, Set, AbortSignal: options.AbortSignal || AbortSignal, setTimeout, clearTimeout, fetch: async (url, opts) => { requests.push([url, opts]); if (options.fetch) return options.fetch(url, opts); throw Error('app offline'); } };
  vm.runInNewContext(fs.readFileSync(require.resolve('../src/background.js'), 'utf8'), context);
  return { store, requests, tabs, finished, send: (message, sender) => new Promise(resolve => { if (!handler(message, sender, resolve)) resolve(undefined); }) };
}
const message = { platform: 'discord', threadId: '123', threadTitle: 'Friends', id: '456', text: 'Hello', createdAt: '2026-10-23T12:00:00Z' };
const sender = { id: 'extension-id', frameId: 0, tab: { id: 7 }, url: 'https://discord.com/channels/@me/123' };
const popup = { id: 'extension-id', url: 'chrome-extension://extension-id/popup/popup.html' };

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

test('retry sends queued history and messages without reopening collection tabs', async () => {
  const bg = background({ settings: { youtubeAccount: '@mine' }, fetch: async url => ({ ok: true, status: 200, json: async () => url.endsWith('/messages') ? { ok: true, imported: 1 } : { accepted: 1, imported: 1 } }) });
  bg.store.visits = [{ platform: 'youtube', id: 'aaaaaaaaaaa', url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa', time: '2026-10-23T12:00:00Z', account: { handle: '@mine' }, accountSelection: '@mine', sent: false }];
  bg.store.messages = [{ ...message, sent: false }];
  bg.store.status = { fatal: 'old failure', running: true };
  assert.equal((await bg.send({ type: 'lifenizer-state' }, popup)).running, false);
  assert.equal((await bg.send({ type: 'lifenizer-retry' }, popup)).started, true);
  await bg.finished;
  assert.equal(bg.tabs.length, 0);
  assert.equal(bg.requests.length, 2);
  assert.ok(bg.store.visits[0].sent && bg.store.messages[0].sent);
  assert.equal(bg.store.status.fatal, null);
});

test('unconfigured explicit history sync reports setup error without opening a site', async () => {
  const bg = background();
  await bg.send({ type: 'lifenizer-sync', platforms: ['youtube'] }, popup);
  await bg.finished;
  assert.equal(bg.tabs.length, 0);
  assert.match(bg.store.status.youtube.message, /Configure the expected account/);
});

test('connection test uses unsaved credentials without changing capture consent or stored settings', async () => {
  const bg = background({ fetch: async () => ({ ok: true, status: 200, json: async () => ({ app: 'lifenizer', unlocked: true }) }) });
  const before = JSON.stringify(bg.store.settings);
  assert.equal((await bg.send({ type: 'lifenizer-ping', connection: { port: 43210, token: 'unsaved' } }, popup)).ok, true);
  assert.equal(bg.requests[0][0], 'http://127.0.0.1:43210/v1/ping');
  assert.equal(bg.requests[0][1].headers.Authorization, 'Bearer unsaved');
  assert.equal(JSON.stringify(bg.store.settings), before);
  assert.equal(await bg.send({ type: 'lifenizer-ping', connection: { port: 0, token: 'unsaved' } }, popup), undefined);
});

test('deletion waits for in-flight delivery so a completed request cannot restore deleted messages', async () => {
  let release, requested;
  const request = new Promise(resolve => { requested = resolve; });
  const response = new Promise(resolve => { release = resolve; });
  const bg = background({ fetch: async () => { requested(); return response; } });
  await bg.send({ type: 'lifenizer-messages', platform: 'discord', messages: [message] }, sender);
  await request;
  const deletion = bg.send({ type: 'lifenizer-clear' }, popup);
  assert.equal((await bg.send({ type: 'lifenizer-retry' }, popup)).started, false);
  release({ ok: true, status: 200, json: async () => ({ ok: true, imported: 1 }) });
  assert.equal((await deletion).ok, true);
  assert.equal(bg.store.messages.length, 0);
  assert.equal(bg.store.visits.length, 0);
  assert.equal((await bg.send({ type: 'lifenizer-state' }, popup)).running, false);
});

test('deletion is blocked during history sync and content pages cannot request it', async () => {
  const bg = background();
  assert.equal(await bg.send({ type: 'lifenizer-clear' }, sender), undefined);
  await bg.send({ type: 'lifenizer-sync', platforms: [] }, popup);
  assert.equal((await bg.send({ type: 'lifenizer-clear' }, popup)).error, 'sync-running');
  await bg.finished;
});

test('stalled history and message requests use deadlines, preserve the queues and release retry', async () => {
  const deadlines = [];
  const bg = background({ settings: { youtubeAccount: '@mine' },
    AbortSignal: { timeout: ms => {
      deadlines.push(ms);
      const controller = new AbortController();
      setImmediate(() => controller.abort(new DOMException('Test deadline elapsed', 'TimeoutError')));
      return controller.signal;
    } },
    fetch: (_, { signal }) => new Promise((_, reject) => signal.addEventListener('abort', () => reject(signal.reason), { once: true })),
  });
  bg.store.visits = [{ platform: 'youtube', id: 'aaaaaaaaaaa', url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa', time: '2026-10-23T12:00:00Z', account: { handle: '@mine' }, accountSelection: '@mine', sent: false }];
  bg.store.messages = [{ ...message, sent: false }];
  await bg.send({ type: 'lifenizer-retry' }, popup);
  await bg.finished;
  assert.deepEqual(deadlines, [10000, 10000]);
  assert.equal(bg.store.visits[0].sent, false); assert.equal(bg.store.messages[0].sent, false);
  assert.equal(bg.store.status.delivery.error, 'timeout'); assert.equal(bg.store.status.messages.error, 'timeout');
  assert.equal((await bg.send({ type: 'lifenizer-state' }, popup)).running, false);
});

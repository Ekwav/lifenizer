const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const { PassThrough } = require('node:stream');
const fs = require('node:fs');
const vm = require('node:vm');
const { WebSocket } = require('ws');
const { createBridge, serveStdio, MAX_BYTES } = require('../debug/bridge.cjs');
const token = 'a'.repeat(64);
const origin = 'chrome-extension://' + 'a'.repeat(32);
async function setup(t, options = {}) {
  const bridge = createBridge({ token, port: 0, ...options });
  const port = await bridge.ready;
  t.after(() => bridge.close());
  return { bridge, url: `ws://127.0.0.1:${port}/lifenizer-debug` };
}
async function connect(url, secret = token) {
  const socket = new WebSocket(url, { origin });
  socket.on('error', () => {});
  await once(socket, 'open');
  const response = once(socket, 'message');
  socket.send(JSON.stringify({ type: 'auth', token: secret }));
  await response;
  return socket;
}

test('debug bridge requires strong separate secret and extension origin', async t => {
  assert.throws(() => createBridge({ token: 'short' }), /32/);
  const { url } = await setup(t);
  const socket = new WebSocket(url, { origin: 'https://www.youtube.com' });
  const [error] = await once(socket, 'error');
  assert.match(error.message, /401/);
});

test('unauthorized first message and missing auth close the connection', async t => {
  const { url } = await setup(t, { authMs: 30 });
  const socket = new WebSocket(url, { origin });
  socket.on('error', () => {});
  await once(socket, 'open');
  const closed = once(socket, 'close');
  socket.send(JSON.stringify({ type: 'auth', token: 'wrong' }));
  assert.equal((await closed)[0], 1008);
  const idle = new WebSocket(url, { origin });
  idle.on('error', () => {});
  await once(idle, 'open');
  assert.equal((await once(idle, 'close'))[0], 1008);
});

test('bounded debug calls relay fixed tool names and reject arbitrary arguments', async t => {
  const { bridge, url } = await setup(t);
  await assert.rejects(bridge.call('list_tabs'), /not connected/);
  const socket = await connect(url);
  socket.on('message', bytes => {
    const command = JSON.parse(bytes);
    if (command.type === 'command') socket.send(JSON.stringify({ type: 'result', id: command.id, result: [{ tabId: 1, platform: 'youtube' }] }));
  });
  assert.deepEqual(await bridge.call('list_tabs'), [{ tabId: 1, platform: 'youtube' }]);
  await assert.rejects(bridge.call('evaluate', { code: 'document.cookie' }), /Invalid/);
  await assert.rejects(bridge.call('page_diagnostics', { tabId: 1, selector: '*' }), /Invalid/);
  await assert.rejects(bridge.call('sample_visible_content', { tabId: 1, limit: 100 }), /Invalid/);
});

test('deadlines, cancellation and disconnect release pending calls', async t => {
  const { bridge, url } = await setup(t, { deadlineMs: 30 });
  const socket = await connect(url);
  await assert.rejects(bridge.call('list_tabs'), /timed out/);
  const controller = new AbortController();
  const cancelled = bridge.call('list_tabs', {}, controller.signal);
  controller.abort();
  await assert.rejects(cancelled, /cancelled/);
  const disconnected = bridge.call('list_tabs');
  socket.close();
  await assert.rejects(disconnected, /disconnected/);
});

test('oversized WebSocket payload closes with no tool output', async t => {
  const { bridge, url } = await setup(t);
  const socket = await connect(url);
  const result = bridge.call('list_tabs');
  socket.send('x'.repeat(MAX_BYTES + 1));
  await assert.rejects(result, /disconnected/);
});

test('stdio implements initialize, discovery, tools/call, ping and cancellation', async t => {
  const { bridge, url } = await setup(t);
  const socket = await connect(url);
  socket.on('message', bytes => {
    const command = JSON.parse(bytes);
    if (command.type === 'command') socket.send(JSON.stringify({ type: 'result', id: command.id, result: { platform: 'youtube', selectors: {} } }));
  });
  const input = new PassThrough(), output = new PassThrough();
  const responses = [], waiters = [];
  output.on('data', chunk => {
    responses.push(...chunk.toString().trim().split('\n').map(JSON.parse));
    for (const wake of waiters.splice(0)) wake();
  });
  serveStdio(bridge, input, output);
  const send = value => input.write(JSON.stringify({ jsonrpc: '2.0', ...value }) + '\n');
  async function response(id) {
    while (!responses.some(value => value.id === id)) await new Promise(resolve => waiters.push(resolve));
    return responses.find(value => value.id === id);
  }
  send({ id: 0, method: 'tools/list' });
  assert.equal((await response(0)).error.code, -32000);
  send({ id: 1, method: 'initialize', params: { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'test', version: '1' } } });
  assert.equal((await response(1)).result.protocolVersion, '2025-11-25');
  send({ method: 'notifications/initialized' });
  send({ id: 2, method: 'tools/list' });
  assert.deepEqual((await response(2)).result.tools.map(tool => tool.name), ['list_tabs', 'page_diagnostics', 'sample_visible_content']);
  send({ id: 3, method: 'tools/call', params: { name: 'page_diagnostics', arguments: { tabId: 1 } } });
  assert.equal(JSON.parse((await response(3)).result.content[0].text).platform, 'youtube');
  send({ id: 4, method: 'ping' });
  assert.deepEqual((await response(4)).result, {});
  send({ id: 5, method: 'tools/call', params: { name: 'evaluate', arguments: {} } });
  assert.equal((await response(5)).error.code, -32602);
  send({ id: 6, method: 'tools/call', params: { name: 'list_tabs', arguments: {} } });
  send({ method: 'notifications/cancelled', params: { requestId: 6 } });
  assert.match((await response(6)).result.content[0].text, /cancelled/);
  input.end();
});

test('extension opt-in defaults off and clearing secret closes socket', async () => {
  let settings = {}, changed, connections = [];
  class Socket {
    static OPEN = 1;
    constructor(url) { this.url = url; this.readyState = 1; this.sent = []; connections.push(this); }
    send(value) { this.sent.push(JSON.parse(value)); }
    close() { this.closed = true; }
  }
  const context = {
    chrome: { storage: { local: { get: async () => ({ settings }) }, onChanged: { addListener: callback => { changed = callback; } } }, runtime: { onStartup: { addListener: () => {} } } },
    WebSocket: Socket, URL, clearTimeout, setTimeout, TextEncoder,
  };
  vm.runInNewContext(fs.readFileSync(require.resolve('../src/lib/debug.js'), 'utf8'), context);
  await new Promise(setImmediate);
  assert.equal(connections.length, 0);
  settings = { debugEnabled: true, debugToken: token };
  changed({ settings: {} }, 'local');
  await new Promise(setImmediate);
  assert.equal(connections.length, 1);
  assert.equal(connections[0].url, 'ws://127.0.0.1:47616/lifenizer-debug');
  await connections[0].onmessage({ data: JSON.stringify({ type: 'command', id: 'private', name: 'sample_visible_content', args: { tabId: 1 } }) });
  assert.equal(connections[0].sent[0].error, 'Debug operation unavailable or disabled');
  settings = { debugEnabled: true, debugToken: '' };
  changed({ settings: {} }, 'local');
  await new Promise(setImmediate);
  assert.equal(connections[0].closed, true);
  assert.equal(connections.length, 1);
});

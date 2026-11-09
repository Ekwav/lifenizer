#!/usr/bin/env node
// MCP 2025-11-25 stdio server. The browser transport is a separately
// authenticated, loopback-only WebSocket; stdout contains JSON-RPC only.
const http = require('node:http');
const crypto = require('node:crypto');
const { WebSocketServer, WebSocket } = require('ws');
const MAX_BYTES = 65536;
const TOOLS = [
  { name: 'list_tabs', description: 'List supported open tab IDs and platform hosts. Does not read titles, URLs or page content.', inputSchema: { type: 'object', properties: {}, additionalProperties: false } },
  { name: 'page_diagnostics', description: 'Read fixed adapter selector counts, page locale and selected signed-in account identity from a supported tab. No message/video text.', inputSchema: { type: 'object', properties: { tabId: { type: 'integer', minimum: 0 } }, required: ['tabId'], additionalProperties: false } },
  { name: 'sample_visible_content', description: 'Explicit private-content read: sample up to 10 currently rendered messages or video entries for parser development. Requires Allow content samples in extension Debug settings. Never imports, scrolls or sends messages.', inputSchema: { type: 'object', properties: { tabId: { type: 'integer', minimum: 0 }, limit: { type: 'integer', minimum: 1, maximum: 10 } }, required: ['tabId'], additionalProperties: false } },
].map(tool => ({ ...tool, annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false } }));

function createBridge({ token, port = 47616, deadlineMs = 5000, authMs = 3000, heartbeatMs = 20000 } = {}) {
  if (typeof token !== 'string' || token.length < 32 || token.length > 256) throw new Error('LIFENIZER_DEBUG_TOKEN must contain 32–256 characters');
  let browser = null;
  const pending = new Map();
  const server = http.createServer((_, response) => { response.writeHead(404); response.end(); });
  const sockets = new WebSocketServer({ server, path: '/lifenizer-debug', maxPayload: MAX_BYTES,
    verifyClient: ({ origin, req }) => sockets.clients.size < 4 &&
      /^(chrome-extension:\/\/[a-p]{32}|moz-extension:\/\/[\da-f-]{36})$/i.test(origin || '') &&
      req.headers.host === `127.0.0.1:${server.address()?.port}`,
  });
  sockets.on('error', () => {});
  function rejectPending(message) { for (const item of pending.values()) item.finish(new Error(message)); }
  sockets.on('connection', socket => {
    let authenticated = false;
    const timeout = setTimeout(() => socket.close(1008, 'Authentication required'), authMs);
    socket.on('error', () => {});
    socket.on('message', bytes => {
      let message;
      try { message = JSON.parse(bytes.toString()); } catch (_) { socket.close(1008, 'Invalid message'); return; }
      if (!authenticated) {
        const given = typeof message?.token === 'string' ? Buffer.from(message.token) : Buffer.alloc(0);
        const wanted = Buffer.from(token);
        if (message?.type !== 'auth' || given.length !== wanted.length || !crypto.timingSafeEqual(given, wanted) || browser) {
          socket.close(1008, 'Authentication rejected'); return;
        }
        authenticated = true; browser = socket; clearTimeout(timeout);
        socket.send(JSON.stringify({ type: 'ready' }));
        return;
      }
      if (message?.type === 'pong') return;
      if (message?.type !== 'result' || typeof message.id !== 'string') { socket.close(1008, 'Invalid response'); return; }
      const item = pending.get(message.id);
      if (item) item.finish(message.error || message.result === undefined ? new Error('Extension rejected debug request') : null, message.result);
    });
    socket.on('close', () => {
      clearTimeout(timeout);
      if (browser === socket) { browser = null; rejectPending('Debug extension disconnected'); }
    });
  });
  const heartbeat = setInterval(() => {
    if (browser?.readyState === WebSocket.OPEN) browser.send(JSON.stringify({ type: 'ping' }));
  }, heartbeatMs);
  heartbeat.unref();

  function call(name, args = {}, signal) {
    const keys = Object.keys(args || {});
    if (!TOOLS.some(tool => tool.name === name) || !args || typeof args !== 'object' || Array.isArray(args) ||
      (name === 'list_tabs' ? keys.length !== 0 : !Number.isInteger(args.tabId) || args.tabId < 0 || keys.some(key => !['tabId', ...(name === 'sample_visible_content' ? ['limit'] : [])].includes(key))) ||
      (args.limit !== undefined && (!Number.isInteger(args.limit) || args.limit < 1 || args.limit > 10))) return Promise.reject(new Error('Invalid tool arguments'));
    if (!browser || browser.readyState !== WebSocket.OPEN) return Promise.reject(new Error('Debug extension is not connected; opt in and save Debug settings'));
    if (pending.size >= 4) return Promise.reject(new Error('Debug bridge is busy'));
    if (signal?.aborted) return Promise.reject(new Error('Debug request cancelled'));
    return new Promise((resolve, reject) => {
      const id = crypto.randomUUID();
      const socket = browser;
      const cancel = () => { socket.send(JSON.stringify({ type: 'cancel', id })); finish(new Error('Debug request cancelled')); };
      const timer = setTimeout(() => { socket.send(JSON.stringify({ type: 'cancel', id })); finish(new Error('Debug request timed out')); }, deadlineMs);
      function finish(error, result) {
        if (!pending.delete(id)) return;
        clearTimeout(timer); signal?.removeEventListener('abort', cancel);
        error ? reject(error) : resolve(result);
      }
      pending.set(id, { finish });
      signal?.addEventListener('abort', cancel, { once: true });
      socket.send(JSON.stringify({ type: 'command', id, name, args }));
    });
  }
  async function close() {
    clearInterval(heartbeat); rejectPending('Debug bridge closed');
    for (const socket of sockets.clients) socket.terminate();
    await new Promise(resolve => sockets.close(resolve));
    if (server.listening) await new Promise(resolve => server.close(resolve));
  }
  const ready = new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', () => resolve(server.address().port)); });
  return { ready, call, close };
}

function serveStdio(bridge, input = process.stdin, output = process.stdout) {
  let buffer = '', initialized = false, ready = false;
  const requests = new Map();
  const send = value => { if (!output.write(JSON.stringify(value) + '\n')) input.pause(); };
  output.on('drain', () => input.resume());
  const error = (id, code, message) => send({ jsonrpc: '2.0', id, error: { code, message } });
  input.setEncoding('utf8');
  input.on('data', chunk => {
    buffer += chunk;
    if (Buffer.byteLength(buffer) > MAX_BYTES) { input.destroy(); bridge.close(); return; }
    let end;
    while ((end = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
      let message;
      try { message = JSON.parse(line); } catch (_) { error(null, -32700, 'Parse error'); continue; }
      if (!message || message.jsonrpc !== '2.0' || typeof message.method !== 'string') { error(null, -32600, 'Invalid request'); continue; }
      if (message.method === 'notifications/initialized') { ready = initialized; continue; }
      if (message.method === 'notifications/cancelled') { requests.get(message.params?.requestId)?.abort(); continue; }
      if (message.id === undefined) continue;
      if (message.id !== null && !['string', 'number'].includes(typeof message.id)) { error(null, -32600, 'Invalid request ID'); continue; }
      const result = value => send({ jsonrpc: '2.0', id: message.id, result: value });
      if (message.method === 'initialize') {
        initialized = true;
        result({ protocolVersion: '2025-11-25', capabilities: { tools: {} }, serverInfo: { name: 'lifenizer-extension-debug', version: '0.1.0' } });
      } else if (message.method === 'ping') result({});
      else if (!ready) error(message.id, -32000, 'Initialize the MCP session first');
      else if (message.method === 'tools/list') result({ tools: TOOLS });
      else if (message.method === 'tools/call') {
        if (!TOOLS.some(tool => tool.name === message.params?.name)) { error(message.id, -32602, 'Unknown tool'); continue; }
        if (requests.size >= 4 || requests.has(message.id)) { error(message.id, -32000, 'Too many pending requests'); continue; }
        const controller = new AbortController(); requests.set(message.id, controller);
        bridge.call(message.params.name, message.params.arguments, controller.signal)
          .then(value => result({ content: [{ type: 'text', text: JSON.stringify(value) }] }),
            failure => result({ isError: true, content: [{ type: 'text', text: failure.message }] }))
          .finally(() => requests.delete(message.id));
      } else error(message.id, -32601, 'Method not found');
    }
  });
  input.on('end', () => { for (const controller of requests.values()) controller.abort(); bridge.close(); });
}

if (require.main === module) {
  try {
    const bridge = createBridge({ token: process.env.LIFENIZER_DEBUG_TOKEN });
    bridge.ready.then(() => serveStdio(bridge), () => { console.error('Cannot bind the loopback debug port'); process.exitCode = 1; });
    for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => bridge.close().then(() => process.exit()));
  } catch (failure) { console.error(failure.message); process.exitCode = 1; }
}
module.exports = { createBridge, serveStdio, TOOLS, MAX_BYTES };

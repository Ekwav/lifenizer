// Optional fixed-scope developer transport. Never exposes page evaluation,
// arbitrary DOM selectors, credentials, imports or browser mutations.
(() => {
  const ext = globalThis.browser || globalThis.chrome;
  const HOSTS = { 'www.youtube.com': 'youtube', 'www.tiktok.com': 'tiktok', 'web.whatsapp.com': 'whatsapp', 'discord.com': 'discord' };
  let socket, retry, generation = 0;
  const pending = new Set();
  function platform(url) {
    try { const parsed = new URL(url); return parsed.protocol === 'https:' ? HOSTS[parsed.hostname] : undefined; } catch (_) { return undefined; }
  }
  async function execute(name, args, connectionToken) {
    const settings = (await ext.storage.local.get('settings')).settings || {};
    if (!settings.debugEnabled || settings.debugToken !== connectionToken) throw new Error('Debug disabled');
    if (name === 'list_tabs') {
      if (Object.keys(args).length) throw new Error('Invalid arguments');
      return (await ext.tabs.query({})).filter(tab => platform(tab.url)).slice(0, 100)
        .map(tab => ({ tabId: tab.id, platform: platform(tab.url), active: !!tab.active }));
    }
    if (!['page_diagnostics', 'sample_visible_content'].includes(name) || !Number.isInteger(args.tabId) || args.tabId < 0 ||
        Object.keys(args).some(key => !['tabId', ...(name === 'sample_visible_content' ? ['limit'] : [])].includes(key)) ||
        (args.limit !== undefined && (!Number.isInteger(args.limit) || args.limit < 1 || args.limit > 10))) throw new Error('Invalid arguments');
    if (name === 'sample_visible_content' && !settings.debugAllowContent) throw new Error('Content samples disabled');
    if (!platform((await ext.tabs.get(args.tabId)).url)) throw new Error('Unsupported tab');
    return ext.tabs.sendMessage(args.tabId, { type: 'lifenizer-debug-page', operation: name, limit: args.limit || 5 }, { frameId: 0 });
  }
  async function configure() {
    const current = ++generation;
    clearTimeout(retry); pending.clear();
    if (socket) { socket.onclose = null; socket.close(); socket = null; }
    const settings = (await ext.storage.local.get('settings')).settings || {};
    if (current !== generation || settings.debugEnabled !== true || typeof settings.debugToken !== 'string' || settings.debugToken.length < 32 || settings.debugToken.length > 256) return;
    const token = settings.debugToken;
    const ws = socket = new WebSocket('ws://127.0.0.1:47616/lifenizer-debug');
    ws.onopen = () => { if (current === generation) ws.send(JSON.stringify({ type: 'auth', token })); };
    ws.onerror = () => {};
    ws.onclose = () => { if (current === generation) { pending.clear(); retry = setTimeout(configure, 2000); } };
    ws.onmessage = async event => {
      if (current !== generation || typeof event.data !== 'string' || new TextEncoder().encode(event.data).length > 65536) { ws.close(); return; }
      let message;
      try { message = JSON.parse(event.data); } catch (_) { ws.close(); return; }
      if (message.type === 'ping') { ws.send(JSON.stringify({ type: 'pong' })); return; }
      if (message.type === 'ready') return;
      if (message.type === 'cancel') { pending.delete(message.id); return; }
      if (message.type !== 'command' || typeof message.id !== 'string' || message.id.length > 64 || pending.size >= 4 || pending.has(message.id)) { ws.close(); return; }
      pending.add(message.id);
      let response;
      try { response = { type: 'result', id: message.id, result: await execute(message.name, message.args || {}, token) }; }
      catch (_) { response = { type: 'result', id: message.id, error: 'Debug operation unavailable or disabled' }; }
      if (!pending.delete(message.id) || current !== generation || ws.readyState !== WebSocket.OPEN) return;
      const latest = (await ext.storage.local.get('settings')).settings || {};
      if (!latest.debugEnabled || latest.debugToken !== token || (message.name === 'sample_visible_content' && !latest.debugAllowContent && !response.error)) return;
      let encoded = JSON.stringify(response);
      if (new TextEncoder().encode(encoded).length > 65536) encoded = JSON.stringify({ type: 'result', id: message.id, error: 'Debug result exceeds limit' });
      ws.send(encoded);
    };
  }
  ext.storage.onChanged.addListener((changes, area) => { if (area === 'local' && changes.settings) configure(); });
  ext.runtime.onStartup.addListener(configure);
  configure();
})();

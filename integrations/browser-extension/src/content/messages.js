// Observe only newly rendered messages in an open conversation. No scrolling,
// history traversal, page-network interception, credentials, or send actions.
(() => {
  const ext = globalThis.browser || globalThis.chrome;
  const M = globalThis.LF.messages;
  const platform = location.hostname === 'web.whatsapp.com' ? 'whatsapp' : 'discord';
  const selector = platform === 'whatsapp' ? '#main [data-id]' : 'li[id^="chat-messages-"]';
  let enabled = false, thread = '', since = Date.now(), seen = new Set(), scheduled = false, lastStatus = '';
  let pending = [], sending = false;
  const send = m => Promise.resolve(ext.runtime.sendMessage(m));
  function status(error) {
    if (lastStatus === error) return;
    lastStatus = error;
    send({ type: 'lifenizer-message-status', platform, error }).catch(() => {});
  }
  async function flush() {
    if (sending || !pending.length || !enabled) return;
    sending = true;
    const batch = pending.slice(0, M.MAX_BATCH);
    try {
      const response = await send({ type: 'lifenizer-messages', platform, messages: batch });
      if (response?.ok) { pending.splice(0, batch.length); status(''); }
      else status(response?.error || 'message-queue-failed');
    } catch (_) { status('message-queue-failed'); }
    sending = false;
    if (pending.length && pending[0] !== batch[0]) flush();
  }
  function scan(baseline = false) {
    if (!enabled) return;
    const nodes = [...document.querySelectorAll(selector)];
    const messages = nodes.map(node => M[platform](node, location, document));
    const current = messages.find(Boolean)?.threadId || location.pathname;
    if (current !== thread) { thread = current; baseline = true; since = Date.now(); seen = new Set(); }
    if (new Set(messages.filter(Boolean).map(m => m.threadId)).size > 1) { status('message-layout'); return; }
    if (!nodes.length || messages.some(m => !M.valid(m))) status('message-layout');
    else status('');
    for (let i = 0; i < nodes.length; i++) {
      const message = messages[i];
      if (!M.valid(message) || seen.has(M.key(message))) continue;
      seen.add(M.key(message));
      // Older messages rendered by scrolling never count as new messages.
      if (!baseline && Date.parse(message.createdAt) >= (platform === 'whatsapp' ? Math.floor(since / 60000) * 60000 : since)) pending.push(message);
    }
    flush();
  }
  function schedule() {
    if (scheduled || !enabled) return;
    scheduled = true;
    queueMicrotask(() => { scheduled = false; scan(); });
  }
  async function configure() {
    const stored = await ext.storage.local.get('settings');
    const next = stored.settings?.[`${platform}Enabled`] === true;
    if (next !== enabled) {
      enabled = next; thread = ''; seen.clear(); pending = []; since = Date.now();
      if (enabled) scan(true);
    }
  }
  new MutationObserver(schedule).observe(document, { subtree: true, childList: true, characterData: true });
  ext.storage.onChanged.addListener((changes, area) => { if (area === 'local' && changes.settings) configure(); });
  addEventListener('popstate', schedule);
  configure();
})();

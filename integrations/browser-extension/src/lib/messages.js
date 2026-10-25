// Visible-DOM message parsing and a durable, bounded-batch delivery contract.
(function (root) {
  const platforms = ['whatsapp', 'discord'];
  const MAX_BATCH = 25;
  function valid(m) {
    return m && platforms.includes(m.platform) && ['id', 'threadId', 'threadTitle', 'text', 'createdAt'].every(k => typeof m[k] === 'string' && m[k].trim().length > 0) &&
      m.id.length > 0 && m.id.length <= 512 && m.threadId.length > 0 && m.threadId.length <= 512 &&
      m.threadTitle.length <= 1000 && m.text.length > 0 && m.text.length <= 50000 && Number.isFinite(Date.parse(m.createdAt)) &&
      ['authorId', 'authorName', 'sourceUrl'].every(k => m[k] === undefined || (typeof m[k] === 'string' && m[k].trim().length > 0 && m[k].length <= ({ authorId: 512, authorName: 1000, sourceUrl: 2048 }[k]))) &&
      (!m.sourceUrl || new RegExp(`^https://${m.platform === 'discord' ? 'discord\\.com' : 'web\\.whatsapp\\.com'}/`).test(m.sourceUrl));
  }
  const key = m => JSON.stringify([m.platform, m.threadId, m.id]);
  function merge(store, fresh) {
    const seen = new Set(store.map(key));
    const added = [];
    for (const m of fresh) if (valid(m) && !seen.has(key(m))) { seen.add(key(m)); added.push({ ...m, sent: false }); }
    // Never discard unacknowledged messages to make room for newer ones.
    return store.filter(m => !m.sent).concat(store.filter(m => m.sent).slice(-10000), added);
  }
  async function deliver(store, settings, fetchImpl) {
    const pending = store.filter(m => !m.sent && settings[`${m.platform}Enabled`]);
    let sent = 0;
    if (!pending.length) return { sent };
    if (!settings.token) return { sent, error: 'not-paired' };
    for (let i = 0; i < pending.length; i += MAX_BATCH) {
      const part = pending.slice(i, i + MAX_BATCH);
      let response, body;
      try {
        response = await fetchImpl(`http://127.0.0.1:${settings.port}/v1/messages`, {
          method: 'POST', headers: { Authorization: `Bearer ${settings.token}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ source: 'lifenizer-extension', version: 1, messages: part.map(({ sent, ...m }) => m) }),
        });
      } catch (error) { return { sent, error: error?.name === 'TimeoutError' ? 'timeout' : 'unreachable' }; }
      try { body = await response.json(); } catch (_) { /* Preserve unacknowledged entries. */ }
      if (response.status === 401) return { sent, error: 'bad-token' };
      if (response.status === 503) return { sent, error: body?.error === 'locked' ? 'locked' : 'app-busy' };
      if (!response.ok) return { sent, error: `http-${response.status}` };
      if (!body || body.ok !== true || !Number.isInteger(body.imported) || body.imported < 0 || body.imported > part.length) return { sent, error: 'invalid-response' };
      part.forEach(m => { m.sent = true; });
      sent += part.length;
    }
    return { sent };
  }
  function discord(node, location, doc) {
    const match = /^chat-messages-(\d+)-(\d+)$/.exec(node.id || '');
    const route = /^\/channels\/(\d+|@me)\/(\d+)$/.exec(location.pathname);
    if (!match || !route || match[1] !== route[2]) return null;
    const text = node.querySelector('[id^="message-content-"]')?.textContent?.trim();
    const createdAt = node.querySelector('time[datetime]')?.getAttribute('datetime');
    if (!text || !createdAt) return null;
    const author = node.querySelector('[id^="message-username-"]');
    const avatar = node.querySelector('img[src*="/avatars/"]')?.getAttribute('src');
    const authorId = /\/avatars\/(\d+)\//.exec(avatar || '')?.[1];
    return { platform: 'discord', threadId: route[2], id: match[2], threadTitle: doc.title.replace(/\s*[|–-]\s*Discord$/, ''), text,
      createdAt, ...(authorId ? { authorId } : {}), ...(author?.textContent?.trim() ? { authorName: author.textContent.trim() } : {}),
      sourceUrl: `https://discord.com/channels/${route[1]}/${route[2]}/${match[2]}` };
  }
  function whatsapp(node, location, doc) {
    const match = /^(?:true|false)_([^_]+)_(.+)$/.exec(node.getAttribute('data-id') || '');
    const text = node.querySelector('.selectable-text.copyable-text')?.textContent?.trim();
    const stamp = node.querySelector('[data-pre-plain-text]')?.getAttribute('data-pre-plain-text');
    const date = /^\[(\d{1,2}):(\d{2})(?:\s*([AP]M))?,\s*(\d{1,2})[/.](\d{1,2})[/.](\d{4})\]\s*(.*?):\s*$/i.exec(stamp || '');
    const lang = doc.documentElement.lang;
    if (!match || !text || !date || !lang) return null;
    // Interpret only an explicitly declared UI locale, never guess date order.
    let order;
    try { order = new Intl.DateTimeFormat(lang).formatToParts(new Date(2026, 10, 23)).filter(p => p.type === 'month' || p.type === 'day').map(p => p.type); } catch (_) { return null; }
    const first = +date[4], second = +date[5];
    const month = order[0] === 'month' ? first : second, day = order[0] === 'day' ? first : second;
    let hour = +date[1];
    if (date[3]) hour = hour % 12 + (/pm/i.test(date[3]) ? 12 : 0);
    const parsed = new Date(+date[6], month - 1, day, hour, +date[2]);
    if (parsed.getMonth() !== month - 1 || parsed.getDate() !== day || hour > 23 || +date[2] > 59) return null;
    const title = doc.querySelector('#main header [title]')?.getAttribute('title');
    if (!title) return null;
    return { platform: 'whatsapp', threadId: match[1], id: match[2], threadTitle: title, text, createdAt: parsed.toISOString(),
      ...(date[7] ? { authorName: date[7] } : {}), sourceUrl: 'https://web.whatsapp.com/' };
  }
  const api = { valid, key, merge, deliver, discord, whatsapp, MAX_BATCH };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else (root.LF = root.LF || {}).messages = api;
})(globalThis);

// Pure-ish orchestration helpers (no chrome globals): settings defaults,
// merge of collected visits into the local store and delivery to the app via
// an injected fetch. Kept separate from background.js so it is unit-testable.
(function (root) {
  const P = (typeof module === 'object' && module.exports) ? require('./payload.js') : root.LF.payload;

  const DEFAULTS = {
    port: 47615,
    token: '',
    periodic: false,
    maxDays: 30,
    maxItems: 3000,
    maxSeconds: 90,
    foregroundTabs: true,
    youtubeUrl: 'https://www.youtube.com/feed/history',
    tiktokUrl: 'https://www.tiktok.com/setting/watch-history',
  };
  const STORE_CAP = 20000;

  function withDefaults(s) { return { ...DEFAULTS, ...(s || {}) }; }

  /** Adds fresh visits not yet stored. @returns {{store: object[], added: object[]}} */
  function merge(store, fresh) {
    const keys = new Set(store.map(P.visitKey));
    const added = [];
    for (const v of fresh) {
      const k = P.visitKey(v);
      if (keys.has(k)) continue;
      keys.add(k);
      added.push({ ...v, sent: false });
    }
    let next = store.concat(added);
    if (next.length > STORE_CAP) {
      next = next.sort((a, b) => Date.parse(b.time) - Date.parse(a.time)).slice(0, STORE_CAP);
    }
    return { store: next, added };
  }

  /**
   * Sends unsent visits in chunks. Mutates `sent` flags on success.
   * @returns {{sent: number, imported: number, error?: string}}
   */
  async function deliver(visits, settings, fetchImpl) {
    const base = `http://127.0.0.1:${settings.port}`;
    const headers = { Authorization: `Bearer ${settings.token}`, 'Content-Type': 'application/json' };
    const pending = visits.filter((v) => !v.sent);
    let sent = 0, imported = 0;
    if (!settings.token) return { sent, imported, error: 'not-paired' };
    for (const part of P.chunk(pending, P.MAX_CHUNK)) {
      let res;
      try {
        res = await fetchImpl(`${base}/v1/watch-history`, { method: 'POST', headers, body: JSON.stringify(P.buildPayload(part)) });
      } catch (e) {
        return { sent, imported, error: 'unreachable' };
      }
      if (res.status === 401) return { sent, imported, error: 'bad-token' };
      if (res.status === 503) {
        // "locked", or a retryable "busy"/"import-failed"; visits stay unsent.
        let reason = 'locked';
        try { reason = (await res.json()).error || reason; } catch (e) { /* ignore */ }
        return { sent, imported, error: reason === 'locked' ? 'locked' : 'app-busy' };
      }
      if (res.status === 413) return { sent, imported, error: 'too-large' };
      if (!res.ok) return { sent, imported, error: `http-${res.status}` };
      let body = {};
      try { body = await res.json(); } catch (e) { /* ignore */ }
      for (const v of part) v.sent = true;
      sent += part.length;
      imported += Number(body.imported) || 0;
    }
    return { sent, imported };
  }

  async function ping(settings, fetchImpl) {
    try {
      const res = await fetchImpl(`http://127.0.0.1:${settings.port}/v1/ping`, { headers: { Authorization: `Bearer ${settings.token}` } });
      if (res.status === 401) return { error: 'bad-token' };
      if (!res.ok) return { error: `http-${res.status}` };
      const body = await res.json();
      return { ok: true, unlocked: !!body.unlocked };
    } catch (e) {
      return { error: 'unreachable' };
    }
  }

  const MESSAGES = {
    'not-logged-in': 'Not logged in (the history page asked for a sign-in)',
    layout: 'Page layout not recognized (the site may have changed)',
    'tab-timeout': 'The page did not finish loading',
    unreachable: 'Lifenizer app not reachable (is it running? check the port)',
    'bad-token': 'Lifenizer rejected the token (re-pair on the options page)',
    locked: 'Vault is locked, unlock Lifenizer and sync again',
    'app-busy': 'Lifenizer is busy or the import failed, the entries are kept and sent on the next sync',
    'not-paired': 'Not paired with the app, use "Download export" or enter port and token',
    'too-large': 'The app refused the request as too large',
  };
  const message = (code) => MESSAGES[code] || `Error: ${code}`;

  const api = { DEFAULTS, STORE_CAP, withDefaults, merge, deliver, ping, message };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else (root.LF = root.LF || {}).sync = api;
})(globalThis);

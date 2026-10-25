// Pure-ish orchestration helpers (no chrome globals): settings defaults,
// merge of collected visits into the local store and delivery to the app via
// an injected fetch. Kept separate from background.js so it is unit-testable.
(function (root) {
  const P = (typeof module === 'object' && module.exports) ? require('./payload.js') : root.LF.payload;

  const DEFAULTS = {
    port: 47615,
    token: '',
    periodic: false,
    youtubeAccount: '',
    tiktokAccount: '',
    whatsappEnabled: false,
    discordEnabled: false,
    maxDays: 30,
    maxItems: 3000,
    maxSeconds: 90,
    foregroundTabs: true,
    youtubeUrl: 'https://www.youtube.com/feed/history',
    tiktokUrl: 'https://www.tiktok.com/setting/watch-history',
  };
  const STORE_CAP = 20000;
  const selection = value => { const s = typeof value === 'string' ? value.trim() : ''; return s.startsWith('@') ? s.toLowerCase() : s; };
  function accountMatches(v, settings) {
    const expected = selection(settings[`${v.platform}Account`]);
    return !!expected && selection(v.accountSelection) === expected && !!v.account &&
      [v.account.id, v.account.handle].includes(expected);
  }

  function withDefaults(s) { return { ...DEFAULTS, ...(s || {}) }; }

  /** Adds fresh visits not yet stored. @returns {{store: object[], added: object[]}} */
  function merge(store, fresh) {
    const ownerKey = v => JSON.stringify([selection(v.accountSelection), v.account?.id || '', v.account?.handle || '', P.visitKey(v)]);
    const keys = new Set(store.map(ownerKey));
    const added = [];
    for (const v of fresh) {
      const k = ownerKey(v);
      if (keys.has(k)) continue;
      keys.add(k);
      added.push({ ...v, sent: false });
    }
    let next = store.concat(added);
    if (next.length > STORE_CAP) {
      const pending = next.filter(v => !v.sent);
      next = pending.concat(next.filter(v => v.sent).sort((a, b) => Date.parse(b.time) - Date.parse(a.time)).slice(0, Math.max(0, STORE_CAP - pending.length)));
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
    const pending = visits.filter((v) => !v.sent && accountMatches(v, settings));
    const held = visits.filter(v => !v.sent && !accountMatches(v, settings)).length;
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
      let body;
      try { body = await res.json(); } catch (e) { /* ignore */ }
      if (!body || body.accepted !== part.length || !Number.isInteger(body.imported) || body.imported < 0 || body.imported > part.length) {
        return { sent, imported, error: 'invalid-response' };
      }
      for (const v of part) v.sent = true;
      sent += part.length;
      imported += body.imported;
    }
    return { sent, imported, ...(held ? { error: 'account-queue-held', held } : {}) };
  }

  async function ping(settings, fetchImpl) {
    if (!settings.token) return { error: 'not-paired' };
    try {
      const res = await fetchImpl(`http://127.0.0.1:${settings.port}/v1/ping`, { headers: { Authorization: `Bearer ${settings.token}` }, signal: AbortSignal.timeout(10000) });
      if (res.status === 401) return { error: 'bad-token' };
      if (!res.ok) return { error: `http-${res.status}` };
      const body = await res.json();
      if (!body || body.app !== 'lifenizer' || typeof body.unlocked !== 'boolean') return { error: 'invalid-response' };
      return { ok: true, unlocked: body.unlocked };
    } catch (e) {
      return { error: 'unreachable' };
    }
  }

  const MESSAGES = {
    'account-queue-held': 'Unverified or differently configured account entries remain unsent. Recollect with the matching account.',
    'account-unconfigured': 'Configure the expected account in Settings before collecting.',
    'account-unverified': 'The signed-in account could not be verified.',
    'account-mismatch': 'The signed-in account differs from Settings. Nothing was imported.',
    'message-layout': 'Message layout unsupported or no open conversation. Open a supported chat; nothing is scraped from history.',
    'message-queue-failed': 'Messages could not be saved to the extension outbox.',
    'not-logged-in': 'Not logged in (the history page asked for a sign-in)',
    layout: 'Page layout not recognized (the site may have changed)',
    'tab-timeout': 'The page did not finish loading',
    unreachable: 'Lifenizer app not reachable (is it running? check the port)',
    'bad-token': 'Lifenizer rejected the token (re-pair on the options page)',
    locked: 'Vault is locked, unlock Lifenizer and sync again',
    'app-busy': 'Lifenizer is busy or the import failed, the entries are kept and sent on the next sync',
    'not-paired': 'Not paired with the app, use "Download export" or enter port and token',
    'too-large': 'The app refused the request as too large',
    'invalid-response': 'The app did not acknowledge all entries. Data stays queued; check the port and retry delivery.',
  };
  const message = (code) => MESSAGES[code] || `Error: ${code}`;

  const api = { DEFAULTS, STORE_CAP, withDefaults, selection, accountMatches, merge, deliver, ping, message };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else (root.LF = root.LF || {}).sync = api;
})(globalThis);

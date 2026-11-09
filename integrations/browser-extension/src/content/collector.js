// Isolated-world content script (youtube.com, tiktok.com). Listens for the
// background's "collect" command, scrolls the history page (bounded by item
// count, wall time, the last-synced marker and the cutoff date) and returns
// visits. Pure parsing lives in src/lib/*.
(function () {
  const ext = globalThis.browser || globalThis.chrome;
  const LF = globalThis.LF;
  const isYouTube = /(^|\.)youtube\.com$/.test(location.hostname);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  const responses = [];
  let initial = null;
  let collecting = false;
  let expectedAccount, collectionAccount, accountFailure;
  let requestId = 0;
  window.addEventListener('message', (ev) => {
    if (ev.source !== window || !ev.data || ev.data.__lifenizer !== true) return;
    if (ev.data.kind === 'response') {
      if (collecting) {
        // Do not associate an in-flight response with an account that has not
        // yet been verified for this collection.
        if (!collectionAccount) return;
        const check = LF.accounts.check(expectedAccount, ev.data.account);
        if (check.error || !LF.accounts.same(collectionAccount, ev.data.account)) {
          accountFailure = check.error ? check : { error: 'account-mismatch', account: ev.data.account };
          return;
        }
      }
      responses.push(ev.data.json);
      // Outside a sync only the most recent responses are kept.
      if (!collecting && responses.length > 20) responses.shift();
    }
    if (ev.data.kind === 'initial' && ev.data.requestId === requestId) initial = ev.data;
  });

  async function getInitial() {
    initial = null;
    requestId++;
    for (let i = 0; i < 20 && !initial; i++) {
      window.postMessage({ __lifenizer: 'request-initial', requestId }, '*');
      await sleep(400);
    }
    return initial;
  }

  function scrollDown() {
    const el = document.scrollingElement || document.documentElement;
    window.scrollTo(0, el.scrollHeight);
    window.dispatchEvent(new Event('scroll'));
  }

  async function collectYouTube(opts, init) {
    if (!init) return { error: 'layout', detail: 'page data not available' };
    if (init.loggedIn === false) return { error: 'not-logged-in' };
    const lang = LF.youtube.pageLang(init.lang);
    const now = new Date();
    let raw = [];
    let consumed = 0;
    const absorb = (json) => { raw = raw.concat(LF.youtube.extract(json).entries); };
    if (init.json) absorb(init.json);
    if (!raw.length && !responses.length && !init.json) return { error: 'layout', detail: 'no ytInitialData' };

    const started = Date.now();
    let stalls = 0, stoppedBy = 'end';
    const cutoffMs = opts.cutoffMs;
    for (;;) {
      if (accountFailure) return accountFailure;
      while (consumed < responses.length) absorb(responses[consumed++]);
      const { dated, undated } = LF.headers.assignDays(raw, lang, now, opts.maxDays + 5);
      const visits = dated.map((e) => LF.payload.makeVisit('youtube', {
        id: e.id, title: e.title, channel: e.channel, time: e.day, timePrecision: 'day',
      }));
      const marked = LF.payload.applyMarker(visits, opts.marker, cutoffMs);
      const done = (why) => ({
        platform: 'youtube', visits: marked.fresh, found: visits.length, known: marked.known,
        undated, stoppedBy: why, lang,
      });
      if (marked.stop) return done('marker');
      if (visits.length >= opts.maxItems) return done('max-items');
      if (Date.now() - started > opts.maxMs) return done('time-limit');
      if (stalls >= 4) {
        if (!raw.length) return { error: 'layout', detail: 'no video entries recognized' };
        return done(stoppedBy);
      }
      const before = raw.length + responses.length;
      scrollDown();
      await sleep(1500);
      const after = raw.length + responses.length;
      stalls = after === before && consumed === responses.length ? stalls + 1 : 0;
    }
  }

  function findHistoryButton() {
    const re = /watch history|viewing history|verlauf/i;
    for (const el of document.querySelectorAll('a,button,[role="button"],[role="menuitem"],li,div')) {
      if (el.children.length < 3 && re.test(el.textContent || '') && (el.textContent || '').length < 40) return el;
    }
    return null;
  }

  async function collectTikTok(opts) {
    await sleep(2500);
    if (!responses.length) { const b = findHistoryButton(); if (b) { b.click(); await sleep(2500); } }
    if (/\/login/.test(location.pathname)) return { error: 'not-logged-in' };
    const started = Date.now();
    const items = new Map();
    let consumed = 0, stalls = 0;
    const nowIso = new Date().toISOString();
    const take = () => {
      while (consumed < responses.length) {
        for (const it of LF.tiktok.mapResponse(responses[consumed++]).items) if (!items.has(it.id)) items.set(it.id, it);
      }
      if (!responses.length) {
        for (const a of document.querySelectorAll('a[href*="/video/"]')) {
          const id = LF.tiktok.idFromHref(a.getAttribute('href'));
          if (id && !items.has(id)) items.set(id, { id, title: (a.getAttribute('title') || a.textContent || '').trim() || undefined, time: undefined });
        }
      }
    };
    for (;;) {
      if (accountFailure) return accountFailure;
      take();
      const visits = [...items.values()].map((it) => LF.payload.makeVisit('tiktok', {
        id: it.id, title: it.title, channel: it.channel,
        time: it.time || nowIso, timePrecision: it.time ? 'exact' : 'day',
      }));
      const marked = LF.payload.applyMarker(visits, opts.marker, opts.cutoffMs);
      const done = (why) => ({ platform: 'tiktok', visits: marked.fresh, found: visits.length, known: marked.known, undated: 0, stoppedBy: why });
      if (marked.stop) return done('marker');
      if (visits.length >= opts.maxItems) return done('max-items');
      if (Date.now() - started > opts.maxMs) return done('time-limit');
      if (stalls >= 4) {
        if (!visits.length) return { error: 'layout', detail: 'no watch-history requests or video links seen' };
        return done('end');
      }
      const before = items.size + responses.length;
      scrollDown();
      await sleep(1500);
      take();
      stalls = items.size + responses.length === before ? stalls + 1 : 0;
    }
  }

  ext.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (!msg || msg.type !== 'lifenizer-collect') return false;
    if (collecting) { sendResponse({ error: 'busy' }); return false; }
    const configured = LF.accounts.check(msg.opts && msg.opts.expectedAccount, null);
    if (configured.error === 'account-unconfigured') { sendResponse(configured); return false; }
    collecting = true;
    expectedAccount = msg.opts.expectedAccount;
    collectionAccount = null;
    accountFailure = null;
    responses.length = 0;
    (async () => {
      const init = await getInitial();
      const checked = LF.accounts.check(expectedAccount, init && init.account);
      if (checked.error) return checked;
      collectionAccount = checked.account;
      const result = await (isYouTube ? collectYouTube(msg.opts, init) : collectTikTok(msg.opts));
      if (accountFailure) return accountFailure;
      if (result.error) return result;
      const latest = await getInitial();
      const finalCheck = LF.accounts.check(expectedAccount, latest && latest.account);
      if (accountFailure) return accountFailure;
      if (finalCheck.error) return finalCheck;
      if (!LF.accounts.same(collectionAccount, finalCheck.account)) return { error: 'account-mismatch', account: finalCheck.account };
      return { ...result, account: collectionAccount };
    })()
      .finally(() => { collecting = false; responses.length = 0; })
      .then(sendResponse)
      .catch((e) => sendResponse({ error: 'layout', detail: String(e && e.message || e) }));
    return true;
  });
})();

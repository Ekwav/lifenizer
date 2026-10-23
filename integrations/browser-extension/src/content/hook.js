// Runs in the page's own JS world (MAIN) on youtube.com and tiktok.com at
// document_start. It only OBSERVES what the page itself loads: it copies the
// JSON of the history-related responses to the extension's content script via
// window.postMessage. It does not issue requests of its own, read cookies or
// touch credentials.
(function () {
  if (window.__lifenizerHook) return;
  window.__lifenizerHook = true;
  const isYouTube = /(^|\.)youtube\.com$/.test(location.hostname);
  const WANT = isYouTube
    ? /\/youtubei\/v1\/browse/
    : /\/api\/.*(watch|view|browsing|browse)[_\-/]?history|\/api\/.*history\/(list|item)/i;

  // On YouTube the browse endpoint serves every page; only the history feed
  // is of interest, so nothing is copied during normal browsing.
  const relevant = () => !isYouTube || location.pathname.startsWith('/feed/history');

  function account() {
    try {
      const accounts = window.LF && window.LF.accounts;
      if (!accounts) return null;
      if (isYouTube) {
        const get = (key) => window.ytcfg && window.ytcfg.get && window.ytcfg.get(key);
        // This header is the active account menu, not a channel/video renderer.
        const header = document.querySelector('ytd-active-account-header-renderer #channel-handle');
        return accounts.youtube({ loggedIn: get('LOGGED_IN'), channelId: get('CHANNEL_ID') }, header && header.textContent);
      }
      let state = window.__UNIVERSAL_DATA_FOR_REHYDRATION__;
      if (!state) {
        const script = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__');
        try { state = script && JSON.parse(script.textContent); } catch (_) { /* unknown shape */ }
      }
      return accounts.tiktok(state && state.__DEFAULT_SCOPE__ && state.__DEFAULT_SCOPE__['webapp.app-context']);
    } catch (_) { return null; }
  }

  function emit(url, json, requestAccount) {
    if (!relevant()) return;
    try { window.postMessage({ __lifenizer: true, kind: 'response', url: String(url), json,
      account: window.LF.accounts.same(requestAccount, account()) ? requestAccount : null }, '*'); } catch (e) { /* ignore */ }
  }

  const origFetch = window.fetch;
  if (typeof origFetch === 'function') {
    window.fetch = function (input, init) {
      const url = typeof input === 'string' ? input : (input && input.url) || '';
      const wanted = WANT.test(url) && relevant();
      const requestAccount = wanted ? account() : null;
      const p = origFetch.apply(this, arguments);
      if (wanted) {
        p.then((res) => res.clone().json().then((j) => emit(url, j, requestAccount)).catch(() => {})).catch(() => {});
      }
      return p;
    };
  }

  const origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    if (WANT.test(String(url))) {
      const requestAccount = account();
      this.addEventListener('load', function () {
        try { emit(url, JSON.parse(this.responseText), requestAccount); } catch (e) { /* not json */ }
      });
    }
    return origOpen.apply(this, arguments);
  };

  window.addEventListener('message', (ev) => {
    if (ev.source !== window || !ev.data || ev.data.__lifenizer !== 'request-initial') return;
    let hl, loggedIn;
    try { hl = window.ytcfg && window.ytcfg.get && window.ytcfg.get('HL'); } catch (e) { /* ignore */ }
    try { loggedIn = window.ytcfg && window.ytcfg.get && window.ytcfg.get('LOGGED_IN'); } catch (e) { /* ignore */ }
    window.postMessage({
      __lifenizer: true,
      kind: 'initial',
      json: isYouTube ? (window.ytInitialData || null) : null,
      lang: hl || document.documentElement.lang || navigator.language,
      loggedIn: loggedIn === undefined ? null : !!loggedIn,
      account: account(),
      requestId: ev.data.requestId,
    }, '*');
  });
})();

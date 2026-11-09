// Fixed adapter diagnostics in the isolated world. Page-derived text is only
// returned by the separate, explicitly enabled private-content sample tool.
(() => {
  const ext = globalThis.browser || globalThis.chrome;
  const platform = { 'www.youtube.com': 'youtube', 'www.tiktok.com': 'tiktok', 'web.whatsapp.com': 'whatsapp', 'discord.com': 'discord' }[location.hostname];
  const selectors = {
    youtube: ['ytd-video-renderer', 'ytd-item-section-renderer', 'ytd-active-account-header-renderer'],
    tiktok: ['a[href*="/video/"]', '[data-e2e="profile-icon"]'],
    whatsapp: ['#main [data-id]', '#main header [title]'],
    discord: ['li[id^="chat-messages-"]', '[id^="message-content-"]', 'time[datetime]'],
  };
  const clip = (value, max) => typeof value === 'string' ? value.slice(0, max) : undefined;
  function selfAccount() {
    if (!['youtube', 'tiktok'].includes(platform)) return Promise.resolve(null);
    return new Promise(resolve => {
      const requestId = 'debug-' + crypto.randomUUID();
      const finish = account => { clearTimeout(timer); window.removeEventListener('message', receive); resolve(account); };
      const receive = event => {
        if (event.source !== window || event.data?.__lifenizer !== true || event.data.kind !== 'initial' || event.data.requestId !== requestId) return;
        const account = event.data.account;
        finish(account ? { id: clip(account.id, 128), handle: clip(account.handle, 128) } : null);
      };
      const timer = setTimeout(() => finish(null), 750);
      window.addEventListener('message', receive);
      window.postMessage({ __lifenizer: 'request-initial', requestId }, '*');
    });
  }
  async function inspect(operation, limit) {
    const account = await selfAccount();
    const result = { platform, lang: clip(document.documentElement.lang, 32), account,
      selectors: Object.fromEntries(selectors[platform].map(selector => [selector, Math.min(10000, document.querySelectorAll(selector).length)])) };
    if (operation === 'page_diagnostics') return result;
    if (platform === 'whatsapp' || platform === 'discord') {
      const nodes = [...document.querySelectorAll(selectors[platform][0])].slice(-limit);
      result.samples = nodes.map(node => globalThis.LF.messages[platform](node, location, document)).filter(globalThis.LF.messages.valid)
        .map(message => ({ id: clip(message.id, 128), threadId: clip(message.threadId, 128), threadTitle: clip(message.threadTitle, 100),
          text: clip(message.text, 500), createdAt: clip(message.createdAt, 40), authorName: clip(message.authorName, 100) }));
      result.unrecognized = nodes.length - result.samples.length;
    } else {
      const selector = platform === 'youtube' ? 'ytd-video-renderer a#video-title[href]' : 'a[href*="/video/"]';
      result.samples = [...document.querySelectorAll(selector)].slice(0, limit).map(node => {
        let id = null;
        try {
          const url = new URL(node.getAttribute('href'), location.origin);
          id = platform === 'youtube' ? url.searchParams.get('v') : /\/video\/(\d+)/.exec(url.pathname)?.[1];
        } catch (_) { /* unrecognized link */ }
        return { id: clip(id, 128), title: clip(node.getAttribute('title') || node.textContent?.trim(), 200) };
      });
    }
    return result;
  }
  ext.runtime.onMessage.addListener((message, sender, respond) => {
    if (sender.id !== ext.runtime.id || message?.type !== 'lifenizer-debug-page') return false;
    if (!platform || !['page_diagnostics', 'sample_visible_content'].includes(message.operation) || !Number.isInteger(message.limit) || message.limit < 1 || message.limit > 10) { respond({ error: 'invalid-debug-request' }); return false; }
    (async () => {
      const settings = (await ext.storage.local.get('settings')).settings || {};
      if (!settings.debugEnabled || (message.operation === 'sample_visible_content' && !settings.debugAllowContent)) return { error: 'debug-disabled' };
      const result = await inspect(message.operation, message.limit);
      const latest = (await ext.storage.local.get('settings')).settings || {};
      return latest.debugEnabled && latest.debugToken === settings.debugToken && (message.operation !== 'sample_visible_content' || latest.debugAllowContent) ? result : { error: 'debug-disabled' };
    })().then(respond, () => respond({ error: 'adapter-unavailable' }));
    return true;
  });
})();

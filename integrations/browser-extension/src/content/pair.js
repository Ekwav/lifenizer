(() => {
  if (window.top !== window) return;
  const ext = globalThis.browser || globalThis.chrome;
  if (location.origin === 'https://lifenizer.coflnet.com') {
    const check = () => ext.runtime.sendMessage({type:'lifenizer-discovery'}).then(state => {
      if (state) window.dispatchEvent(new CustomEvent('lifenizer-extension-state', {detail:JSON.stringify(state)}));
    }).catch(() => {});
    window.addEventListener('lifenizer-extension-check', check);
    document.addEventListener('click', event => {
      if (!event.isTrusted || event.button !== 0 || !event.target.closest('[data-lifenizer-connect]')) return;
      event.preventDefault(); event.stopImmediatePropagation();
      ext.runtime.sendMessage({type:'lifenizer-open-pair'}).catch(() => {});
    }, true);
    check();
  } else if (globalThis.LF.pair.parse(location.href)) {
    // The helper link only stages a nonce. Exchange requires a gesture in our own page.
    ext.runtime.sendMessage({type:'lifenizer-open-pair', link:location.href}).then(() => history.replaceState(null, '', '/v1/pair')).catch(() => {});
  }
})();

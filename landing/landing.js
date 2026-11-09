// Keep links in already-installed apps pointed at the focused setup page.
if (location.hash === '#extensions' && location.pathname !== '/extension') location.replace('/extension');

const labels = {
  'lifenizer.apk': 'Download Android APK',
  'lifenizer-linux-x64.tar.gz': 'Download Linux x64',
  'lifenizer-history-sync-chromium.zip': 'Chrome / Edge ZIP',
  'lifenizer-history-sync-firefox.zip': 'Firefox ZIP',
};
async function refreshDownloads() {
  const status = document.querySelector('#download-status');
  try {
    const response = await fetch('/api/downloads', { cache: 'no-store' });
    if (!response.ok) throw new Error('Unavailable');
    const files = await response.json();
    for (const link of document.querySelectorAll('[data-download]')) {
      const name = link.dataset.download;
      const available = files.some(file => file.name === name && file.available === true);
      link.textContent = available ? labels[name] : `${labels[name]} · unavailable`;
      link.setAttribute('aria-disabled', String(!available));
      if (available) link.href = `/downloads/${name}`;
      else link.removeAttribute('href');
    }
    status.textContent = document.querySelector('[data-download][aria-disabled="false"]')
      ? 'Direct downloads · no app store account needed'
      : 'Downloads are not available yet. Please try again later.';
  } catch {
    for (const link of document.querySelectorAll('[data-download]')) {
      link.textContent = `${labels[link.dataset.download]} · unavailable`;
      link.removeAttribute('href');
      link.setAttribute('aria-disabled', 'true');
    }
    status.replaceChildren('Downloads could not be checked. ');
    const retry = document.createElement('button');
    retry.type = 'button';
    retry.textContent = 'Try again';
    retry.addEventListener('click', refreshDownloads);
    status.append(retry);
  }
}
window.addEventListener('lifenizer-extension-state', event => {
  let state;
  try { state = JSON.parse(event.detail); } catch { return; }
  if (state?.installed !== true) return;
  document.querySelector('#connection-status').textContent = state.local
    ? (state.unlocked ? 'Browser companion and local app detected. Open Lifenizer to continue.' : 'Local app detected. Unlock your vault in Lifenizer to continue.')
    : 'Browser companion detected. Open Lifenizer to connect your app.';
});
window.addEventListener('focus', () => window.dispatchEvent(new CustomEvent('lifenizer-extension-check')));
document.querySelector('[data-lifenizer-connect]').addEventListener('click', () => {
  document.querySelector('#connection-status').textContent = 'Continue in Lifenizer or the browser companion. If the app is missing, choose Get the app.';
});
window.dispatchEvent(new CustomEvent('lifenizer-extension-check'));
refreshDownloads();

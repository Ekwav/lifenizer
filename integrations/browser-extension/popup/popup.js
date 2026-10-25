const ext = globalThis.browser || globalThis.chrome;
const $ = (id) => document.getElementById(id);
const get = k => ext.storage.local.get(k);
const send = m => ext.runtime.sendMessage(m).catch(() => null);

function line(parent, text, cls) {
  const d = document.createElement('div');
  if (cls) d.className = cls;
  d.textContent = text;
  parent.appendChild(d);
}

function renderPlatform(el, name, s) {
  el.replaceChildren();
  const b = document.createElement('b');
  b.textContent = name;
  el.appendChild(b);
  if (!s) return line(el, 'Not synced yet', 'muted');
  if (s.state === 'collecting') return line(el, 'Collecting...');
  if (s.state === 'error') return line(el, (s.message || s.error) + (s.detail ? ` (${s.detail})` : ''), 'err');
  line(el, `found ${s.found}, new ${s.fresh}, sent ${s.sent}` + (s.known ? `, already known ${s.known}` : ''));
  if (s.undated) line(el, `undated (header not recognized, skipped): ${s.undated}`, 'err');
  line(el, `stopped: ${s.stoppedBy || ''}`, 'muted');
}

async function render() {
  const { status = {}, settings = {} } = await get(['status', 'settings']);
  renderPlatform($('youtube'), 'YouTube', status.youtube);
  renderPlatform($('tiktok'), 'TikTok', status.tiktok);
  for (const platform of ['whatsapp', 'discord']) {
    const s = status[platform], el = $(platform);
    el.replaceChildren();
    line(el, platform === 'whatsapp' ? 'WhatsApp Web' : 'Discord Web');
    line(el, !settings[`${platform}Enabled`] ? 'Disabled — enable in Settings' : s?.message || 'Enabled — open a logged-in conversation', s?.state === 'error' ? 'err' : 'muted');
  }
  const messages = $('messages');
  messages.replaceChildren();
  if (status.messages) line(messages, `${status.messages.sent || 0} messages delivered, ${status.messages.pending || 0} waiting. ${status.messages.message || ''}`, status.messages.state === 'error' ? 'err' : 'muted');
  const state = await send({ type: 'lifenizer-state' });
  $('sync').disabled = $('retry').disabled = !!state?.running;
  const d = status.delivery, el = $('delivery');
  el.replaceChildren();
  if (status.fatal) line(el, status.fatal, 'err');
  else if (d && d.state === 'error') line(el, `${d.message} (${d.pending} waiting)`, 'err');
  else if (d && d.state === 'done') line(el, `Delivered ${d.sent}, imported ${d.imported}`, 'ok');
  else if (d && d.state === 'sending') line(el, 'Sending...');
}

async function checkApp() {
  const r = await send({ type: 'lifenizer-ping' });
  const el = $('app');
  if (!r) { el.textContent = 'Extension unavailable. Reopen the popup or reload the extension.'; return; }
  if (r.ok) { el.className = r.unlocked ? 'ok' : 'err'; el.textContent = r.unlocked ? 'Lifenizer connected' : 'Lifenizer connected, vault locked'; return; }
  el.className = 'err';
  el.textContent = globalThis.LF.sync.message(r.error);
}

function download(name, data) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 1)], { type: 'application/json' }));
  const a = document.createElement('a');
  a.href = url; a.download = name; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 5000);
}

$('sync').onclick = async () => { await send({ type: 'lifenizer-sync', ...($('platform').value ? { platforms: [$('platform').value] } : {}) }); render(); };
$('retry').onclick = async () => { await send({ type: 'lifenizer-retry' }); render(); checkApp(); };
$('options').onclick = (e) => { e.preventDefault(); ext.runtime.openOptionsPage(); };
$('download').onclick = async () => {
  const { visits = [], messages = [] } = await get(['visits', 'messages']);
  const P = globalThis.LF.payload;
  const yt = P.buildTakeoutYoutube(visits), tt = P.buildTiktokExport(visits);
  if (yt.length) download('watch-history.json', yt);
  if (tt.Activity['Video Browsing History'].VideoList.length) download('user_data.json', tt);
  if (messages.length) download('lifenizer-messages.json', { source: 'lifenizer-extension', version: 1, messages: messages.map(({ sent, ...m }) => m) });
  if (!yt.length && !tt.Activity['Video Browsing History'].VideoList.length && !messages.length) $('delivery').textContent = 'Nothing collected yet. Sync configured history or enable message capture in Settings.';
};
ext.storage.onChanged.addListener(render);
render(); checkApp();

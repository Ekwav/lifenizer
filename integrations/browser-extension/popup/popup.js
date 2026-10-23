const ext = globalThis.browser || globalThis.chrome;
const $ = (id) => document.getElementById(id);
const get = (k) => new Promise((res) => { const r = ext.storage.local.get(k, res); if (r && r.then) r.then(res); });
const send = (m) => new Promise((res) => { const r = ext.runtime.sendMessage(m, res); if (r && r.then) r.then(res, () => res(null)); });

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
  const { status = {} } = await get('status');
  renderPlatform($('youtube'), 'YouTube', status.youtube);
  renderPlatform($('tiktok'), 'TikTok', status.tiktok);
  $('sync').disabled = !!status.running;
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
  if (!r) { el.textContent = 'App status unknown'; return; }
  if (r.ok) { el.className = r.unlocked ? 'ok' : 'err'; el.textContent = r.unlocked ? 'Lifenizer connected' : 'Lifenizer connected, vault locked'; return; }
  el.className = 'err';
  el.textContent = r.error === 'bad-token' ? 'Token rejected, check Settings' : 'App not reachable. Use Download export or check Settings.';
}

function download(name, data) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 1)], { type: 'application/json' }));
  const a = document.createElement('a');
  a.href = url; a.download = name; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 5000);
}

$('sync').onclick = async () => { await send({ type: 'lifenizer-sync' }); render(); };
$('options').onclick = (e) => { e.preventDefault(); ext.runtime.openOptionsPage(); };
$('download').onclick = async () => {
  const { visits = [] } = await get('visits');
  const P = globalThis.LF.payload;
  const yt = P.buildTakeoutYoutube(visits), tt = P.buildTiktokExport(visits);
  if (yt.length) download('watch-history.json', yt);
  if (tt.Activity['Video Browsing History'].VideoList.length) download('user_data.json', tt);
  if (!yt.length && !tt.Activity['Video Browsing History'].VideoList.length) $('delivery').textContent = 'Nothing collected yet. Run Sync now first.';
};
ext.storage.onChanged.addListener(render);
render(); checkApp();

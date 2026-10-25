const ext = globalThis.browser || globalThis.chrome;
const $ = (id) => document.getElementById(id);
const get = (k) => ext.storage.local.get(k);
const set = (o) => Promise.resolve(ext.storage.local.set(o));
const send = (m) => ext.runtime.sendMessage(m).catch(() => null);
const DEFAULTS = { port: 47615, token: '', periodic: false, maxDays: 30, maxItems: 3000, maxSeconds: 90, foregroundTabs: true,
  youtubeAccount: '', tiktokAccount: '', whatsappEnabled: false, discordEnabled: false,
  debugEnabled: false, debugToken: '', debugAllowContent: false,
  youtubeUrl: 'https://www.youtube.com/feed/history', tiktokUrl: 'https://www.tiktok.com/setting/watch-history' };
const FIELDS = Object.keys(DEFAULTS);

async function load() {
  const s = { ...DEFAULTS, ...((await get('settings')).settings || {}) };
  for (const f of FIELDS) { const el = $(f); if (el.type === 'checkbox') el.checked = !!s[f]; else el.value = s[f]; }
}
function read() {
  const s = {};
  for (const f of FIELDS) { const el = $(f); s[f] = el.type === 'checkbox' ? el.checked : el.type === 'number' ? Number(el.value) : el.value.trim(); }
  return s;
}
const say = (t) => { $('msg').textContent = t; };
$('save').onclick = async () => {
  if (FIELDS.some(f => !$(f).reportValidity())) return;
  const settings = read();
  if (settings.debugEnabled && (settings.debugToken.length < 32 || settings.debugToken.length > 256)) { say('Debug requires a separate 32–256 character secret'); return; }
  await set({ settings }); say('Saved');
};
$('test').onclick = async () => {
  if (!$('port').reportValidity()) return;
  say('Testing connection…');
  const r = await send({ type: 'lifenizer-ping', connection: { port: Number($('port').value), token: $('token').value.trim() } });
  say(!r ? 'Extension unavailable. Reload the extension and retry.' : r.ok ? (r.unlocked ? 'Connected. Save to apply these settings.' : 'Connected, vault locked. Unlock Lifenizer, then save settings.') : globalThis.LF.sync.message(r.error));
};
$('clear').onclick = async () => {
  if (!confirm('Permanently delete all locally collected watch history and messages, including undelivered data? Download an export first if needed. Enabled message capture will continue.')) return;
  $('clear').disabled = true;
  const r = await send({ type: 'lifenizer-clear' });
  $('clear').disabled = false;
  say(r?.ok ? 'Collected data deleted' : r?.error === 'sync-running' ? 'Sync is running. Wait for it to finish, then retry deletion.' : 'Data could not be deleted. Reload the extension and retry.');
};
load();

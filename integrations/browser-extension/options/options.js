const ext = globalThis.browser || globalThis.chrome;
const $ = (id) => document.getElementById(id);
const get = (k) => new Promise((res) => { const r = ext.storage.local.get(k, res); if (r && r.then) r.then(res); });
const set = (o) => Promise.resolve(ext.storage.local.set(o));
const send = (m) => new Promise((res) => { const r = ext.runtime.sendMessage(m, res); if (r && r.then) r.then(res, () => res(null)); });
const DEFAULTS = { port: 47615, token: '', periodic: false, maxDays: 30, maxItems: 3000, maxSeconds: 90, foregroundTabs: true,
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
$('save').onclick = async () => { await set({ settings: read() }); say('Saved'); };
$('test').onclick = async () => {
  await set({ settings: read() });
  const r = await send({ type: 'lifenizer-ping' });
  say(!r ? 'No answer' : r.ok ? (r.unlocked ? 'Connected' : 'Connected, vault locked') : r.error === 'bad-token' ? 'Token rejected' : 'App not reachable');
};
$('clear').onclick = async () => { await set({ visits: [], status: {} }); say('Collected data deleted'); };
load();

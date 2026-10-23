// MV3 background (service worker in Chromium, event page in Firefox).
// Orchestrates: open history tab -> ask content script to collect -> merge
// into local store -> deliver to the desktop app on 127.0.0.1.
if (typeof importScripts === 'function') {
  importScripts('lib/headers.js', 'lib/youtube.js', 'lib/tiktok.js', 'lib/payload.js', 'lib/sync.js', 'lib/messages.js');
}
const ext = globalThis.browser || globalThis.chrome;
const LF = globalThis.LF;
const ALARM = 'lifenizer-sync';
let running = false;

const get = keys => ext.storage.local.get(keys);
const set = (obj) => Promise.resolve(ext.storage.local.set(obj));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function loadSettings() { return LF.sync.withDefaults((await get('settings')).settings); }

async function setStatus(patch) {
  const cur = (await get('status')).status || {};
  await set({ status: { ...cur, ...patch, updated: new Date().toISOString() } });
}

function waitForLoad(tabId, timeoutMs) {
  return new Promise((resolve) => {
    let done = false;
    const finish = (ok) => { if (done) return; done = true; ext.tabs.onUpdated.removeListener(listener); clearTimeout(timer); resolve(ok); };
    const listener = (id, info) => { if (id === tabId && info.status === 'complete') finish(true); };
    const timer = setTimeout(() => finish(false), timeoutMs);
    ext.tabs.onUpdated.addListener(listener);
    Promise.resolve(ext.tabs.get(tabId)).then((t) => { if (t && t.status === 'complete') finish(true); }, () => {});
  });
}

async function collectIn(platform, url, settings, marker, cutoffMs) {
  const tab = await ext.tabs.create({ url, active: !!settings.foregroundTabs && !settings.quiet });
  try {
    if (!(await waitForLoad(tab.id, 45000))) return { error: 'tab-timeout' };
    const current = await ext.tabs.get(tab.id);
    const host = new URL(current.url || url).hostname;
    const want = platform === 'youtube' ? /(^|\.)youtube\.com$/ : /(^|\.)tiktok\.com$/;
    if (!want.test(host) || /\/(login|signin)/i.test(current.url)) return { error: 'not-logged-in' };
    const opts = { expectedAccount: settings[`${platform}Account`], marker, cutoffMs, maxDays: settings.maxDays, maxItems: settings.maxItems, maxMs: settings.maxSeconds * 1000 };
    for (let attempt = 0; attempt < 6; attempt++) {
      try {
        const res = await ext.tabs.sendMessage(tab.id, { type: 'lifenizer-collect', opts });
        if (res) return res;
      } catch (e) { /* content script not ready yet */ }
      await sleep(1000);
    }
    return { error: 'layout', detail: 'content script did not answer' };
  } finally {
    try { await ext.tabs.remove(tab.id); } catch (e) { /* already closed */ }
  }
}

async function syncPlatform(platform, settings) {
  const data = await get(['visits', 'firstSync']);
  let store = data.visits || [];
  const mine = store.filter((v) => v.platform === platform && LF.sync.accountMatches(v, settings));
  const marker = LF.payload.makeMarker(mine);
  const cutoffMs = mine.length ? Date.now() - 400 * 864e5 : Date.now() - settings.maxDays * 864e5;
  const url = platform === 'youtube' ? settings.youtubeUrl : settings.tiktokUrl;
  await setStatus({ [platform]: { state: 'collecting' } });
  const res = await collectIn(platform, url, settings, marker, cutoffMs);
  if (res.error) {
    await setStatus({ [platform]: { state: 'error', error: res.error, message: LF.sync.message(res.error), detail: res.detail } });
    return;
  }
  if (!res.account || !LF.sync.accountMatches({ platform, account: res.account, accountSelection: settings[`${platform}Account`] }, settings)) {
    await setStatus({ [platform]: { state: 'error', error: 'account-mismatch', message: LF.sync.message('account-mismatch') } });
    return;
  }
  // Collection can outlive a settings edit. Never bind that result to new settings.
  if (LF.sync.selection((await loadSettings())[`${platform}Account`]) !== LF.sync.selection(settings[`${platform}Account`])) return;
  const merged = LF.sync.merge(store, res.visits.map(v => ({ ...v, account: res.account, accountSelection: LF.sync.selection(settings[`${platform}Account`]) })));
  await set({ visits: merged.store });
  await setStatus({
    [platform]: { state: 'collected', found: res.found, fresh: merged.added.length, known: res.known, undated: res.undated || 0, stoppedBy: res.stoppedBy, sent: 0 },
  });
}

function configuredFetch(settings, keys) {
  return async (url, opts) => {
    const current = await loadSettings();
    if (['port', 'token', ...keys].some(k => current[k] !== settings[k])) throw new Error('settings-changed');
    return fetch(url, { ...opts, signal: AbortSignal.timeout(10000) });
  };
}
async function deliverAll(settings) {
  settings = await loadSettings();
  const store = (await get('visits')).visits || [];
  const pending = store.filter((v) => !v.sent);
  if (!pending.length) { await setStatus({ delivery: { state: 'idle', pending: 0 } }); return; }
  await setStatus({ delivery: { state: 'sending', pending: pending.length } });
  const wasPending = new Set(pending);
  const r = await LF.sync.deliver(store, settings, configuredFetch(settings, ['youtubeAccount', 'tiktokAccount']));
  await set({ visits: store });
  const status = (await get('status')).status || {};
  for (const p of ['youtube', 'tiktok']) {
    if (status[p] && status[p].state === 'collected') {
      status[p].sent = pending.filter((v) => v.platform === p && v.sent && wasPending.has(v)).length;
    }
  }
  await setStatus({
    youtube: status.youtube, tiktok: status.tiktok,
    delivery: r.error
      ? { state: 'error', error: r.error, message: LF.sync.message(r.error), sent: r.sent, pending: store.filter((v) => !v.sent).length }
      : { state: 'done', sent: r.sent, imported: r.imported, pending: 0 },
  });
}

// quiet: never steal focus (used by the daily alarm).
async function syncNow(platforms, quiet) {
  if (running) return;
  running = true;
  try {
    const settings = { ...(await loadSettings()), quiet: !!quiet };
    await setStatus({ running: true, started: new Date().toISOString() });
    for (const p of platforms || ['youtube', 'tiktok']) await syncPlatform(p, settings);
    await deliverAll(settings);
    await queueMessages(() => deliverMessages());
  } catch (e) {
    await setStatus({ fatal: String(e && e.message || e) });
  } finally {
    running = false;
    await setStatus({ running: false });
  }
}

async function applyAlarm() {
  const s = await loadSettings();
  await ext.alarms.clear(ALARM);
  if (s.periodic) ext.alarms.create(ALARM, { periodInMinutes: 24 * 60, delayInMinutes: 60 });
}

ext.alarms.onAlarm.addListener((a) => { if (a.name === ALARM) syncNow(undefined, true); });
ext.runtime.onInstalled.addListener(applyAlarm);
ext.runtime.onStartup.addListener(() => { applyAlarm(); queueMessages(deliverMessages); });
ext.storage.onChanged.addListener((changes, area) => { if (area === 'local' && changes.settings) { applyAlarm(); queueMessages(deliverMessages); } });

// Serialize read/modify/write operations so concurrent tabs cannot lose outbox entries.
let messageTail = Promise.resolve();
function queueMessages(action) {
  const result = messageTail.then(action);
  messageTail = result.catch(() => {});
  return result;
}
async function deliverMessages() {
  const settings = await loadSettings();
  const store = (await get('messages')).messages || [];
  const result = await LF.messages.deliver(store, settings, configuredFetch(settings, ['whatsappEnabled', 'discordEnabled']));
  await set({ messages: store });
  await setStatus({ messages: { state: result.error ? 'error' : 'done', sent: result.sent,
    pending: store.filter(m => !m.sent).length, ...(result.error ? { error: result.error, message: LF.sync.message(result.error) } : {}) } });
}
function extensionPage(sender) {
  return sender.id === ext.runtime.id &&
    [ext.runtime.getURL('popup/popup.html'), ext.runtime.getURL('options/options.html')].includes(sender.url);
}
function chatSender(sender, platform) {
  if (sender.id !== ext.runtime.id || !sender.tab || sender.frameId !== 0) return false;
  try {
    const url = new URL(sender.url);
    return url.protocol === 'https:' && (platform === 'whatsapp'
      ? url.hostname === 'web.whatsapp.com'
      : platform === 'discord' && url.hostname === 'discord.com' && /^\/channels\/(?:@me|\d+)\/\d+$/.test(url.pathname));
  } catch (_) { return false; }
}
ext.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg) return false;
  if (msg.type === 'lifenizer-messages' || msg.type === 'lifenizer-message-status') {
    if (!chatSender(sender, msg.platform)) return false;
    const work = async () => {
      const settings = await loadSettings();
      if (!settings[`${msg.platform}Enabled`]) return { error: 'disabled' };
      if (msg.type === 'lifenizer-message-status') {
        await setStatus({ [msg.platform]: { state: msg.error ? 'error' : 'watching', error: msg.error,
          message: msg.error ? LF.sync.message(msg.error) : 'Watching newly rendered messages in open chats' } });
        return { ok: true };
      }
      if (!Array.isArray(msg.messages) || !msg.messages.length || msg.messages.length > LF.messages.MAX_BATCH ||
          msg.messages.some(m => !LF.messages.valid(m) || m.platform !== msg.platform ||
            (m.platform === 'discord' && new URL(sender.url).pathname.split('/').pop() !== m.threadId))) return { error: 'invalid-messages' };
      const store = LF.messages.merge((await get('messages')).messages || [], msg.messages);
      await set({ messages: store });
      // Durable enqueue is the acknowledgement; app failures keep the records unsent.
      return { ok: true };
    };
    queueMessages(work).then(result => { sendResponse(result); if (result.ok && msg.type === 'lifenizer-messages') queueMessages(deliverMessages); },
      () => sendResponse({ error: 'message-queue-failed' }));
    return true;
  }
  if (!extensionPage(sender)) return false;
  if (msg.type === 'lifenizer-sync') {
    if (msg.platforms !== undefined && (!Array.isArray(msg.platforms) || msg.platforms.some(p => !['youtube', 'tiktok'].includes(p)))) return false;
    const started = !running; syncNow(msg.platforms); sendResponse({ started }); return false;
  }
  if (msg.type === 'lifenizer-ping') {
    loadSettings().then((s) => LF.sync.ping(s, (u, o) => fetch(u, o))).then(sendResponse);
    return true;
  }
  return false;
});

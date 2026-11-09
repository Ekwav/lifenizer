const test = require('node:test');
const assert = require('node:assert/strict');
const M = require('../src/lib/messages');
const S = require('../src/lib/sync');
const message = n => ({ platform: 'discord', threadId: '123', threadTitle: 'Friends', id: String(n), text: 'Hello', createdAt: '2026-10-23T12:00:00Z', sourceUrl: `https://discord.com/channels/@me/123/${n}` });
const node = fields => ({ id: fields.id, getAttribute: name => fields[name], textContent: fields.textContent, querySelector: selector => fields[selector] || null });

test('Discord reads only active channel DOM with exact IDs, time and visible author', () => {
  const item = node({ id: 'chat-messages-123-456', '[id^="message-content-"]': node({ textContent: 'Hello' }), 'time[datetime]': node({ datetime: '2026-10-23T12:00:00Z' }), '[id^="message-username-"]': node({ textContent: 'Alice' }), 'img[src*="/avatars/"]': node({ src: 'https://cdn.discordapp.com/avatars/789/icon.webp' }) });
  const m = M.discord(item, { pathname: '/channels/@me/123' }, { title: 'Friends | Discord' });
  assert.equal(m.id, '456'); assert.equal(m.threadId, '123'); assert.equal(m.authorId, '789'); assert.equal(m.authorName, 'Alice'); assert.ok(M.valid(m));
  assert.equal(M.discord(item, { pathname: '/channels/@me/999' }, {}), null);
});

test('WhatsApp uses stable data IDs and explicit locale, unsupported timestamps fail closed', () => {
  const item = node({ 'data-id': 'false_491234@c.us_ABC', '.selectable-text.copyable-text': node({ textContent: 'Hi there' }), '[data-pre-plain-text]': node({ 'data-pre-plain-text': '[14:25, 23/10/2026] Alice: ' }) });
  const doc = { documentElement: { lang: 'de-DE' }, querySelector: () => node({ title: 'Alice' }) };
  const m = M.whatsapp(item, {}, doc);
  assert.equal(m.threadId, '491234@c.us'); assert.equal(m.id, 'ABC'); assert.equal(m.authorName, 'Alice'); assert.ok(M.valid(m));
  assert.equal(M.whatsapp(item, {}, { ...doc, documentElement: { lang: '' } }), null);
  assert.equal(M.whatsapp(node({ 'data-id': 'unrecognized' }), {}, doc), null);
});

test('message outbox dedupes, preserves offline entries and delivers bounded acknowledged batches', async () => {
  let store = M.merge([], Array.from({ length: 60 }, (_, i) => message(i)));
  store = M.merge(store, [message(1)]); assert.equal(store.length, 60);
  const settings = { port: 47615, token: 'secret', discordEnabled: true };
  assert.equal((await M.deliver(store, settings, async () => { throw Error('offline'); })).error, 'unreachable');
  assert.equal(store.filter(m => m.sent).length, 0);
  const calls = [];
  const result = await M.deliver(store, settings, async (url, opts) => {
    const body = JSON.parse(opts.body); calls.push(body.messages.length);
    assert.equal(url, 'http://127.0.0.1:47615/v1/messages'); assert.equal(opts.headers.Authorization, 'Bearer secret');
    assert.equal(body.source, 'lifenizer-extension'); assert.equal(body.version, 1); assert.ok(!('sent' in body.messages[0]));
    return { ok: true, json: async () => ({ ok: true, imported: 1 }) };
  });
  assert.deepEqual(calls, [25, 25, 10]); assert.equal(result.sent, 60);
  const disabled = [message(100)];
  await M.deliver(disabled, { ...settings, discordEnabled: false }, () => { throw Error('must not send'); });
  assert.ok(!disabled[0].sent);
  const invalidAck = [message(101)];
  await M.deliver(invalidAck, settings, async () => ({ ok: true, status: 200, json: async () => ({}) }));
  assert.ok(!invalidAck[0].sent);
});

test('history queue holds legacy, wrong-account and changed-selection records without delivery', async () => {
  const visit = { platform: 'youtube', id: 'video', time: '2026-10-23T12:00:00Z', account: { handle: '@mine', id: 'stable' }, accountSelection: '@mine' };
  const settings = S.withDefaults({ token: 'token', youtubeAccount: '@MINE' });
  assert.ok(S.accountMatches(visit, settings));
  const held = [{ ...visit, accountSelection: '@other' }, { ...visit, account: undefined }, { ...visit, account: { handle: '@other' } }];
  const r = await S.deliver(held, settings, () => { throw Error('must not send'); });
  assert.equal(r.error, 'account-queue-held'); assert.equal(r.held, 3); assert.ok(held.every(v => !v.sent));
});

test('message acknowledgments reject malformed counts and explain authentication and locked errors', async () => {
  const settings = { port: 47615, token: 'secret', discordEnabled: true };
  for (const body of [null, {}, { ok: true, imported: -1 }, { ok: true, imported: 2 }]) {
    const store = [message(1)];
    assert.equal((await M.deliver(store, settings, async () => ({ ok: true, status: 200, json: async () => body }))).error, 'invalid-response');
    assert.ok(!store[0].sent);
  }
  for (const [status, error] of [[401, 'bad-token'], [503, 'locked']]) {
    const store = [message(1)];
    assert.equal((await M.deliver(store, settings, async () => ({ ok: false, status, json: async () => ({ error: 'locked' }) }))).error, error);
    assert.ok(!store[0].sent);
  }
});

const test = require('node:test');
const assert = require('node:assert');
const P = require('../src/lib/payload.js');
const S = require('../src/lib/sync.js');

const yt = (id, iso, extra) => P.makeVisit('youtube', { id, title: 'T ' + id, channel: 'C', time: iso, timePrecision: 'day', ...extra });
const tt = (id, iso, p) => P.makeVisit('tiktok', { id, time: iso, timePrecision: p || 'day' });

test('loopback payload matches the contract', () => {
  const p = P.buildPayload([yt('aaaaaaaaaaa', '2026-10-05T10:00:00.000Z'), P.makeVisit('youtube', { id: 'bbbbbbbbbbb', title: 'x', time: '2026-10-05T10:00:00.000Z', timePrecision: 'exact' })]);
  assert.strictEqual(p.source, 'lifenizer-extension');
  assert.strictEqual(p.version, 1);
  assert.deepStrictEqual(p.visits[0], { url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa', title: 'T aaaaaaaaaaa', channel: 'C', time: '2026-10-05T10:00:00.000Z', timePrecision: 'day' });
  assert.ok(!('channel' in p.visits[1]));
});

test('chunking never exceeds 2000', () => {
  const list = Array.from({ length: 4500 }, (_, i) => i);
  assert.deepStrictEqual(P.chunk(list, 99999).map((c) => c.length), [2000, 2000, 500]);
  assert.strictEqual(P.buildPayloads(list.map((i) => yt('v' + String(i).padStart(10, '0'), '2026-10-05T10:00:00.000Z')), 5000).length, 3);
});

test('Takeout export shape', () => {
  const out = P.buildTakeoutYoutube([yt('aaaaaaaaaaa', '2026-10-05T10:00:00.000Z'), tt('7300000000000000001', '2026-10-05T10:00:00.000Z')]);
  assert.deepStrictEqual(out, [{ header: 'YouTube', title: 'Watched T aaaaaaaaaaa', titleUrl: 'https://www.youtube.com/watch?v=aaaaaaaaaaa', subtitles: [{ name: 'C' }], time: '2026-10-05T10:00:00.000Z' }]);
});

test('TikTok export shape, UTC date', () => {
  const out = P.buildTiktokExport([yt('aaaaaaaaaaa', '2026-10-05T10:00:00.000Z'), tt('7300000000000000001', '2026-10-05T23:59:58.000Z', 'exact')]);
  assert.deepStrictEqual(out, { Activity: { 'Video Browsing History': { VideoList: [{ Date: '2026-10-05 23:59:58', Link: 'https://www.tiktokv.com/share/video/7300000000000000001/' }] } } });
});

test('marker stops at known key and cutoff; keeps newer items', () => {
  const stored = [yt('old', '2026-10-03T12:00:00.000Z')];
  const marker = P.makeMarker(stored);
  const page = [yt('n1', '2026-10-05T12:00:00.000Z'), yt('old', '2026-10-03T12:00:00.000Z'), yt('x', '2026-10-02T12:00:00.000Z')];
  const r = P.applyMarker(page, marker, null);
  assert.deepStrictEqual(r.fresh.map((v) => v.id), ['n1', 'x']); // caller stops scrolling on r.stop
  assert.strictEqual(r.stop, true);
  const c = P.applyMarker(page, { keys: [] }, Date.parse('2026-10-04T00:00:00Z'));
  assert.deepStrictEqual(c.fresh.map((v) => v.id), ['n1']);
  assert.strictEqual(c.stop, true);
});

test('same video on another day is new for YouTube; tiktok day-precision dedupes per video', () => {
  const m = P.makeMarker([yt('a', '2026-10-03T12:00:00.000Z'), tt('7300000000000000001', '2026-10-03T12:00:00.000Z')]);
  assert.strictEqual(P.applyMarker([yt('a', '2026-10-05T12:00:00.000Z')], m, null).fresh.length, 1);
  assert.strictEqual(P.applyMarker([tt('7300000000000000001', '2026-10-09T12:00:00.000Z')], m, null).fresh.length, 0);
});

test('merge dedupes and marks unsent; deliver chunks and maps errors', async () => {
  const a = yt('aaaaaaaaaaa', '2026-10-05T12:00:00.000Z');
  let { store, added } = S.merge([], [a, a]);
  assert.strictEqual(added.length, 1);
  assert.strictEqual(S.merge(store, [a]).added.length, 0);

  const calls = [];
  const ok = async (url, o) => { calls.push([url, o]); return { status: 200, ok: true, json: async () => ({ accepted: 1, imported: 1 }) }; };
  const settings = S.withDefaults({ token: 'tok' });
  const r = await S.deliver(store, settings, ok);
  assert.deepStrictEqual([r.sent, r.imported, r.error], [1, 1, undefined]);
  assert.strictEqual(calls[0][0], 'http://127.0.0.1:47615/v1/watch-history');
  assert.strictEqual(calls[0][1].headers.Authorization, 'Bearer tok');
  assert.strictEqual(store[0].sent, true);

  const more = S.merge(store, [yt('bbbbbbbbbbb', '2026-10-05T12:00:00.000Z')]).store;
  const locked = await S.deliver(more, settings, async () => ({ status: 503, ok: false }));
  assert.strictEqual(locked.error, 'locked');
  assert.strictEqual(more[1].sent, false);
  assert.strictEqual((await S.deliver(more, settings, async () => ({ status: 401, ok: false }))).error, 'bad-token');
  assert.strictEqual((await S.deliver(more, settings, async () => { throw new Error('refused'); })).error, 'unreachable');
  assert.strictEqual((await S.deliver(more, S.withDefaults({}), ok)).error, 'not-paired');
});

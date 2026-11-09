const test = require('node:test');
const assert = require('node:assert');
const T = require('../src/lib/tiktok.js');

// SYNTHETIC response; the real shape is unverified.
const response = {
  statusCode: 0, hasMore: true, cursor: '1234',
  itemList: [
    { id: '7300000000000000001', desc: 'dance', author: { uniqueId: 'someone' }, video: {}, watchTime: 1790000000 },
    { id: '7300000000000000002', desc: '', author: 'bob', stats: {} },
    { id: '123', desc: 'too short id' },
    { id: '7300000000000000003', unrelated: true },
  ],
};

test('maps items, exact time when present, share-link url', () => {
  const r = T.mapResponse(response);
  assert.strictEqual(r.hasMore, true);
  assert.deepStrictEqual(r.items.map((i) => i.id), ['7300000000000000001', '7300000000000000002']);
  assert.strictEqual(r.items[0].url, 'https://www.tiktokv.com/share/video/7300000000000000001/');
  assert.strictEqual(r.items[0].time, new Date(1790000000 * 1000).toISOString());
  assert.strictEqual(r.items[0].channel, 'someone');
  assert.strictEqual(r.items[1].time, undefined);
  assert.strictEqual(r.items[1].title, 'TikTok video 7300000000000000002');
});

test('toIso handles seconds, millis, strings and rejects junk', () => {
  assert.strictEqual(T.toIso(1790000000000), T.toIso(1790000000));
  assert.strictEqual(T.toIso('2026-10-05T10:42:00Z'), '2026-10-05T10:42:00.000Z');
  assert.strictEqual(T.toIso(5), undefined);
  assert.strictEqual(T.toIso('nope'), undefined);
});

test('idFromHref', () => {
  assert.strictEqual(T.idFromHref('/@u/video/7300000000000000001?x=1'), '7300000000000000001');
  assert.strictEqual(T.idFromHref('/@u'), null);
});

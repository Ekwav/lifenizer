const test = require('node:test');
const assert = require('node:assert');
const H = require('../src/lib/headers.js');

// Monday 5 Oct 2026, local time.
const now = new Date(2026, 9, 5, 15, 0, 0);
const ymd = (d) => d && [d.getFullYear(), d.getMonth() + 1, d.getDate(), d.getHours()];

test('en: today, yesterday, weekday, month/day, with year', () => {
  assert.deepStrictEqual(ymd(H.resolveHeader('Today', 'en', now)), [2026, 10, 5, 12]);
  assert.deepStrictEqual(ymd(H.resolveHeader('Yesterday', 'en', now)), [2026, 10, 4, 12]);
  assert.deepStrictEqual(ymd(H.resolveHeader('Friday', 'en', now)), [2026, 10, 2, 12]);
  assert.deepStrictEqual(ymd(H.resolveHeader('Oct 3', 'en', now)), [2026, 10, 3, 12]);
  assert.deepStrictEqual(ymd(H.resolveHeader('Sep 12', 'en', now)), [2026, 9, 12, 12]);
  assert.deepStrictEqual(ymd(H.resolveHeader('Dec 25, 2025', 'en', now)), [2025, 12, 25, 12]);
});

test('de: heute, gestern, Wochentag, Datum', () => {
  assert.deepStrictEqual(ymd(H.resolveHeader('Heute', 'de', now)), [2026, 10, 5, 12]);
  assert.deepStrictEqual(ymd(H.resolveHeader('Gestern', 'de', now)), [2026, 10, 4, 12]);
  assert.deepStrictEqual(ymd(H.resolveHeader('Freitag', 'de', now)), [2026, 10, 2, 12]);
  assert.deepStrictEqual(ymd(H.resolveHeader('3. Okt.', 'de', now)), [2026, 10, 3, 12]);
  assert.deepStrictEqual(ymd(H.resolveHeader('12. September', 'de', now)), [2026, 9, 12, 12]);
});

test('normalization ignores case, punctuation and spacing', () => {
  assert.deepStrictEqual(ymd(H.resolveHeader('  TODAY ', 'en', now)), [2026, 10, 5, 12]);
  assert.deepStrictEqual(ymd(H.resolveHeader('3 okt', 'de', now)), [2026, 10, 3, 12]);
});

test('unknown header is null; weekday names do not resolve beyond a week', () => {
  assert.strictEqual(H.resolveHeader('Recently', 'en', now), null);
  assert.strictEqual(H.resolveHeader('', 'en', now), null);
});

test('assignDays inherits previous day for unknown headers and counts undated', () => {
  const entries = [{ header: 'Mystery', id: 'x' }, { header: 'Today', id: 'a' }, { header: 'Mystery', id: 'b' }, { header: 'Oct 3', id: 'c' }];
  const { dated, undated } = H.assignDays(entries, 'en', now);
  assert.strictEqual(undated, 1);
  assert.deepStrictEqual(dated.map((e) => [e.id, e.day.getDate()]), [['a', 5], ['b', 5], ['c', 3]]);
});

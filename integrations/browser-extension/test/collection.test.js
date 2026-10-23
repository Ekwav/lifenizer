const test = require('node:test');
const assert = require('node:assert');
const Y = require('../src/lib/youtube.js');
const H = require('../src/lib/headers.js');
const P = require('../src/lib/payload.js');
const F = require('./fixtures.js');

const now = new Date(2026, 9, 5, 15, 0, 0);

for (const lang of ['en', 'de']) {
  test(`youtube pipeline end to end (${lang})`, () => {
    const raw = Y.extract(F.initialData(lang)).entries
      .concat(Y.extract(F.continuation(lang === 'de' ? '3. Okt.' : 'Oct 3')).entries);
    const { dated, undated } = H.assignDays(raw, lang, now, 400);
    assert.strictEqual(undated, 0);
    const visits = dated.map((e) => P.makeVisit('youtube', { id: e.id, title: e.title, channel: e.channel, time: e.day, timePrecision: 'day' }));
    assert.deepStrictEqual(visits.map((v) => P.localDay(v.time)), ['2026-10-05', '2026-10-05', '2026-10-04', '2026-10-03']);
    assert.ok(visits.every((v) => v.timePrecision === 'day'));
  });
}

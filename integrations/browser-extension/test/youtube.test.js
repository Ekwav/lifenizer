const test = require('node:test');
const assert = require('node:assert');
const Y = require('../src/lib/youtube.js');
const F = require('./fixtures.js');

test('extracts videoRenderer, lockupViewModel and shorts with headers; skips playlists', () => {
  const { entries, continuation } = Y.extract(F.initialData('en'));
  assert.strictEqual(continuation, true);
  assert.deepStrictEqual(entries.map((e) => [e.header, e.id, e.title, e.channel, !!e.short]), [
    ['Today', 'aaaaaaaaaaa', 'Old shape', 'Chan A', false],
    ['Today', 'bbbbbbbbbbb', 'New shape', 'Chan B', false],
    ['Yesterday', 'ccccccccccc', 'A short', undefined, true],
  ]);
});

test('continuation response entries carry their section header', () => {
  const { entries, continuation } = Y.extract(F.continuation('Oct 3'));
  assert.strictEqual(continuation, false);
  assert.deepStrictEqual(entries.map((e) => [e.header, e.id]), [['Oct 3', 'ddddddddddd']]);
});

test('garbage input yields no entries', () => {
  assert.deepStrictEqual(Y.extract(null).entries, []);
  assert.deepStrictEqual(Y.extract({ a: [1, 'x', { videoRenderer: { videoId: 'short' } }] }).entries, []);
});

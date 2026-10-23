const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const A = require('../src/lib/accounts.js');
const channel = 'UC' + 'a'.repeat(22);

test('only logged-in self contexts identify accounts', () => {
  assert.equal(A.youtube({ loggedIn: false, channelId: channel }, '@owner'), null);
  assert.deepEqual(A.youtube({ loggedIn: true, channelId: channel }), { id: channel });
  assert.deepEqual(A.youtube({ loggedIn: true }, '@Owner'), { handle: '@owner' });
  assert.equal(A.tiktok({ user: { id: '123', uniqueId: 'owner' } }), null);
  assert.equal(A.tiktok({ isLogin: true, author: { id: '123', uniqueId: 'owner' } }), null);
  assert.deepEqual(A.tiktok({ isLogin: true, user: { uid: '123', uniqueId: 'owner' } }), { id: '123', handle: '@owner' });
});

test('expected ID or handle is mandatory and display names cannot match', () => {
  assert.equal(A.check('', { id: channel }).error, 'account-unconfigured');
  assert.equal(A.check(channel, null).error, 'account-unverified');
  assert.equal(A.check('Owner', { handle: '@owner' }).error, 'account-mismatch');
  assert.equal(A.check('@Other', { handle: '@owner' }).error, 'account-mismatch');
  assert.deepEqual(A.check('@OWNER', { handle: '@owner' }), { account: { handle: '@owner' } });
  assert.equal(A.check(channel.toUpperCase(), { id: channel }).error, 'account-mismatch');
  assert.equal(A.same({ id: '1', handle: '@a' }, { id: '2', handle: '@a' }), false);
});

async function collect(accounts, expectedAccount = channel) {
  let listener, requests = 0;
  const handlers = [];
  const context = {
    LF: {
      accounts: A,
      youtube: { pageLang: () => 'en', extract: () => ({ entries: [{ id: 'video' }] }) },
      headers: { assignDays: (raw) => ({ dated: raw, undated: 0 }) },
      payload: { makeVisit: (_, value) => value, applyMarker: (visits) => ({ fresh: visits, known: 0 }) },
    },
    location: { hostname: 'www.youtube.com', pathname: '/feed/history' },
    document: {},
    setTimeout: (callback) => { callback(); },
    chrome: { runtime: { onMessage: { addListener: (value) => { listener = value; } } } },
    Date,
  };
  context.window = {
    addEventListener: (_, callback) => handlers.push(callback),
    postMessage: (data) => {
      const account = accounts[Math.min(requests++, accounts.length - 1)];
      for (const handler of handlers) handler({ source: context.window, data: {
        __lifenizer: true, kind: 'initial', requestId: data.requestId,
        account, loggedIn: true, json: {}, lang: 'en',
      } });
    },
  };
  vm.runInNewContext(fs.readFileSync(require.resolve('../src/content/collector.js'), 'utf8'), context);
  return new Promise((resolve) => listener({ type: 'lifenizer-collect', opts: { expectedAccount, maxItems: 1, maxDays: 30 } }, {}, resolve));
}

test('collector rejects missing or wrong account before returning visits', async () => {
  assert.equal((await collect([{ id: channel }], '')).error, 'account-unconfigured');
  assert.equal((await collect([null])).error, 'account-unverified');
  const mismatch = await collect([{ id: 'UC' + 'b'.repeat(22) }]);
  assert.equal(mismatch.error, 'account-mismatch');
  assert.equal(mismatch.visits, undefined);
});

test('collector rechecks identity and discards visits after an account switch', async () => {
  const result = await collect([{ id: channel }, { id: 'UC' + 'b'.repeat(22) }]);
  assert.equal(result.error, 'account-mismatch');
  assert.equal(result.visits, undefined);
  const valid = await collect([{ id: channel }]);
  assert.equal(valid.account.id, channel);
  assert.equal(valid.visits.length, 1);
});

function initialFromHook(hostname, state = {}) {
  let emitted;
  function XHR() {}
  XHR.prototype.open = () => {};
  const context = {
    LF: { accounts: A },
    location: { hostname, pathname: '/feed/history' },
    document: { querySelector: () => null, getElementById: () => null, documentElement: { lang: 'en' } },
    navigator: { language: 'en' },
    XMLHttpRequest: XHR,
    ...state,
  };
  context.window = context;
  context.addEventListener = (_, callback) => { context.__handler = callback; };
  context.postMessage = (data) => { emitted = data; };
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(require.resolve('../src/content/hook.js'), 'utf8'), context);
  vm.runInContext("__handler({ source: window, data: { __lifenizer: 'request-initial', requestId: 7 } })", context);
  return emitted;
}

test('page hook reads only signed-in self config, not a viewed profile', () => {
  const config = { LOGGED_IN: true, CHANNEL_ID: channel };
  const youtube = initialFromHook('www.youtube.com', { ytcfg: { get: (key) => config[key] } });
  assert.equal(youtube.account.id, channel);
  assert.equal(youtube.requestId, 7);
  const state = { __DEFAULT_SCOPE__: {
    'webapp.user-detail': { userInfo: { user: { id: '999', uniqueId: 'stranger' } } },
  } };
  assert.equal(initialFromHook('www.tiktok.com', { __UNIVERSAL_DATA_FOR_REHYDRATION__: state }).account, null);
  state.__DEFAULT_SCOPE__['webapp.app-context'] = { isLogin: true, user: { uid: '123', uniqueId: 'owner' } };
  assert.equal(initialFromHook('www.tiktok.com', { __UNIVERSAL_DATA_FOR_REHYDRATION__: state }).account.handle, '@owner');
});

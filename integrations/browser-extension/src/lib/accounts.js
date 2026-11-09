// Account checks accept only explicit self-account context, never a video
// author, a viewed profile or a display name. Undocumented page shapes may
// change; missing self context deliberately blocks collection.
(function (root) {
  const text = (value) => typeof value === 'string' ? value.trim() : '';
  const handle = (value) => /^@[\p{L}\p{N}_.-]+$/u.test(text(value)) ? text(value).toLowerCase() : '';
  function youtube(config, activeHandle) {
    if (config.loggedIn !== true) return null;
    const id = /^UC[\w-]{22}$/.test(text(config.channelId)) ? config.channelId : '';
    const name = handle(activeHandle);
    return id || name ? { ...(id && { id }), ...(name && { handle: name }) } : null;
  }
  function tiktok(context) {
    // The app context's logged-in self user is distinct from UserModule and
    // webapp.user-detail, which describe profiles the user is viewing.
    if (!context || context.isLogin !== true || !context.user) return null;
    const user = context.user;
    const id = /^\d+$/.test(text(user.uid || user.id)) ? text(user.uid || user.id) : '';
    const name = handle('@' + text(user.uniqueId));
    return id || name ? { ...(id && { id }), ...(name && { handle: name }) } : null;
  }
  function check(expected, account) {
    expected = text(expected);
    if (!expected) return { error: 'account-unconfigured' };
    if (!account || (!account.id && !account.handle)) return { error: 'account-unverified' };
    const matches = expected.startsWith('@')
      ? handle(expected) && handle(expected) === account.handle
      : expected === account.id;
    return matches ? { account } : { error: 'account-mismatch', account };
  }
  function same(first, second) {
    if (!first || !second) return false;
    // If available, require the stable identity as well as the selected handle.
    return first.id === second.id && first.handle === second.handle;
  }
  const api = { youtube, tiktok, check, same };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else (root.LF = root.LF || {}).accounts = api;
})(globalThis);

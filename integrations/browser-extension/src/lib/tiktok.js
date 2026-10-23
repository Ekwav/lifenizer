// Pure module: maps JSON the tiktok.com web client loads for its watch-history
// view to visits. The exact response shape could not be verified without a
// logged-in session, so this is deliberately shape-tolerant: it walks the JSON
// and accepts any object that looks like a video item (numeric id plus
// description/author/video/stats), picking up a watch timestamp when present.
(function (root) {
  const ID_KEYS = ['aweme_id', 'itemId', 'item_id', 'video_id', 'videoId'];
  const TIME_KEYS = ['watchTime', 'watch_time', 'viewTime', 'view_time', 'browseTime', 'browse_time', 'visitTime', 'visit_time', 'historyTime', 'history_time', 'playTime', 'play_time', 'timestamp'];
  const SIGNAL_KEYS = ['desc', 'author', 'video', 'stats', 'statistics', 'music', 'createTime', 'create_time'];
  const isId = (v) => (typeof v === 'string' || typeof v === 'number') && /^\d{15,20}$/.test(String(v));

  function toIso(value) {
    if (value == null || value === '') return undefined;
    let ms;
    if (typeof value === 'number' || /^\d+(\.\d+)?$/.test(String(value))) {
      const n = Number(value);
      if (!(n > 1e9)) return undefined;
      ms = n < 1e11 ? n * 1000 : n;
    } else {
      ms = Date.parse(String(value));
    }
    if (!Number.isFinite(ms)) return undefined;
    const d = new Date(ms);
    return Number.isNaN(d.getTime()) ? undefined : d.toISOString();
  }

  function authorName(o) {
    const a = o.author;
    if (a && typeof a === 'object') return a.uniqueId || a.unique_id || a.nickname || undefined;
    if (typeof a === 'string') return a;
    return o.authorName || undefined;
  }

  function toItem(o) {
    let id;
    for (const k of ID_KEYS) if (isId(o[k])) { id = String(o[k]); break; }
    if (!id && isId(o.id) && SIGNAL_KEYS.some((k) => k in o)) id = String(o.id);
    if (!id) return null;
    let time;
    for (const k of TIME_KEYS) { time = toIso(o[k]); if (time) break; }
    return {
      id,
      url: `https://www.tiktokv.com/share/video/${id}/`,
      title: typeof o.desc === 'string' && o.desc.trim() ? o.desc.trim() : `TikTok video ${id}`,
      channel: authorName(o),
      time, // exact watch time if the response carries one
    };
  }

  /** @returns {{items: object[], hasMore: boolean|undefined, cursor: any}} */
  function mapResponse(json) {
    const items = [];
    const seen = new Set();
    function walk(node) {
      if (node == null || typeof node !== 'object') return;
      if (Array.isArray(node)) { node.forEach(walk); return; }
      const item = toItem(node);
      if (item) {
        if (!seen.has(item.id)) { seen.add(item.id); items.push(item); }
        return;
      }
      for (const k of Object.keys(node)) walk(node[k]);
    }
    walk(json);
    const hasMore = json && (json.hasMore ?? json.has_more);
    return { items, hasMore: hasMore === undefined ? undefined : !!hasMore, cursor: json && (json.cursor ?? json.next_cursor) };
  }

  /** DOM fallback helper: video id from an anchor href. */
  function idFromHref(href) {
    const m = /\/video\/(\d{15,20})/.exec(href || '');
    return m ? m[1] : null;
  }

  const api = { mapResponse, toIso, idFromHref, HISTORY_URL_RE: /(watch|view|browsing|browse)[_\-/]?history|history\/(list|item)/i };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else (root.LF = root.LF || {}).tiktok = api;
})(globalThis);

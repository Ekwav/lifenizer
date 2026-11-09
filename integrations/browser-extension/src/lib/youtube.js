// Pure module: extracts watch-history entries from YouTube InnerTube JSON
// (ytInitialData of /feed/history and youtubei/v1/browse continuation
// responses). Handles videoRenderer, lockupViewModel and Shorts shapes.
(function (root) {
  function text(node) {
    if (node == null) return '';
    if (typeof node === 'string') return node;
    if (typeof node.simpleText === 'string') return node.simpleText;
    if (typeof node.content === 'string') return node.content;
    if (Array.isArray(node.runs)) return node.runs.map((r) => r.text || '').join('');
    return '';
  }

  const ID_RE = /^[A-Za-z0-9_-]{6,20}$/;

  function headerText(section) {
    const h = section.header;
    if (!h) return '';
    const r = h.itemSectionHeaderRenderer || h.sectionHeaderViewModel || h.shelfHeaderRenderer || h;
    return text(r.title) || text(r.headline) || text(r.titleText) || text(r.sectionTitle) || '';
  }

  function videoRenderer(r) {
    if (!ID_RE.test(r.videoId || '')) return null;
    return {
      id: r.videoId,
      title: text(r.title),
      channel: text(r.ownerText) || text(r.longBylineText) || text(r.shortBylineText) || undefined,
    };
  }

  function lockup(r) {
    const type = r.contentType || '';
    if (type && !/VIDEO|SHORT|REEL/.test(type)) return null; // playlists, channels, ...
    if (!ID_RE.test(r.contentId || '')) return null;
    const meta = (r.metadata && r.metadata.lockupMetadataViewModel) || {};
    let channel;
    const rows = (meta.metadata && meta.metadata.contentMetadataViewModel && meta.metadata.contentMetadataViewModel.metadataRows) || [];
    for (const row of rows) {
      const part = (row.metadataParts || [])[0];
      const t = part && text(part.text);
      if (t) { channel = t; break; }
    }
    return { id: r.contentId, title: text(meta.title), channel };
  }

  function shorts(r) {
    // shortsLockupViewModel / reelItemRenderer
    const id = r.videoId
      || (r.onTap && r.onTap.innertubeCommand && r.onTap.innertubeCommand.reelWatchEndpoint && r.onTap.innertubeCommand.reelWatchEndpoint.videoId)
      || (r.inlinePlayerData && r.inlinePlayerData.onVisible && r.inlinePlayerData.onVisible.innertubeCommand && r.inlinePlayerData.onVisible.innertubeCommand.watchEndpoint && r.inlinePlayerData.onVisible.innertubeCommand.watchEndpoint.videoId);
    if (!ID_RE.test(id || '')) return null;
    const title = text(r.headline) || text(r.overlayMetadata && r.overlayMetadata.primaryText);
    return { id, title };
  }

  const LEAF = {
    videoRenderer,
    compactVideoRenderer: videoRenderer,
    lockupViewModel: lockup,
    shortsLockupViewModel: shorts,
    reelItemRenderer: shorts,
  };

  /**
   * @returns {{entries: {header:string,id:string,title:string,channel?:string,short?:boolean}[], continuation: boolean}}
   * entries in page order; `header` is the day header of the enclosing section.
   */
  function extract(data) {
    const entries = [];
    let continuation = false;
    const seen = new Set();
    function walk(node, header) {
      if (node == null || typeof node !== 'object') return;
      if (seen.has(node)) return;
      seen.add(node);
      if (Array.isArray(node)) { for (const n of node) walk(n, header); return; }
      if (node.continuationItemRenderer) continuation = true;
      if (node.itemSectionRenderer) {
        const sec = node.itemSectionRenderer;
        walk(sec.contents, headerText(sec) || header);
        return;
      }
      for (const key of Object.keys(node)) {
        const value = node[key];
        if (LEAF[key] && value && typeof value === 'object') {
          const v = LEAF[key](value);
          if (v) entries.push({ header, ...v, short: key === 'shortsLockupViewModel' || key === 'reelItemRenderer' });
        } else {
          walk(value, header);
        }
      }
    }
    walk(data, '');
    return { entries, continuation };
  }

  /** Page language from ytcfg / html lang, normalized for Intl. */
  function pageLang(raw) {
    return String(raw || 'en').replace('_', '-');
  }

  const api = { extract, pageLang, text };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else (root.LF = root.LF || {}).youtube = api;
})(globalThis);

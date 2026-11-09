// Pure module: visit normalization, dedupe keys, incremental markers, chunking
// and the payload/export builders for the Lifenizer loopback API and the
// Takeout / TikTok-export fallback files.
(function (root) {
  const MAX_CHUNK = 2000;

  function pad(n) { return String(n).padStart(2, '0'); }

  /** Local calendar day (YYYY-MM-DD) of an ISO time. */
  function localDay(iso) {
    const d = new Date(iso);
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }

  /** Dedupe key: one visit per video per day (day precision) or per second. */
  function visitKey(v) {
    // TikTok entries without a real watch time are deduped per video only: the
    // sync day is not a watch day and must not make old items look new.
    const when = v.timePrecision === 'exact'
      ? String(Math.floor(Date.parse(v.time) / 1000))
      : v.platform === 'tiktok' ? 'any' : localDay(v.time);
    return `${v.platform}:${v.id}@${when}`;
  }

  function watchUrl(id) { return `https://www.youtube.com/watch?v=${id}`; }

  /** Collected visit -> internal record. */
  function makeVisit(platform, { id, title, channel, time, timePrecision, url }) {
    const v = {
      platform,
      id,
      url: url || (platform === 'youtube' ? watchUrl(id) : `https://www.tiktokv.com/share/video/${id}/`),
      title: title || '',
      time: time instanceof Date ? time.toISOString() : time,
      timePrecision: timePrecision || 'day',
    };
    if (channel) v.channel = channel;
    return v;
  }

  // ---- incremental marker -------------------------------------------------
  const MARKER_SIZE = 200;

  /** Newest keys of the stored visits, newest first. */
  function makeMarker(visits) {
    const sorted = [...visits].sort((a, b) => Date.parse(b.time) - Date.parse(a.time));
    return { keys: sorted.slice(0, MARKER_SIZE).map(visitKey), newest: sorted[0] ? sorted[0].time : null };
  }

  /**
   * Decide what to keep from entries ordered newest first.
   * stops when the marker is reached (a known key) or the cutoff is passed.
   * @returns {{fresh: object[], stop: boolean, known: number, tooOld: number}}
   */
  function applyMarker(visits, marker, cutoffMs) {
    const known = new Set(marker && marker.keys || []);
    const fresh = [];
    let stop = false, knownCount = 0, tooOld = 0;
    for (const v of visits) {
      if (cutoffMs != null && Date.parse(v.time) < cutoffMs) { tooOld++; stop = true; continue; }
      if (known.has(visitKey(v))) { knownCount++; stop = true; continue; }
      fresh.push(v);
    }
    return { fresh, stop, known: knownCount, tooOld };
  }

  function chunk(list, size) {
    const n = Math.min(size || MAX_CHUNK, MAX_CHUNK);
    const out = [];
    for (let i = 0; i < list.length; i += n) out.push(list.slice(i, i + n));
    return out;
  }

  // ---- loopback payload ---------------------------------------------------
  function buildPayload(visits) {
    return {
      source: 'lifenizer-extension',
      version: 1,
      visits: visits.map((v) => {
        const o = { url: v.url, title: v.title, time: v.time, timePrecision: v.timePrecision };
        if (v.channel) o.channel = v.channel;
        return o;
      }),
    };
  }

  function buildPayloads(visits, size) {
    return chunk(visits, size).map(buildPayload);
  }

  // ---- fallback exports ---------------------------------------------------
  function buildTakeoutYoutube(visits) {
    return visits.filter((v) => v.platform === 'youtube').map((v) => {
      const o = { header: 'YouTube', title: `Watched ${v.title || v.id}`, titleUrl: v.url };
      if (v.channel) o.subtitles = [{ name: v.channel }];
      o.time = v.time;
      return o;
    });
  }

  function tiktokDate(iso) {
    const d = new Date(iso);
    return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`;
  }

  function buildTiktokExport(visits) {
    return {
      Activity: {
        'Video Browsing History': {
          VideoList: visits.filter((v) => v.platform === 'tiktok').map((v) => ({
            Date: tiktokDate(v.time),
            Link: `https://www.tiktokv.com/share/video/${v.id}/`,
          })),
        },
      },
    };
  }

  const api = { MAX_CHUNK, localDay, visitKey, makeVisit, makeMarker, applyMarker, chunk, buildPayload, buildPayloads, buildTakeoutYoutube, buildTiktokExport, tiktokDate };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else (root.LF = root.LF || {}).payload = api;
})(globalThis);

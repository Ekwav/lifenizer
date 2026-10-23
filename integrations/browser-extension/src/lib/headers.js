// Pure module: resolves the day-level section headers of the YouTube history
// page ("Today", "Heute", "Fri", "Oct 3", "3. Okt.") to a calendar day,
// independent of the page language, by generating candidate labels for the last
// N days with Intl and matching the normalized header text against them.
(function (root) {
  function normalize(text) {
    return String(text || '')
      .normalize('NFKC')
      .toLowerCase()
      .replace(/[\p{P}\p{S}]/gu, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  function localNoon(year, month, day) {
    return new Date(year, month, day, 12, 0, 0, 0);
  }

  function pad(n) {
    return String(n).padStart(2, '0');
  }

  function dayKey(date) {
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  }

  function safe(fn) {
    try { return fn(); } catch (e) { return null; }
  }

  const fmtCache = new Map();
  function dtf(lang, opts) {
    const k = lang + JSON.stringify(opts);
    if (!fmtCache.has(k)) fmtCache.set(k, safe(() => new Intl.DateTimeFormat(lang, opts)));
    return fmtCache.get(k);
  }
  const fmt = (lang, opts, date) => { const f = dtf(lang, opts); return f ? f.format(date) : null; };

  const rtfCache = new Map();
  function rtfFor(lang) {
    if (!rtfCache.has(lang)) rtfCache.set(lang, safe(() => new Intl.RelativeTimeFormat(lang, { numeric: 'auto' })));
    return rtfCache.get(lang);
  }

  /** Candidate normalized labels for one day, in priority order. */
  function labelsFor(date, daysAgo, lang) {
    const labels = [];
    const add = (s) => { if (s) labels.push(normalize(s)); };
    if (daysAgo <= 1) {
      const rtf = rtfFor(lang);
      if (rtf) add(rtf.format(-daysAgo, 'day'));
    }
    if (daysAgo <= 6) {
      add(fmt(lang, { weekday: 'long' }, date));
      add(fmt(lang, { weekday: 'short' }, date));
    }
    const formats = [
      { month: 'short', day: 'numeric' },
      { month: 'long', day: 'numeric' },
      { month: 'short', day: 'numeric', year: 'numeric' },
      { month: 'long', day: 'numeric', year: 'numeric' },
      { weekday: 'long', month: 'long', day: 'numeric' },
      { weekday: 'short', month: 'short', day: 'numeric' },
      { dateStyle: 'medium' },
      { dateStyle: 'long' },
    ];
    for (const f of formats) add(fmt(lang, f, date));
    return labels;
  }

  const tableCache = new Map();

  function buildTable(lang, now, maxDays) {
    const key = `${lang}|${dayKey(now)}|${maxDays}`;
    if (tableCache.has(key)) return tableCache.get(key);
    const table = new Map(); // normalized label -> Date (closest day wins)
    for (let i = 0; i <= maxDays; i++) {
      const d = localNoon(now.getFullYear(), now.getMonth(), now.getDate() - i);
      for (const label of labelsFor(d, i, lang)) {
        if (label && !table.has(label)) table.set(label, d);
      }
    }
    tableCache.set(key, table);
    return table;
  }

  /**
   * @returns {Date|null} local noon of the resolved day, or null when the
   * header is not recognized.
   */
  function resolveHeader(text, lang, now, maxDays) {
    const norm = normalize(text);
    if (!norm) return null;
    const table = buildTable(lang || 'en', now || new Date(), maxDays || 400);
    return table.get(norm) || null;
  }

  /**
   * Walks entries in page order ({header, ...}) and assigns each a day.
   * Unresolved headers inherit the previous resolved day; entries before any
   * resolved day are returned as undated.
   */
  function assignDays(entries, lang, now, maxDays) {
    const dated = [];
    let undated = 0;
    let current = null;
    let lastHeader = Symbol('none');
    for (const e of entries) {
      if (e.header !== lastHeader) {
        lastHeader = e.header;
        const resolved = resolveHeader(e.header, lang, now, maxDays);
        if (resolved) current = resolved;
      }
      if (!current) { undated++; continue; }
      dated.push({ ...e, day: current });
    }
    return { dated, undated };
  }

  const api = { normalize, resolveHeader, assignDays, dayKey, localNoon };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else (root.LF = root.LF || {}).headers = api;
})(globalThis);

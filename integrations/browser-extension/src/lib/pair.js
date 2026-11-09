(function(root) {
  const validCode = code => typeof code === 'string' && /^[A-Za-z0-9_-]{43}$/.test(code);
  function parse(value) {
    try {
      const u = new URL(value);
      if (u.protocol !== 'http:' || u.hostname !== '127.0.0.1' || !u.port || u.username || u.password || u.pathname !== '/v1/pair' || u.search || !/^#code=[A-Za-z0-9_-]{43}$/.test(u.hash)) return null;
      // Reject normalized spellings such as decimal IPs, encoded paths and credentials.
      const port = Number(u.port), code = u.hash.slice(6);
      return port > 0 && port <= 65535 && value === `http://127.0.0.1:${port}/v1/pair#code=${code}` ? {port, code} : null;
    } catch (_) { return null; }
  }
  function siteSender(sender, id) {
    try { const u = new URL(sender.url); return sender.id === id && !!sender.tab && sender.frameId === 0 && u.origin === 'https://lifenizer.coflnet.com' && !u.username && !u.password; } catch (_) { return false; }
  }
  async function exchange(pair, request) {
    const response = await request(`http://127.0.0.1:${pair.port}/v1/pair`, {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({code:pair.code}), signal:AbortSignal.timeout(4000), redirect:'error'});
    if (!response.ok) { const error = new Error([400,401,403,404,409,410].includes(response.status) ? 'expired' : 'waiting'); throw error; }
    const data = await response.json();
    if (data.app !== 'lifenizer' || data.version !== 1 || data.port !== pair.port || typeof data.token !== 'string' || !data.token || data.token.length > 4096) throw Error('invalid-response');
    return {port:pair.port, token:data.token};
  }
  const api = {parse, validCode, siteSender, exchange};
  if (typeof module === 'object' && module.exports) module.exports = api;
  else (root.LF = root.LF || {}).pair = api;
})(globalThis);

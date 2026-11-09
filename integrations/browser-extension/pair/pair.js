const ext = globalThis.browser || globalThis.chrome;
const $ = id => document.getElementById(id);
const P = globalThis.LF.pair;
let stream, timer, deadline, generation = 0, staged;
const say = text => { $('status').textContent = text; };
function stop() {
  generation++;
  clearTimeout(timer); clearTimeout(deadline);
  stream?.getTracks().forEach(track => track.stop()); stream = null;
  $('preview').pause(); $('preview').srcObject = null; $('preview').hidden = true;
}
async function permission() {
  try {
    const host = {origins:['http://127.0.0.1/*']};
    if (!await ext.permissions.contains(host) && !await ext.permissions.request(host)) {
      say('Local app access was denied. Choose Connect again and allow access to 127.0.0.1 to retry.'); return false;
    }
  } catch (_) { say('Local app permission could not be requested. Reopen this extension page and retry Connect.'); return false; }
  let access;
  try { access = await navigator.permissions?.query({name:'loopback-network'}); } catch (_) { /* older browsers do not expose this permission */ }
  if (access?.state === 'denied') {
    say('Your browser blocked access to device apps and services. Allow access in this page’s browser permissions, then choose Connect again.'); return false;
  }
  return true;
}
async function consent() {
  const {settings = {}, visits = [], messages = []} = await ext.storage.local.get(['settings','visits','messages']);
  if ((settings.token || visits.some(v => !v.sent) || messages.some(m => !m.sent)) && !confirm('Replace the browser connection? Any queued imports, including private messages, may be delivered to the vault you unlock in Lifenizer. Continue only if this is the intended vault.')) return false;
  return true;
}
async function connect(pair) {
  stop(); staged = null; $('accept').hidden = true;
  const run = generation, until = Date.now() + 120000;
  const attempt = async () => {
    if (run !== generation) return;
    try {
      say('Waiting for Lifenizer. Unlock the intended vault and approve the connection in Lifenizer if asked. If your browser asks to access device apps and services, choose Allow.');
      const connection = await P.exchange(pair, fetch);
      if (run !== generation) return;
      const saved = await ext.runtime.sendMessage({type:'lifenizer-pair-save',connection});
      if (!saved?.ok) throw Error(saved?.error || 'save-failed');
      stop(); say('Connected. Your browser is ready. Choose accounts or enable message capture in Settings.');
    } catch (error) {
      if (run !== generation) return;
      if (['expired','invalid-response','sync-running','save-failed'].includes(error.message) || Date.now() >= until) {
        stop(); say(error.message === 'sync-running' ? 'Sync is running. Wait for it to finish, then create a new pairing code and retry.' : 'Pairing ended or the code expired. Create a new QR code in Lifenizer, or choose Open Lifenizer and connect again.'); return;
      }
      say('Waiting for Lifenizer. Unlock the intended vault, approve the connection in Lifenizer if asked, and enable the browser receiver. Allow any browser prompt for device apps and services. If blocked, allow access in this page’s browser permissions and retry. Cancel to stop.');
      timer = setTimeout(attempt, 1000);
    }
  };
  await attempt();
}
function stage(value) {
  const pair = P.parse(value);
  if (!pair) { say('This is not a Lifenizer pairing QR. Display a fresh QR from the desktop app and retry.'); return false; }
  stop(); staged = pair; $('port').value = pair.port; $('accept').hidden = false;
  say('Pairing code ready. Unlock the intended vault, then confirm Connect using scanned code.'); return true;
}
$('accept').onclick = async () => {
  const pair = staged, run = generation;
  if (pair && await permission() && run === generation && await consent() && run === generation) connect(pair);
};
$('open').onclick = async () => {
  const run = generation;
  if (!$('port').reportValidity() || !await permission() || run !== generation || !await consent() || run !== generation) return;
  stop();
  const code = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
  const port = Number($('port').value);
  // Navigation occurs synchronously within the explicit click, after consent.
  const link = document.createElement('a'); link.href = `lifenizer://connect-extension?code=${code}&port=${port}`; link.click();
  connect({port,code});
};
function decode(source, width, height) {
  const scale = Math.min(1, 1600 / Math.max(width,height));
  const canvas = document.createElement('canvas'); canvas.width = Math.round(width*scale); canvas.height = Math.round(height*scale);
  if (!canvas.width || !canvas.height) return false;
  const context = canvas.getContext('2d', {willReadFrequently:true}); context.drawImage(source,0,0,canvas.width,canvas.height);
  const pixels = context.getImageData(0,0,canvas.width,canvas.height);
  const result = jsQR(pixels.data,pixels.width,pixels.height);
  return result ? stage(result.data) : false;
}
async function scan(camera) {
  stop(); const run = generation;
  try {
    const media = camera ? await navigator.mediaDevices.getUserMedia({video:{width:{ideal:1280},height:{ideal:720}},audio:false}) : await navigator.mediaDevices.getDisplayMedia({video:{width:{ideal:1600},height:{ideal:1000},frameRate:{max:5}},audio:false});
    if (run !== generation) { media.getTracks().forEach(t => t.stop()); return; }
    stream = media;
    media.getTracks().forEach(t => t.addEventListener('ended', () => { if (stream === media) { stop(); say('Capture ended. Choose a scan method to try again.'); } }));
    const video = $('preview'); video.srcObject = media; video.hidden = false; await video.play();
    if (run !== generation) return;
    say('Looking for a Lifenizer QR. Cancel to stop.');
    deadline = setTimeout(() => { stop(); say('No pairing QR found within one minute. Enlarge the QR or choose a QR image and try again.'); },60000);
    const frame = () => { if (run !== generation) return; if (!decode(video,video.videoWidth,video.videoHeight)) timer = setTimeout(frame,250); };
    frame();
  } catch (_) { if (run === generation) { stop(); say('Capture unavailable or cancelled. Try a QR image, another scan method, or Open Lifenizer and connect.'); } }
}
$('screen').onclick = () => scan(false); $('camera').onclick = () => scan(true);
$('image').onchange = async () => {
  stop(); const run = generation, file = $('image').files[0]; $('image').value = '';
  if (!file) return;
  if (file.size > 10*1024*1024) { say('Choose a QR image smaller than 10 MB.'); return; }
  let bitmap;
  try {
    bitmap = await createImageBitmap(file, {resizeWidth:1600,resizeQuality:'high'});
    if (run === generation && !decode(bitmap,bitmap.width,bitmap.height)) say('No Lifenizer QR found. Enlarge the QR or choose another image.');
  } catch (_) { if (run === generation) say('Image could not be read. Choose a PNG or JPEG containing the QR.'); }
  finally { bitmap?.close(); }
};
$('cancel').onclick = () => { stop(); staged = null; $('accept').hidden = true; say('Cancelled. Choose a connection method to retry.'); };
window.addEventListener('pagehide', stop);
try { if (location.hash) stage(decodeURIComponent(location.hash.slice(1))); } catch (_) { say('Invalid pairing link. Create a new pairing QR and retry.'); }
history.replaceState(null,'',location.pathname);
ext.storage.local.get('settings').then(({settings}) => { if (!staged && settings?.port) $('port').value = settings.port; });

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const P = require('../src/lib/pair');
const code = 'A'.repeat(43);
const link = `http://127.0.0.1:47615/v1/pair#code=${code}`;
test('QR parser accepts only exact local helper links and valid nonce/port', () => {
  assert.deepEqual(P.parse(link),{port:47615,code});
  for (const value of [link.replace('127.0.0.1','localhost'),link.replace('127.0.0.1','2130706433'),link.replace('http:','https:'),link.replace('/v1/pair','/v1/%70air'),link.replace(':47615',':0'),link.replace(':47615',':65536'),link.replace('127.0.0.1','a@127.0.0.1'),link.replace('#','?next=evil#'),link+'&x=1',link.slice(0,-1),'https://evil.test/#'+code]) assert.equal(P.parse(value),null,value);
});
test('site sender is restricted to own runtime, exact HTTPS origin and top frame', () => {
  const sender = {id:'mine',tab:{id:1},frameId:0,url:'https://lifenizer.coflnet.com/'};
  assert.equal(P.siteSender(sender,'mine'),true);
  for (const patch of [{id:'evil'},{frameId:1},{tab:null},{url:'http://lifenizer.coflnet.com/'},{url:'https://lifenizer.coflnet.com.evil.test/'},{url:'https://lifenizer.coflnet.com:444/'}]) assert.equal(P.siteSender({...sender,...patch},'mine'),false);
});
test('exchange is bounded, rejects redirects and validates app/version/port/token', async () => {
  let request;
  const result = await P.exchange({port:47615,code}, async (url,opts) => {request={url,opts};return {ok:true,json:async()=>({app:'lifenizer',version:1,port:47615,token:'secret'})};});
  assert.deepEqual(result,{port:47615,token:'secret'});
  assert.equal(request.url,'http://127.0.0.1:47615/v1/pair');assert.equal(request.opts.redirect,'error');assert.equal(request.opts.body,JSON.stringify({code})); assert.ok(request.opts.signal);
  await assert.rejects(P.exchange({port:47615,code},async()=>({ok:false,status:410})),/expired/);
  await assert.rejects(P.exchange({port:47615,code},async()=>({ok:true,json:async()=>({app:'evil',token:'secret'})})),/invalid-response/);
});
function ui() {
  const elements = Object.fromEntries(['status','preview','accept','port','open','screen','camera','image','cancel'].map(id=>[id,{value:id==='port'?'47615':'',hidden:false,reportValidity:()=>true,pause(){},play:async()=>{}}]));
  const writes=[],links=[],timers=new Map();let stopped=0,next=0;
  const stream={getTracks:()=>[{stop:()=>stopped++,addEventListener(){}}]};
  const settings={port:47615,token:'old',youtubeAccount:'@mine',discordEnabled:false,debugEnabled:false};
  const context={LF:{pair:P},document:{getElementById:id=>elements[id],createElement:()=>({click(){links.push(this.href);}})},window:{addEventListener(){}},location:{hash:'#'+encodeURIComponent(link),pathname:'/pair/pair.html'},history:{replaceState(){}},confirm:()=>true,
    navigator:{mediaDevices:{getUserMedia:async()=>stream}},crypto:require('node:crypto').webcrypto,btoa,Uint8Array,Date,URL,AbortSignal,
    setTimeout:(fn)=>{timers.set(++next,fn);return next;},clearTimeout:id=>timers.delete(id),
    fetch:async()=>({ok:true,json:async()=>({app:'lifenizer',version:1,port:47615,token:'new'})}),
    chrome:{storage:{local:{get:async()=>({settings,visits:[{sent:false}]})}},runtime:{sendMessage:async m=>{writes.push(m);return {ok:true};}}}};
  vm.runInNewContext(fs.readFileSync(require.resolve('../pair/pair.js'),'utf8'),context);
  return {elements,context,writes,links,timers,get stopped(){return stopped;}};
}
test('staged helper never pairs before consent; cancellation clears staging',async()=>{
  const page=ui(); assert.equal(page.writes.length,0);
  page.context.confirm=()=>false;await page.elements.accept.onclick();assert.equal(page.writes.length,0);
  page.context.confirm=()=>true;await page.elements.accept.onclick();await new Promise(setImmediate);
  assert.equal(page.writes[0].connection.token,'new');
  const cancelled=ui();cancelled.elements.cancel.onclick();await cancelled.elements.accept.onclick();assert.equal(cancelled.writes.length,0);
});
test('cancel during permission prompt stops late tracks without starting scan timers',async()=>{
  const page=ui();let resolve;page.context.navigator.mediaDevices.getUserMedia=()=>new Promise(r=>resolve=r);
  const scan=page.elements.camera.onclick();page.elements.cancel.onclick();
  let stopped=0;resolve({getTracks:()=>[{stop:()=>stopped++}]});await scan;
  assert.equal(stopped,1);assert.equal(page.timers.size,0);assert.equal(page.elements.preview.srcObject,null);
});
test('bundled decoder works without BarcodeDetector and is packaged for both browsers',()=>{
  const decoder = require('../vendor/jsQR');
  const rows = require('./pair-qr.json'), size = rows.length * 4, pixels = new Uint8ClampedArray(size * size * 4);
  for(let y=0;y<size;y++) for(let x=0;x<size;x++) {const i=(y*size+x)*4, value=rows[Math.floor(y/4)][Math.floor(x/4)]==='B'?255:0; pixels[i]=pixels[i+1]=pixels[i+2]=value; pixels[i+3]=255;}
  assert.equal(decoder(pixels,size,size).data,link);
  const build=fs.readFileSync(require.resolve('../scripts/build'),'utf8');assert.match(build,/'pair', 'vendor'/);
});

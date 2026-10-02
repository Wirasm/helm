import http from 'node:http';
import { writeFileSync } from 'node:fs';

const ready = process.argv[2];
if (!ready) throw new Error('usage: node Tests/BrowserFixtures/oopif.mjs <ready-file>');

const controls = `
  <select id=select><option value=same>First</option><option disabled>Disabled</option>
    <option value=same>Second</option></select>
  <input id=date type=date value=2026-10-02 min=2026-10-02 max=2026-10-12 step=2>
  <script>
    window.events=[]; window.gestures=[]; window.cancelGesture=false; window.barriers=0;
    for (const kind of ['input','change']) document.addEventListener(kind,e=>events.push(e.target.id+':'+e.type));
    for (const kind of ['mousedown','click']) document.addEventListener(kind,e=>{
      gestures.push(e.type); if (cancelGesture) e.preventDefault();
    });
    document.addEventListener('keyup',e=>{if(e.key==='F8') barriers++});
    window.replaceSelect=()=>{const old=document.querySelector('#select'); old.replaceWith(old.cloneNode(true));};
  </script>`;
const base = `<meta charset=utf-8><style>
  html,body{margin:0;min-height:1100px;scrollbar-width:none} iframe{display:block}
  select,input{display:block;width:180px;height:32px;margin-left:32px}
  select{margin-top:25px} input{margin-top:18px}
</style>`;

const server = http.createServer((req,res)=>{
  const request = new URL(req.url, 'http://localhost');
  const token = request.searchParams.get('run') || '';
  const port = server.address().port;
  const leaf = `http://localhost:${port}/leaf?run=${token}`;
  const middle = `http://127.0.0.1:${port}/middle?run=${token}`;
  let body;
  switch(request.pathname) {
    case '/middle': body = `${controls}<div style="height:55px"></div>
      <iframe id=inner src="${leaf}" style="margin-left:67px;width:390px;height:230px;
        border:9px solid blue;transform:scale(.9);transform-origin:0 0"></iframe>
      <script>scrollTo(0,55)</script>`; break;
    case '/leaf': body = `<div style="height:65px"></div>${controls}<script>scrollTo(0,35)</script>`; break;
    default: body = `${controls}<div style="height:45px"></div>
      <iframe id=outer src="${middle}" style="margin-left:61px;width:700px;height:430px;
        border:11px solid red;transform:scale(.8);transform-origin:0 0"></iframe>
      <script>scrollTo(0,45)</script>`;
  }
  res.writeHead(200, {'Content-Type':'text/html; charset=utf-8', 'Cache-Control':'no-store'});
  res.end(base + body);
});
server.listen(0,'::',()=>writeFileSync(ready, `http://localhost:${server.address().port}/main`));
// The server expires independently even if the owning harness is killed.
setTimeout(()=>server.close(()=>process.exit()),1_100_000).unref();
for(const signal of ['SIGTERM','SIGINT']) process.on(signal,()=>server.close(()=>process.exit()));

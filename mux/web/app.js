const E=(s)=>document.getElementById(s)
const esc=s=>(""+s).replace(/[&<>]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]))
function openPlan(file){E("planframe").src='/plan?file='+encodeURIComponent(file);document.body.classList.add("drawer-open")}
function closePlan(){document.body.classList.remove("drawer-open");E("planframe").src="about:blank"}
document.addEventListener("keydown",e=>{if(e.key=="Escape")closePlan()})
// Working indicator: server says executing/elapsed (polled in refresh); the
// counter is driven client-side from a start time so it ticks every second
// without hammering the server. work.start=null means no cycle in flight.
let work={start:null,known:false}
function drawWork(){const w=E("working");if(!w)return
 if(work.start===null){w.innerHTML="";return}
 const secs=work.known?Math.max(0,Math.floor((Date.now()-work.start)/1000)):null
 w.innerHTML='<span class=glyph>✳</span><span class=shimmer>Working…'+(secs===null?"":" "+secs+"s")+'</span>'}
async function pollStatus(){try{const s=await (await fetch("/api/status")).json()
  if(!s.executing){work.start=null;work.known=false}
  else{const base=Date.now()-(s.elapsed||0)*1000
   // Re-sync start only on a new cycle or first sight, so the local counter
   // stays smooth instead of jumping each poll.
   if(work.start===null||Math.abs(base-work.start)>3000)work.start=base
   work.known=s.elapsed!=null}}
 catch(e){}
 drawWork()}
// Conway's Game of Life brand mark in the header. Toroidal so it never settles
// into a static board; reseeds if it empties or stalls. Always visible as a
// logo: it animates while a task is executing and freezes on its last frame
// (golStop clears the interval but never hides the canvas) when idle.
const GOL={cols:10,rows:10,timer:null,grid:null,prev:null,still:0}
function golSeed(){const n=GOL.cols*GOL.rows,g=new Uint8Array(n)
 // Real random initial conditions (~40% density) so every reseed is different —
 // a genuine Conway run, not a fixed loop replaying the same board.
 for(let i=0;i<n;i++)g[i]=Math.random()<.4?1:0
 GOL.grid=g;GOL.prev=null;GOL.still=0}
// One toroidal Conway step over a flat Uint8Array; shared by the header brand
// mark and the Output-log cycle marker so the Conway rule lives in one place.
function conwayNext(grid,cols,rows){const n=cols*rows,nx=new Uint8Array(n)
 for(let y=0;y<rows;y++)for(let x=0;x<cols;x++){let c=0
  for(let dy=-1;dy<=1;dy++)for(let dx=-1;dx<=1;dx++){if(!dx&&!dy)continue
   const yy=(y+dy+rows)%rows,xx=(x+dx+cols)%cols;c+=grid[yy*cols+xx]}
  const i=y*cols+x;nx[i]=grid[i]?(c==2||c==3?1:0):(c==3?1:0)}
 return nx}
function golStep(){const {cols,rows,grid}=GOL,n=cols*rows,nx=conwayNext(grid,cols,rows)
 // reseed if empty or unchanged (stable/oscillator-stuck) for a couple of steps
 let alive=0,same=GOL.prev!=null;for(let i=0;i<n;i++){alive+=nx[i];if(GOL.prev&&nx[i]!=GOL.prev[i])same=false}
 GOL.prev=grid;GOL.grid=nx
 if(!alive){golSeed();return}
 if(same){GOL.still++;if(GOL.still>1)golSeed()}else GOL.still=0}
function golDraw(){const cv=E("gol");if(!cv)return;const ctx=cv.getContext("2d")
 const {cols,rows,grid}=GOL;ctx.clearRect(0,0,cols,rows)
 ctx.fillStyle=getComputedStyle(document.documentElement).getPropertyValue("--mux-gol-fill").trim()||"#aeb4bf"
 for(let i=0;i<cols*rows;i++)if(grid[i])ctx.fillRect(i%cols,(i/cols)|0,1,1)}
function golStart(){if(GOL.timer)return
 if(!GOL.grid)golSeed()
 golDraw();GOL.timer=setInterval(()=>{golStep();golDraw()},130)}
// Freeze the mark on its current frame when idle — clears the interval but keeps
// the canvas visible so it reads as a static logo (never hidden).
function golStop(){if(GOL.timer){clearInterval(GOL.timer);GOL.timer=null}}
// Output-log cycle marker: the NEWEST cycle divider is rendered as a larger
// canvas GOL board that plays a live ~2.5s Conway run once when the cycle first
// appears, then freezes on its final frame. Its own seed (independent of the
// server text grid) so it doesn't couple to gol-busier-seed. Older dividers in
// the scrollback stay as the server's static text grid (frozen final frame).
const MARK={cols:36,rows:12,grid:null,timer:null,step:0},MARK_STEPS=20
// lastCycleCount=null until the first refresh has seen the log; that first sight
// freezes (never animates) any pre-existing newest divider so a page reload
// doesn't replay history. A later strict increase = a brand-new cycle → animate.
let lastCycleCount=null
function markSeed(){const n=MARK.cols*MARK.rows,g=new Uint8Array(n)
 for(let i=0;i<n;i++)g[i]=Math.random()<.4?1:0;MARK.grid=g}
function markDraw(){const cv=E("golmark");if(!cv||!MARK.grid)return
 const ctx=cv.getContext("2d");ctx.clearRect(0,0,MARK.cols,MARK.rows)
 ctx.fillStyle=getComputedStyle(document.documentElement).getPropertyValue("--mux-gol-fill").trim()||"#aeb4bf"
 for(let i=0;i<MARK.cols*MARK.rows;i++)if(MARK.grid[i])ctx.fillRect(i%MARK.cols,(i/MARK.cols)|0,1,1)}
// Run the one-shot animation: reseed, step every 130ms for ~2.5s, then freeze.
function markAnimate(){if(MARK.timer){clearInterval(MARK.timer);MARK.timer=null}
 markSeed();MARK.step=0;markDraw()
 MARK.timer=setInterval(()=>{MARK.grid=conwayNext(MARK.grid,MARK.cols,MARK.rows);markDraw()
  if(++MARK.step>=MARK_STEPS){clearInterval(MARK.timer);MARK.timer=null}},130)}
// Paint the newest marker's current frame onto the (re-rendered) canvas without
// restarting anything — used on every poll so the freshly rebuilt #log canvas
// shows the frozen/in-progress frame instead of flashing blank. Seeds+settles a
// frame on first sight so a reloaded historical marker isn't empty.
function markFreeze(){if(!MARK.grid){markSeed();for(let i=0;i<MARK_STEPS;i++)MARK.grid=conwayNext(MARK.grid,MARK.cols,MARK.rows)}
 markDraw()}
async function act(verb,id,prompt){let text=""
 if(prompt){text=window.prompt(prompt);if(text===null)return}
 try{const r=await fetch("/api/verb",{method:"POST",headers:{"content-type":"application/json"},
   body:JSON.stringify({verb,id,text})})
  const d=await r.json()
  if(!d.ok)alert("mux "+verb+" failed:\n"+(d.out||("HTTP "+r.status)))}
 catch(e){alert("request failed: "+e)}
 refresh()}
function channel(){fetch("/api/channel",{method:"POST",headers:{"content-type":"application/json"},body:"{}"})
 .catch(e=>alert("channel failed: "+e))}
// Open a Terminal continuing a stuck task's exact claude session (human-driven).
function resume(id){fetch("/api/resume",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({id})})
 .then(r=>r.json()).then(d=>{if(!d.ok)alert("resume failed:\n"+(d.out||""))}).catch(e=>alert("resume failed: "+e))}
// Open a Terminal running a FRESH claude seeded to complete a DRAFT task by hand
// (human-driven). Runs outside the headless board — the task stays DRAFT.
function direct(file){fetch("/api/direct",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({file})})
 .then(r=>r.json()).then(d=>{if(!d.ok)alert("direct failed:\n"+(d.out||""))}).catch(e=>alert("direct failed: "+e))}
// Auto mode (persisted server-side). When ON the toggle does the Release/Approve
// gates' job, so those per-task buttons are hidden; revert/answer escape hatches stay.
let auto=false
function drawAuto(){const b=E("autobtn");if(!b)return
 b.textContent="Auto mode: "+(auto?"on":"off");b.classList.toggle("on",auto)}
async function toggleAuto(){try{const r=await fetch("/api/auto",{method:"POST",
   headers:{"content-type":"application/json"},body:JSON.stringify({enabled:!auto})})
  auto=(await r.json()).enabled}catch(e){alert("auto toggle failed: "+e)}
 drawAuto();refresh()}
function buttons(t){const b=[],f=t.file
 if(t.status=="DRAFT"&&!auto){b.push(`<button class=primary onclick="act('release','${f}')">Release</button>`)
  // Open a channel-scoped planner session on a DRAFT to refine it by hand,
  // without releasing it to the headless tick — the task stays DRAFT on the board.
  b.push(`<button onclick="direct('${f}')">plan ⇥</button>`)
  // A DRAFT never ran — nothing to discard — so it can be deleted outright.
  b.push(`<button class=danger onclick="if(confirm('Delete this draft task?'))act('delete','${f}')">delete</button>`)}
 // A READY task hasn't been claimed yet, so you can still regret it: pull it
 // back to DRAFT (un-release) to edit it before the output runs it.
 if(t.status=="READY"&&!auto)b.push(`<button onclick="act('unrelease','${f}')">← unrelease</button>`)
 if(t.status=="RUNNING"){
  if(t.executing)return ""
  if(!auto)b.push(`<button class=ok onclick="act('ok')">Approve</button>`)
  b.push(`<button class=danger onclick="if(confirm('Discard this task\'s changes?'))act('revert')">revert</button>`)}
 if(t.status=="BLOCKED")b.push(`<button onclick="act('resolve','${f}','your answer')">answer</button>`)
 // FAILED is terminal & already discarded — the only way forward is to clear it
 // off the board. (If it kept a session, the resume button below also appears.)
 if(t.status=="FAILED")b.push(`<button class=danger onclick="if(confirm('Delete this failed task?'))act('delete','${f}')">delete</button>`)
 // Resume/direct the recorded session — but NEVER while a tick is live
 // (t.executing): a second claude would collide with the headless tick.
 // STUCK (BLOCKED, RUNNING killed mid-tick, or FAILED) → "resume ⇥" to
 // re-open the chat and keep fixing it; a healthy RUNNING task awaiting
 // approval → "direct ⇥" to steer it interactively.
 // Pushed LAST so it renders after revert.
 if(t.session&&!t.executing){
  const stuck=t.awaiting_answer||t.interrupted||t.status=="FAILED"
  const awaiting=t.status=="RUNNING"&&!stuck
  if(stuck||awaiting)
   b.push(`<button onclick="resume('${t.session}')">${stuck?"resume":"direct"} ⇥</button>`)}
 return `<div class=acts>${b.join("")}</div>`}
async function refresh(){
 const ts=await (await fetch("/api/tasks")).json()
 const rank=s=>s=="DONE"?1:0; ts.sort((a,b)=>rank(a.status)-rank(b.status))
 E("tasks").innerHTML=ts.map(t=>`<div class=t><div class="st ${t.status}">${t.status}`+
  `${t.next?" ·next":""}${t.awaiting_answer?" ·awaiting you":""}`+
  `${t.dep_status=="pending"?" ·blocked by dep":""}</div>`+
  `<div class=nm onclick="openPlan('${t.file}')" title="open plan"><span>${t.file.replace(/\.task\.md$/,"")}</span></div>`+
  `${buttons(t)}</div>`).join("")||"<div class='empty'>No tasks</div>"
 // Animate the logo only while a task is actively executing; otherwise freeze
 // it on its last frame so it sits there as a static brand mark.
 ts.some(t=>t.executing)?golStart():golStop()
 const lg=await (await fetch("/api/log")).json()
 // The server's GOL cycle divider is the only multi-line "─"-led item; the
 // NEWEST one is upgraded to a live canvas board, older ones stay as text.
 const isMark=l=>typeof l=="string"&&l[0]=="─"&&l.indexOf("\n")>=0
 let cycleCount=0,newestIdx=-1
 lg.forEach((l,i)=>{if(isMark(l)){cycleCount++;newestIdx=i}})
 E("log").innerHTML=lg.slice().reverse().map((l,ri)=>{
  // Object entries are long/multi-line markdown messages: render them inline as
  // formatted markdown (marked.js) instead of dumping raw ## / ** into the log.
  if(l&&typeof l=="object")return `<div class="l md">${window.marked?marked.parse(l.md||""):esc(l.md||"")}</div>`
  // Newest cycle divider → animated/frozen canvas (with the server text grid as
  // <canvas> fallback content so a cycle boundary is never invisible).
  if(isMark(l)&&(lg.length-1-ri)===newestIdx)
   return `<div class="l golmarkwrap"><canvas id=golmark class=golmark width=${MARK.cols} height=${MARK.rows}>${esc(l)}</canvas></div>`
  const c={"●":"la","→":"lt","✓":"lr","─":"ls","⌖":"lg","✗":"le","Σ":"lm","▶":"lk"}[l[0]]||"lx";return `<div class="l ${c}">${esc(l)}</div>`}).join("")||((ts.some(t=>t.executing)||E("working").innerHTML)?"":"<div class='empty'>Idle — waiting for a READY task</div>")
 // Animate exactly once per brand-new cycle (strict count increase); on the
 // first sight and on every other poll just repaint the frozen frame so the 2s
 // full re-render of #log never restarts or flickers the animation.
 if(newestIdx>=0){
  if(lastCycleCount!==null&&cycleCount>lastCycleCount)markAnimate()
  else markFreeze()
  lastCycleCount=cycleCount}
 pollStatus()}
golSeed();golDraw() // paint a static logo frame on load; refresh() animates it only while executing
fetch("/api/repo").then(r=>r.json()).then(d=>E("repo").textContent=d.repo)
fetch("/api/auto").then(r=>r.json()).then(d=>{auto=d.enabled;drawAuto();refresh()})
refresh();setInterval(refresh,2000);setInterval(drawWork,1000)

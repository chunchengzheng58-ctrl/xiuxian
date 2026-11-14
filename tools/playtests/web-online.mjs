import {createRequire} from 'node:module';
import {readFileSync,mkdirSync,writeFileSync,linkSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {randomUUID,createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const here=fileURLToPath(new URL('.',import.meta.url));
const project=resolve(here,'../..');
const site=process.argv[2]??resolve(project,'../../outputs/commercial-preview/web');
const work=join(project,'work/playtests/web-online-'+randomUUID());
mkdirSync(work,{recursive:true});
mkdirSync(join(work,'temp'));
process.env.TEMP=join(work,'temp');
process.env.TMP=join(work,'temp');
const output=process.argv[3]??resolve(project,'../../outputs/commercial-preview/web-online');
mkdirSync(output,{recursive:true});
const require=createRequire(import.meta.url);
const {chromium}=require(process.env.PLAYWRIGHT_MODULE??'C:/Users/zcc36/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const {buildApp}=await import(pathToFileURL(join(project,'server/dist/src/app.js')));
const origins=[];
const script=readFileSync(join(here,'web-control.gd')).toString('base64');
const manifest=JSON.parse(readFileSync(join(site,'manifest.json'),'utf8'));
const pckHash=createHash('sha256').update(readFileSync(join(site,'index.pck'))).digest('hex');
assert.equal(pckHash,manifest.files.find(f=>f.name==='index.pck').sha256,'The test must use the identified PCK');
const override=Buffer.from('[application]\nrun/main_scene="res://web-test.tscn"\n').toString('base64');
const testScene=Buffer.from('[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://web-test.gd" id="1"]\n[node name="WebTest" type="Node"]\nscript = ExtResource("1")\n').toString('base64');
const testSite=join(work,'site');
mkdirSync(testSite);
for(const file of manifest.files){
 if(file.name!=='index.html')linkSync(join(site,file.name),join(testSite,file.name));
}
writeFileSync(join(testSite,'index.html'),readFileSync(join(site,'index.html'),'utf8')
 .replace('engine.startGame({',`Promise.all([engine.preloadFile(Uint8Array.from(atob('${script}'),c=>c.charCodeAt(0)), '/web-test.gd'),engine.preloadFile(Uint8Array.from(atob('${override}'),c=>c.charCodeAt(0)), '/override.cfg'),engine.preloadFile(Uint8Array.from(atob('${testScene}'),c=>c.charCodeAt(0)), '/web-test.tscn')]).then(() => engine.startGame({args:['--','--skip-intro','--kernel-ephemeral'],`)
 .replace('}).then(() => { status.hidden = true; }, showError);','})).then(() => { status.hidden = true; }, showError);'));
const server=await buildApp({worker:false,origins,web:{root:testSite},randomInt:()=>0});
const password='web-online-fixture-password';
const accounts={};
for(const username of ['web_alpha','web_beta']){
 assert.equal((await server.app.inject({method:'POST',url:'/api/v2/auth/register',payload:{username,password}})).statusCode,200);
 const session=(await server.app.inject({method:'POST',url:'/api/v2/auth/login',payload:{username,password}})).json().data;
 accounts[username]=session;
}
const logs=[],contexts=[],httpFailures=[];
let serial=0;
const pause=ms=>new Promise(r=>setTimeout(r,ms));
function log(value){logs.push(value);console.log('WEB_ONLINE '+value);}
async function action(page,data){
 const id=++serial;
 await page.evaluate(request=>{window.__gameResult=null;window.__gameRequest=JSON.stringify(request);},{id,...data});
 await page.waitForFunction(id=>{try{return JSON.parse(window.__gameResult)?.id===id}catch{return false}},id,{timeout:15000});
 const {result}=await page.evaluate(()=>JSON.parse(window.__gameResult));
 if(!data.allowMiss)assert(result.ok,JSON.stringify({data,result}));
 return result;
}
const state=page=>action(page,{op:'inspect'});
async function until(page,predicate,label,timeout=20000){
 const end=Date.now()+timeout;
 while(Date.now()<end){const value=await state(page);if(predicate(value))return value;await pause(120);}
 const value=await state(page);
 writeFileSync(join(work,'failed-state-'+serial+'.json'),JSON.stringify(value,null,2));
 await page.screenshot({path:join(output,'failed-'+serial+'.png')});
 throw new Error('Timeout: '+label);
}
async function click(page,text,prefix=false){
 for(let attempt=0;attempt<3;attempt++){
  await until(page,s=>s.buttons.some(b=>!b.disabled&&(prefix?b.text.startsWith(text):b.text===text)),'button '+text);
  const result=await action(page,{op:'click',text,prefix,allowMiss:true});
  if(result.ok)return;
  await pause(150);
 }
 await capture(page,'click-failure-'+serial);
 writeFileSync(join(work,'click-failure-'+serial+'.json'),JSON.stringify(await state(page),null,2));
 throw new Error('Visible button never received mouse event: '+text);
}
async function input(page,placeholder,value){await action(page,{op:'field',placeholder,value});}
async function capture(page,name){await pause(120);await page.screenshot({path:join(output,name+'.png')});}
async function interruptTransport(client,id,expedition,seat=0){
 await client.context.setOffline(true);
 // Force the established transport down too: browser offline emulation alone
 // may leave an already-open WebSocket alive on some Chromium versions.
 for(const [socket,current] of server.realtime.clients){
  if(current.session.account_id===accounts[client.role].account_id)socket.terminate();
 }
 const read=()=>expedition?server.game.expedition.state({id}):server.game.arena.state({id,seat});
 const deadline=Date.now()+3000;
 while(Date.now()<deadline&&read()?.phase!=='reconnecting')await pause(20);
 assert.equal(read()?.phase,'reconnecting','The game server must observe actual transport loss');
 const before=read();
 await pause(350);
 const frozen=read();
 if(expedition){assert.equal(before.player.hp,frozen.player.hp);assert.equal(before.enemy.hp,frozen.enemy.hp);}
 else assert.deepEqual(before.players.map(p=>p.hp),frozen.players.map(p=>p.hp));
 await client.context.setOffline(false);
 log((expedition?'PVE':'PVP')+' authoritative reconnecting phase and frozen health observed during transport outage');
}
async function startBrowser(role){
 const context=await chromium.launchPersistentContext(join(work,role),{
  executablePath:process.env.BROWSER_EXECUTABLE??'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',headless:true,viewport:{width:1440,height:900},
  downloadsPath:join(work,'downloads'),tracesDir:join(work,'traces'),
  env:{...process.env,TEMP:join(work,'temp'),TMP:join(work,'temp')},
  args:['--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader','--no-proxy-server','--disable-background-timer-throttling','--disable-renderer-backgrounding']});
 contexts.push(context);
 const page=context.pages()[0];
 const errors=[];
 const faults={drawAbortActive:false,expected:[]};
 page.on('pageerror',error=>errors.push(error.message));
 page.on('console',entry=>{
  writeFileSync(join(work,role+'-console.log'),entry.type()+': '+entry.text()+'\n',{flag:'a'});
  const expected=faults.drawAbortActive&&(/Failed to load resource.*ERR_FAILED/.test(entry.text())||entry.text().startsWith('TypeError: Failed to fetch'));
  if(expected)faults.expected.push({kind:'console',message:entry.text()});
  if(!expected&&(entry.type()==='error'||entry.text().includes('SCRIPT ERROR')))errors.push(entry.text());
  if(entry.text().includes('ERROR')||entry.text().includes('WARNING'))console.log(role,entry.text());
 });
 page.on('requestfailed',request=>{if(!request.url().includes('/api/v2/realtime')){
  if(faults.drawAbortActive&&request.postDataJSON()?.command==='growth.draw')faults.expected.push({kind:'request',failure:request.failure(),command:'growth.draw'});
  else logs.push({role,networkError:request.failure(),url:request.url()});
 }});
 page.on('response',response=>{if(response.status()>=400)httpFailures.push({role,status:response.status(),url:response.url()});});
 await page.goto(server.app.listeningOrigin,{timeout:90000});
 try{await page.waitForFunction(()=>window.__gameReady===true,null,{timeout:30000});}catch(error){await page.screenshot({path:join(output,role+'-boot-failure.png')});writeFileSync(join(work,role+'-boot.json'),JSON.stringify(await page.evaluate(()=>({text:document.body.innerText,ready:window.__gameReady,request:window.__gameRequest,engine:typeof engine})),null,2));throw error;}
 await action(page,{op:'login',username:role,password});
 await until(page,s=>s.ready&&s.remote,'authenticated remote account');
 await action(page,{op:'key',code:4194305}); // Escape closes the family page.
 log(role+' browser authenticated against its own account');
 return {page,context,errors,role,faults};
}
async function expedition(client,reconnect=false){
 const {page}=client;
 await click(page,'五域游历 / 主线');
 await click(page,'前往本章秘境');
 await click(page,'进入秘境');
 let value=await until(page,s=>s.expedition?.phase==='fighting','PVE fighting');
 const runId=value.expedition.run_id;
 let seq=0,rejoined=false,sawWarning=false;
 const deadline=Date.now()+90000;
 while(Date.now()<deadline){
  value=await state(page);
  const v=value.expedition;
  if(v.result){assert(v.result.won,'Browser player should defeat first boss');break;}
  if(v.phase!=='fighting'){await pause(80);continue;}
  const own=v.player, enemy=v.enemy;
  const dx=enemy.x-own.x,dy=enemy.y-own.y,dist=Math.hypot(dx,dy);
  let mx=dist>85?dx/dist:0,my=dist>85?dy/dist:0,danger=false;
  for(const zone of v.telegraphs){
   sawWarning=true;
   if(zone.kind==='circle'&&Math.hypot(own.x-zone.x,own.y-zone.y)<zone.radius+32){mx=0;my=own.y>555?-1:1;danger=true;}
   else if(zone.kind==='line'){
    const x2=zone.x2-zone.x,y2=zone.y2-zone.y,len=x2*x2+y2*y2;
    const t=len?Math.max(0,Math.min(1,((own.x-zone.x)*x2+(own.y-zone.y)*y2)/len)):0;
    const x=own.x-zone.x-t*x2,y=own.y-zone.y-t*y2,d=Math.hypot(x,y);
    if(d<zone.width/2+32){mx=d?x/d:0;my=d?y/d:1;danger=true;}
   }
  }
  await action(page,{op:'move',x:mx,y:my});
  let use=0;
  if(danger&&own.cd[3]===0)use=3;
  else if(own.hp<own.max_hp*.55&&own.cd[5]===0&&own.mp>=40)use=5;
  else if(dist<110&&own.cd[1]===0)use=1;
  else if(own.cd[2]===0&&own.mp>=18)use=2;
  if(use)await action(page,{op:'action',action:use});
  if(reconnect&&!rejoined&&enemy.hp<enemy.max_hp*.7){
   await action(page,{op:'move',x:0,y:0});
   await interruptTransport(client,runId,true);
   value=await until(page,s=>s.expedition?.run_id===runId&&s.expedition?.phase==='fighting','same PVE room reconnected',15000);
   rejoined=true;log('PVE browser network interruption rejoined same run');
  }
  if(seq++===4)await capture(page,client.role+'-pve-fight');
  await pause(50);
 }
 await action(page,{op:'move',x:0,y:0});
 value=await until(page,s=>s.expedition?.result?.won,'PVE authoritative victory');
 assert(sawWarning);
 assert.equal(value.expedition.result.reward.spirit_stones,100);
 assert.equal(value.expedition.result.reward.materials,8);
 assert(value.expedition.result.reward.equipment);
 await capture(page,client.role+'-pve-result');
 await click(page,'返回秘境');
 await until(page,s=>s.equipment.qi===100&&s.equipment.inventory.length===1,'PVE reward account snapshot');
 await action(page,{op:'key',code:4194305});
 log(client.role+' production Web PVE victory, real rewards and inventory synced');
}
async function social(alpha,beta){
 for(const [client,alias] of [[alpha,'网页松风'],[beta,'网页云栖']]){
  await click(client.page,'同道录 / 好友',true);
  await click(client.page,'我的名片');
  await input(client.page,'社交昵称 · 1–12 个字符',alias);
  await click(client.page,'创建名片');
  await until(client.page,s=>s.buttons.some(b=>b.text==='保存昵称'),'social profile saved');
 }
 const ownBeta=server.game.snapshot(accounts.web_beta.account_id).cultivators.find(c=>c.role==='self');
 const code=server.game.social.home(server.game.own(accounts.web_beta.account_id,ownBeta.cultivator_id)).profile.invite_code;
 await click(alpha.page,'好友');
 await input(alpha.page,'粘贴对方的邀请码',code);
 await click(alpha.page,'添加好友');
 await click(beta.page,'好友申请',true);
 await click(beta.page,'接受');
 await click(beta.page,'好友');
 await click(alpha.page,'私聊',true);
 await input(alpha.page,'给好友写一条消息','网页实机消息');
 await click(alpha.page,'发送私信');
 await click(beta.page,'私聊',true);
 await until(beta.page,s=>s.labels.some(t=>t.includes('网页实机消息')),'peer received actual private message');
 await capture(beta.page,'web-social-chat');
 for(const c of [alpha,beta])await action(c.page,{op:'key',code:4194305});
 log('Two production Web clients created profiles, invited, accepted and exchanged a private message');
}
async function drawRecovery(client,diagnostic=false){
 const {page}=client;
 await click(page,'聚宝阁');
 let committed=null,drop=true;
 const sent=[];
 await page.route('**/api/v2/commands',async route=>{
  const body=route.request().postDataJSON();
  if(body.command!=='growth.draw')return route.continue();
  sent.push(body.payload.request_id);
  if(!drop)return route.continue();
  drop=false;
  const response=await route.fetch();
  assert.equal(response.status(),200);
  committed=(await response.json()).data;
  client.faults.drawAbortActive=true;
  await route.abort('failed');
 });
 await click(page,'祈愿一次',true);
 let value=await until(page,s=>s.equipment.qi===30&&s.equipment.pending_draw&&s.equipment.inventory.length===2&&!s.submitting&&!s.busy,'Committed wish response lost, websocket balance 30 and pending retained');
 const key=value.equipment.pending_draw.request_id;
 assert.equal(key,committed.request_id);
 const drawButtons=s=>s.buttons.filter(b=>b.text.includes('祈愿一次')||b.text.includes('十连祈愿')||b.text.includes('恢复')||b.text.includes('找回')||b.text.includes('继续上次'));
 const before=drawButtons(value);
 await action(page,{op:'skip'});
 value=await state(page);
 const after=drawButtons(value);
 await capture(page,'web-draw-lost-response');
 if(diagnostic)writeFileSync(join(output,'draw-recovery-before-fix.json'),JSON.stringify({key,before,after,pending:value.equipment.pending_draw,qi:value.equipment.qi},null,2));
 else{
  const recovery=after.find(b=>b.text.includes('恢复')||b.text.includes('找回')||b.text.includes('继续上次'));
  assert(recovery&&!recovery.disabled,'Pending wish must remain recoverable after finish_reveal with balance below cost');
  assert(after.filter(b=>b!==recovery).every(b=>b.disabled),'Other draw count must remain disabled while recovery is pending');
 }
 await pause(1500);
 await page.reload({timeout:90000});
 await page.waitForFunction(()=>window.__gameReady===true,null,{timeout:90000});
 await action(page,{op:'login',username:client.role,password});
 value=await until(page,s=>s.ready&&s.remote,'Relogin after lost wish response');
 assert.equal(value.equipment.pending_draw?.request_id,key,'Pending wish survives browser refresh and login');
 assert.equal(value.equipment.qi,30);
 await action(page,{op:'key',code:4194305});
 await click(page,'聚宝阁');
 value=await state(page);
 const recovery=value.buttons.find(b=>(b.text.includes('恢复')||b.text.includes('找回')||b.text.includes('继续上次'))&&!b.disabled)??value.buttons.find(b=>b.text.startsWith('祈愿一次')&&!b.disabled);
 assert(recovery,'Original single-draw receipt can be recovered after relogin');
 await action(page,{op:'click',path:recovery.path});
 value=await until(page,s=>!s.equipment.pending_draw&&s.equipment.last_request===key,'Original receipt recovered and pending cleared');
 await action(page,{op:'skip'});
 assert.equal(value.equipment.inventory.length,2);
 assert.equal(value.equipment.qi,30);
 assert(sent.length>=2&&sent.every(item=>item===key),'Every retry uses the original idempotency key');
 assert(value.equipment.inventory.some(i=>i.id===committed.items[0].equipment_id),'Recovered draw contains original equipment instance');
 const ledger=server.db.all('SELECT delta FROM ledger WHERE operation_id=?',committed.draw_id);
 assert.deepEqual(ledger.map(row=>row.delta),[-70]);
 client.faults.drawAbortActive=false;
 await page.unroute('**/api/v2/commands');
 await capture(page,'web-draw-recovered');
 log('Wish response intentionally dropped after server commit; wallet 30/pending retained, refresh+login recovered same key and original item, one -70 ledger debit');
 return {key,before,after,expectedFailures:client.faults.expected};
}
async function equipmentAndMarket(alpha,beta){
 const page=alpha.page;
 await drawRecovery(alpha);
 await click(page,'我的行囊',true);
 let value=await state(page);
 const card=value.buttons.find(b=>b.tooltip.includes('听风剑')&&b.text==='');
 assert(card,'PVE weapon visible as real item card');
 await action(page,{op:'click',path:card.path});
 await click(page,'穿戴装备');
 value=await until(page,s=>Object.keys(s.equipment.equipped).length>0,'equipped weapon');
 const itemId=value.equipment.equipped.weapon;
 await click(page,'前往锻造');
 await click(page,'强化 ·',true);
 await until(page,s=>s.equipment.inventory.some(i=>i.id===itemId&&i.upgrade_level===1),'equipment upgrade');
 await capture(page,'web-forge-upgrade');
 await click(page,'我的行囊',true);
 await click(page,'卸下装备');
 await until(page,s=>!s.equipment.equipped.weapon,'weapon unequipped');
 await click(page,'定价上架');
 await input(page,'售价（灵气）','12');
 await click(page,'确认上架');
 await until(page,s=>s.equipment.inventory.some(i=>i.id===itemId&&i.market_listing_id),'market listing locked');
 await click(beta.page,'聚宝阁');
 await click(beta.page,'万宝集');
 await click(beta.page,'购买');
 await action(beta.page,{op:'confirm'});
 await until(beta.page,s=>s.equipment.inventory.some(i=>i.id===itemId&&i.upgrade_level===1&&i.school===0),'buyer received upgraded school equipment');
 await until(page,s=>s.equipment.inventory.every(i=>i.id!==itemId)&&s.equipment.qi===32,'seller paid exactly once');
 assert.equal((await state(beta.page)).equipment.qi,88);
 await capture(beta.page,'web-market-purchase');
 for(const c of [alpha,beta])await action(c.page,{op:'key',code:4194305});
 log('Browser PVE rewards funded a draw; real UI wore/upgraded/unequipped/sold gear and buyer received exact school and level');
}
async function duel(alpha,beta,ranked=false){
 if(ranked){
  for(const c of [alpha,beta])await click(c.page,'匹配对战');
  await click(alpha.page,'开始匹配');
  await click(alpha.page,'取消匹配');
  await click(alpha.page,'开始匹配');
  await click(beta.page,'开始匹配');
 }else{
  for(const c of [alpha,beta]){
   await click(c.page,'论剑台 / 对战',true);
   const value=await state(c.page);
   if(value.buttons.some(b=>b.text==='好友切磋'))await click(c.page,'好友切磋');
  }
  await click(alpha.page,'邀约');
  await click(beta.page,'接受约战');
  await Promise.all([click(alpha.page,'进入擂台'),click(beta.page,'进入擂台')]);
 }
 await Promise.all([until(alpha.page,s=>s.duel?.phase==='fighting','alpha duel fighting'),until(beta.page,s=>s.duel?.phase==='fighting','beta duel fighting')]);
 let value=await state(alpha.page),duelId=value.duel.match_id,rejoined=false;
 const end=Date.now()+45000;
 while(Date.now()<end){
  value=await state(alpha.page);
  const v=value.duel;
  if(v.result){assert.equal(v.result.winner,v.seat);break;}
  if(v.phase==='fighting'){
   const own=v.players[v.seat],peer=v.players[1-v.seat],dx=peer.x-own.x,dy=peer.y-own.y,d=Math.hypot(dx,dy);
   await action(alpha.page,{op:'move',x:d>85?dx/d:0,y:d>85?dy/d:0});
   if(d<110&&own.cd[1]===0)await action(alpha.page,{op:'action',action:1});
   else if(own.cd[2]===0&&own.mp>=18)await action(alpha.page,{op:'action',action:2});
   if(!rejoined&&peer.hp<75){
    await interruptTransport(alpha,duelId,false,v.seat);
    await until(alpha.page,s=>s.duel?.match_id===duelId&&s.duel?.phase==='fighting','same browser PVP reconnect',15000);
    rejoined=true;
   }
  }
  await pause(40);
 }
 await action(alpha.page,{op:'move',x:0,y:0});
 const [a,b]=await Promise.all([until(alpha.page,s=>s.duel?.result,'alpha PVP result'),until(beta.page,s=>s.duel?.result,'beta PVP result')]);
 assert.equal(a.duel.result.reason,'knockout');assert.equal(a.duel.result.winner,b.duel.result.winner);
 if(ranked){
  assert.equal(a.duel.mode,'ranked');
  assert.equal(a.duel.rating_change.after,1012);
  assert.equal(b.duel.rating_change.after,988);
 }
 await capture(alpha.page,ranked?'web-ranked-result':'web-pvp-result');
 await Promise.all([click(alpha.page,'返回论剑台'),click(beta.page,'返回论剑台')]);
 await until(alpha.page,s=>s.labels.some(t=>t.includes(ranked?'1012':'胜利')),'winner history/rating');
 await until(beta.page,s=>s.labels.some(t=>t.includes(ranked?'988':'落败')),'loser history/rating');
 if(ranked)await capture(alpha.page,'web-ranked-leaderboard');
 log(ranked?'Two production Web clients queued, cancelled, requeued, auto-entered ranked combat and received exact 1012/988 ratings and leaderboard':'Two production Web clients invited, accepted, fought, reconnected and agreed on server knockout and battle history');
}
try{
 await server.app.listen({host:'127.0.0.1',port:0});
 origins.push(server.app.listeningOrigin);
 const alpha=await startBrowser('web_alpha');
 await expedition(alpha,true);
 if(process.argv.includes('--draw-recovery-only')||process.argv.includes('--draw-recovery-diagnostic')){
  const recovery=await drawRecovery(alpha,process.argv.includes('--draw-recovery-diagnostic'));
  writeFileSync(join(output,'web-draw-recovery-report.json'),JSON.stringify({work,site,pckHash,recovery,logs,errors:alpha.errors,httpFailures},null,2));
  log('Focused wish recovery check completed');
 }else{
 const beta=await startBrowser('web_beta');
 await expedition(beta,false);
 await social(alpha,beta);
 await equipmentAndMarket(alpha,beta);
 await duel(alpha,beta);
 if(process.argv.includes('--ranked'))await duel(alpha,beta,true);
 const errors=[...alpha.errors,...beta.errors];
 const unexpectedNetworkFailures=logs.filter(line=>typeof line==='object'&&line.networkError);
 const expectedNetworkFaults=[...alpha.faults.expected,...beta.faults.expected];
 const finalSnapshots=Object.fromEntries(Object.entries(accounts).map(([name,session])=>[name,server.game.snapshot(session.account_id)]));
 writeFileSync(join(output,'web-online-report.json'),JSON.stringify({work,site,pckHash,runtimeSourceFingerprint:manifest.runtimeSourceFingerprint,logs,errors,httpFailures,unexpectedNetworkFailures,expectedNetworkFaults,finalSnapshots},null,2));
 assert.equal(errors.length,0,JSON.stringify(errors));
 assert.equal(httpFailures.length,0,JSON.stringify(httpFailures));
 assert.equal(unexpectedNetworkFailures.length,0,JSON.stringify(unexpectedNetworkFailures));
 assert.equal(expectedNetworkFaults.filter(f=>f.kind==='request').length,1,'Only the intentionally aborted draw response may fail');
 log('All production Web online flows passed');
 }
}catch(error){writeFileSync(join(work,'error.txt'),String(error.stack));throw error;}
finally{for(const context of contexts)await context.close();await server.app.close();}

import {createRequire} from 'node:module';
import {readFileSync,writeFileSync,mkdirSync,readdirSync,linkSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {randomUUID,createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const here=fileURLToPath(new URL('.',import.meta.url)), project=resolve(here,'../..');
const site=process.argv[2]??resolve(project,'../../outputs/complete-preview/web');
const output=process.argv[3]??resolve(project,'../../outputs/complete-preview/touch-online');
const work=join(project,'work/playtests/touch-online-'+randomUUID());
mkdirSync(join(work,'temp'),{recursive:true});mkdirSync(output,{recursive:true});
process.env.TEMP=join(work,'temp');process.env.TMP=join(work,'temp');
const {chromium}=createRequire(import.meta.url)(process.env.PLAYWRIGHT_MODULE??'C:/Users/zcc36/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const {buildApp}=await import(pathToFileURL(join(project,'server/dist/src/app.js')));
const packHash=createHash('sha256').update(readFileSync(join(site,'index.pck'))).digest('hex');
const testSite=join(work,'site');mkdirSync(testSite);
for(const name of readdirSync(site).filter(n=>n.startsWith('index.')&&n!=='index.html'))linkSync(join(site,name),join(testSite,name));
const b64=s=>Buffer.from(s).toString('base64');
const files=[['/touch-test.gd',readFileSync(join(here,'touch-online.gd'))],['/override.cfg','[application]\nrun/main_scene="res://touch-test.tscn"\n'],['/touch-test.tscn','[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://touch-test.gd" id="1"]\n[node name="TouchTest" type="Node"]\nscript = ExtResource("1")\n']];
const preload=files.map(([name,text])=>`engine.preloadFile(Uint8Array.from(atob('${b64(text)}'),c=>c.charCodeAt(0)),${JSON.stringify(name)})`).join(',');
writeFileSync(join(testSite,'index.html'),readFileSync(join(site,'index.html'),'utf8').replace('engine.startGame({',`Promise.all([${preload}]).then(()=>engine.startGame({args:['--','--skip-intro','--kernel-ephemeral'],`).replace('}).then(() => { status.hidden = true; }, showError);','})).then(() => { status.hidden = true; }, showError);'));
const origins=[], server=await buildApp({worker:false,origins,web:{root:testSite},randomInt:()=>0});
const logs=[],errors=[],httpFailures=[],contexts=[];
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const log=text=>{logs.push(text);console.log('TOUCH_ONLINE '+text);};
let serial=0;
async function state(page){
 const id=++serial;
 await page.evaluate(id=>{window.__touchResult=null;window.__touchRequest=JSON.stringify({id,op:'inspect'});},id);
 await page.waitForFunction(id=>{try{return JSON.parse(window.__touchResult)?.id===id}catch{return false}},id,{timeout:15000});
 return (await page.evaluate(()=>JSON.parse(window.__touchResult))).result;
}
async function until(page,predicate,label,timeout=20000){
 const end=Date.now()+timeout;
 while(Date.now()<end){const s=await state(page);if(predicate(s))return s;await pause(100);}
 writeFileSync(join(work,'failure-state-'+serial+'.json'),JSON.stringify(await state(page),null,2));
 await page.screenshot({path:join(output,'failure-'+serial+'.png')});
 throw new Error('Timeout: '+label);
}
class Fingers{
 constructor(cdp){this.cdp=cdp;this.points=new Map();}
 async set(id,point){const existing=this.points.has(id);if(point)this.points.set(id,{id,x:point.x,y:point.y,radiusX:5,radiusY:5,force:1});else this.points.delete(id);await this.cdp.send('Input.dispatchTouchEvent',{type:point?(existing?'touchMove':'touchStart'):'touchEnd',touchPoints:[...this.points.values()]});}
 async tap(point,id=5){await this.set(id,point);await pause(60);await this.set(id,null);await pause(80);}
 async release(){await this.cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});this.points.clear();}
}
async function metrics(page,s){const box=await page.locator('canvas').boundingBox();return {box,sx:box.width/s.viewport.width,sy:box.height/s.viewport.height};}
function convert(point,m){return {x:m.box.x+point.x*m.sx,y:m.box.y+point.y*m.sy};}
function center(rect){return {x:rect.x+rect.width/2,y:rect.y+rect.height/2};}
function centeredVisible(entry){const p=center(entry.rect),c=entry.clip;return c.width>0&&c.height>0&&p.x>c.x+1&&p.x<c.x+c.width-1&&p.y>c.y+1&&p.y<c.y+c.height-1;}
async function swipe(client,rect,up=true){
 const s=await state(client.page),m=await metrics(client.page,s);
 const x=rect.x+rect.width*.78,y1=rect.y+rect.height*(up?.8:.2),y2=rect.y+rect.height*(up?.2:.8);
 await client.fingers.set(7,convert({x,y:y1},m));
 for(let step=1;step<=10;step++){await client.fingers.set(7,convert({x,y:y1+(y2-y1)*step/10},m));await pause(25);}
 await client.fingers.set(7,null);await pause(180);
}
async function locate(client,predicate,field=false){
 for(let attempt=0;attempt<14;attempt++){
  const s=await state(client.page),entry=(field?s.fields:s.buttons).find(predicate);
  if(entry&&centeredVisible(entry))return {s,entry};
  if(!entry){await pause(120);continue;}
  const scroll=(entry.scroll_chain??[entry.scroll]).map(path=>s.scrolls.find(r=>r.path===path)).find(r=>r?.clip.height>Math.max(90,entry.rect.height)&&r.maximum>r.page);
  assert(scroll,'Offscreen control must have an accessible scroll parent');
  await swipe(client,scroll.clip,entry.rect.y>scroll.clip.y);
 }
 writeFileSync(join(work,'unreachable-state-'+serial+'.json'),JSON.stringify(await state(client.page),null,2));
 await client.page.screenshot({path:join(output,'unreachable-'+serial+'.png')});
 throw new Error('Unable to reach requested touch control');
}
async function tapButton(client,text,prefix=false){
 console.log('TOUCH_ACTION tap '+text);
 const {s,entry}=await locate(client,b=>!b.disabled&&(prefix?b.text.startsWith(text):b.text===text));
 await client.fingers.tap(convert(center(entry.rect),await metrics(client.page,s)));
}
async function field(client,placeholder,value,keyboardCheck=false){
 console.log('TOUCH_ACTION input '+placeholder);
 const {s,entry}=await locate(client,f=>f.placeholder===placeholder,true);
 await client.fingers.tap(convert(center(entry.rect),await metrics(client.page,s)));
 await client.page.waitForFunction(()=>document.activeElement.matches('#stage > input:not(:disabled),#stage > textarea:not(:disabled)'),null,{timeout:5000});
 const input=client.page.locator('#stage > input:focus,#stage > textarea:focus');
 await input.fill(value);
 await until(client.page,latest=>latest.fields.some(f=>f.path===entry.path&&f.length===value.length),'native input reached Godot');
 if(keyboardCheck){
  const original=await client.page.locator('canvas').boundingBox();
  await client.page.setViewportSize({width:844,height:230});await pause(160);
  const editing=await client.page.locator('canvas').boundingBox();
  assert.equal(editing.width,original.width);assert.equal(editing.height,original.height);
  await client.page.screenshot({path:join(output,'touch-native-keyboard.png')});
  await client.page.setViewportSize({width:844,height:390});await pause(120);
 }
 const current=await state(client.page),m=await metrics(client.page,current);
 await client.fingers.tap(convert({x:35,y:32},m));
}
async function openClient(){
 const context=await chromium.launchPersistentContext(join(work,'profile'),{executablePath:process.env.BROWSER_EXECUTABLE??'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',headless:true,viewport:{width:844,height:390},isMobile:true,hasTouch:true,downloadsPath:join(work,'downloads'),tracesDir:join(work,'traces'),env:{...process.env,TEMP:join(work,'temp'),TMP:join(work,'temp')},args:['--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader','--no-proxy-server','--disable-background-timer-throttling','--disable-renderer-backgrounding']});
 contexts.push(context);const page=context.pages()[0];
 await page.addInitScript(()=>{
  window.__touchAudioContexts=[];window.__touchAudioAnalysers=[];
  for(const name of ['AudioContext','webkitAudioContext']){
   const Native=window[name];if(!Native)continue;
   window[name]=class extends Native{constructor(...args){super(...args);window.__touchAudioContexts.push(this);}};
  }
  const connect=AudioNode.prototype.connect;
  AudioNode.prototype.connect=function(destination,...args){
   const result=connect.call(this,destination,...args);
   if(destination===this.context.destination){const analyser=this.context.createAnalyser();connect.call(this,analyser);window.__touchAudioAnalysers.push(analyser);}
   return result;
  };
 });
 page.on('pageerror',e=>errors.push(e.message));
 page.on('console',e=>{writeFileSync(join(work,'console.log'),e.type()+': '+e.text()+'\n',{flag:'a'});if(e.type()==='error')errors.push(e.text());});
 page.on('response',r=>{if(r.status()>=400)httpFailures.push({url:r.url(),status:r.status()});});
 await page.goto(server.app.listeningOrigin,{timeout:90000});
 await page.waitForFunction(()=>window.__touchReady===true,null,{timeout:90000});
 const cdp=await context.newCDPSession(page);
 return {context,page,cdp,fingers:new Fingers(cdp)};
}
function unsafe(zone,p){
 if(zone.kind==='circle')return Math.hypot(p.x-zone.x,p.y-zone.y)<zone.radius+15;
 if(zone.kind==='line'){const dx=zone.x2-zone.x,dy=zone.y2-zone.y,t=Math.max(0,Math.min(1,((p.x-zone.x)*dx+(p.y-zone.y)*dy)/(dx*dx+dy*dy||1)));return Math.hypot(p.x-zone.x-dx*t,p.y-zone.y-dy*t)<zone.width/2+15;}
 return (zone.polygons??[]).some(poly=>{let inside=false;for(let i=0,j=poly.length-1;i<poly.length;j=i++){const a=poly[j],b=poly[i];if((a[1]>p.y)!==(b[1]>p.y)&&p.x<(b[0]-a[0])*(p.y-a[1])/(b[1]-a[1])+a[0])inside=!inside;}return inside;});
}
function intent(v){
 const own=v.player,enemy=v.enemy,threats=[...(v.telegraphs??[]),...(v.hazards??[])],points=[own];
 for(let angle=0;angle<Math.PI*2;angle+=Math.PI/8)for(const r of [96,190])points.push({x:Math.max(235,Math.min(1205,enemy.x+Math.cos(angle)*r)),y:Math.max(405,Math.min(700,enemy.y+Math.sin(angle)*r))});
 const score=p=>threats.filter(z=>unsafe(z,p)).length*10000+Math.hypot(p.x-own.x,p.y-own.y)*.8+Math.abs(Math.hypot(p.x-enemy.x,p.y-enemy.y)-96)*1.6;
 const best=points.reduce((a,b)=>score(b)<score(a)?b:a,points[0]);
 const moving=Math.hypot(best.x-own.x,best.y-own.y)>8,dx=moving?best.x-own.x:enemy.x-own.x,dy=moving?best.y-own.y:enemy.y-own.y,length=Math.hypot(dx,dy)||1;
 const danger=(v.telegraphs??[]).some(z=>z.remaining<.4&&unsafe(z,own));
 let action=Math.hypot(enemy.x-own.x,enemy.y-own.y)<126?0:1;
 if(danger&&own.cd[3]===0)action=3;
 else if(danger&&own.cd[4]===0)action=2;
 else if(own.hp<own.max_hp*.6&&own.cd[5]===0&&own.mp>=40&&!threats.some(z=>unsafe(z,own)))action=4;
 return {x:dx/length,y:dy/length,action};
}
async function fight(client){
 let s=await until(client.page,v=>v.expedition?.phase==='fighting'&&v.touch.active,'touch battle starts');
 assert(s.touch.enabled&&s.touch.buttons.length===5);
 const initialX=s.expedition.player.x,runId=s.expedition.run_id;
 let photographed=false,reconnected=false,settingsChecked=false,resized=false,usedSkills=new Set(),observedBasic=false,observedSpell=false,observedStick=false,observed960=false,deadline=Date.now()+130000;
 while(Date.now()<deadline){
  s=await state(client.page);if(s.expedition?.result)break;
  if(s.expedition?.phase!=='fighting'){await pause(100);continue;}
  const v=s.expedition,m=await metrics(client.page,s),next=intent(v),stick=s.touch.joystick;
  observedBasic ||= v.player.cd[1]>0;
  observedSpell ||= v.player.cd[2]>0&&v.player.mp<v.player.max_mp;
  observedStick ||= s.touch.captured.includes(0)&&(Math.abs(s.touch.move_x)+Math.abs(s.touch.move_y)>0.3);
  observed960 ||= resized&&s.touch.captured.includes(0)&&(Math.abs(s.touch.move_x)+Math.abs(s.touch.move_y)>0.3)&&v.player.cd[1]>0;
  await client.fingers.set(0,convert({x:stick.x+next.x*stick.radius*.95,y:stick.y+next.y*stick.radius*.95},m));
  const button=s.touch.buttons.find(b=>b.id===next.action);
  if(button&&!button.disabled){await client.fingers.tap(convert({x:button.x,y:button.y},m),1);usedSkills.add(button.label);}
  if(!photographed&&v.telegraphs.length){await client.page.screenshot({path:join(output,'touch-844-battle.png')});photographed=true;}
  if(!settingsChecked&&observedStick&&observedBasic){
   await tapButton(client,'设置');
   const opened=await until(client.page,value=>value.settings_open&&!value.touch.visible,'settings release touch controls');
   assert.equal(opened.touch.captured.length,0);assert.equal(opened.touch.move_x,0);assert.equal(opened.touch.move_y,0);
   await client.fingers.release();
   await tapButton(client,'全部静音 · F10');
   await until(client.page,value=>value.options.muted,'actual touch toggles mute');
   await tapButton(client,'全部静音 · F10');
   await until(client.page,value=>!value.options.muted,'actual touch restores audio');
   const after=await until(client.page,value=>value.expedition.tick>opened.expedition.tick+8,'authority keeps ticking under settings');
   assert.equal(after.expedition.phase,'fighting');
   await client.page.screenshot({path:join(output,'touch-settings-in-battle.png')});
   await client.fingers.release();await tapButton(client,'返回游戏 ×');
   await until(client.page,value=>!value.settings_open&&value.touch.active,'return from settings');
   settingsChecked=true;log('Real settings touch releases held joystick and captured fingers while the online battle keeps ticking');
  }
  if(!resized&&settingsChecked&&photographed){
   await client.fingers.release();await client.page.setViewportSize({width:960,height:540});await pause(250);
   resized=true;await client.page.screenshot({path:join(output,'touch-960-battle.png')});
  }
  if(!reconnected&&v.enemy.hp<v.enemy.max_hp*.65){
   await client.fingers.release();await client.context.setOffline(true);
   for(const [socket,current] of server.realtime.clients)if(current.session.account_id===server.db.get('SELECT account_id FROM cultivators WHERE id=?',s.actor).account_id)socket.terminate();
   const end=Date.now()+2000;while(Date.now()<end&&server.game.expedition.state({id:runId})?.phase!=='reconnecting')await pause(20);
   assert.equal(server.game.expedition.state({id:runId})?.phase,'reconnecting');
   await pause(350);await client.context.setOffline(false);
   await until(client.page,value=>value.expedition?.phase==='fighting'&&value.expedition.run_id===runId,'touch client restores same room',15000);
   reconnected=true;log('Real touch battle survives a transport outage and rejoins the same room');
  }
  await pause(40);
 }
 await client.fingers.release();s=await until(client.page,v=>v.expedition?.result,'touch battle terminal result');
 assert(s.expedition.result.won,'Only real joystick and skill touches may win');
 assert(s.touch_events>10&&s.drag_events>3,'Actual ScreenTouch and ScreenDrag events reached Godot');
 assert(usedSkills.size>=2,'Joystick and multiple skill pads were used');
 assert(observedStick&&observedBasic&&observedSpell,'Real touch capture and authoritative basic/spell cooldowns must be observed');
 assert(settingsChecked&&observed960,'Both landscape sizes must drive real combat, with settings safely releasing input');
 assert.notEqual(s.expedition.player.x,initialX,'Authoritative player moved');
 await client.page.screenshot({path:join(output,'touch-844-victory.png')});
 log('844×390 real multitouch joystick and skill-pad victory, authoritative reward received');
 return s;
}
try{
 await server.app.listen({host:'127.0.0.1',port:0});origins.push(server.app.listeningOrigin);
 const client=await openClient();
 await tapButton(client,'注册');
 await field(client,'3—32 位字母、数字或下划线','touch_alpha',true);
 await field(client,'请输入密码（至少 12 位）','touch-fixture-password');
 await field(client,'请再次输入密码','touch-fixture-password');
 await field(client,'自己的昵称','触屏行者');
 await tapButton(client,'注册并登录');
 await until(client.page,s=>s.remote&&s.ready,'touch registration and remote login');
 await tapButton(client,'进入我的角色');
 await tapButton(client,'五域游历 / 主线');
 await until(client.page,s=>s.story?.current_chapter_id==='wood','mobile story objective');
 await tapButton(client,'听取线索');
 let s=await state(client.page);while(s.buttons.some(b=>b.text==='继续'&&!b.disabled)){await tapButton(client,'继续');s=await state(client.page);}
 await tapButton(client,'记下线索');
 await until(client.page,s=>s.story?.chapters.find(c=>c.id==='wood')?.nodes[0].completed,'touch dialogue saved');
 const scrollBefore=await state(client.page),storyScroll=scrollBefore.scrolls.find(r=>r.maximum>r.page&&r.clip.height>100);
 assert(storyScroll,'Story contains a real scroll region');
 await swipe(client,storyScroll.clip,true);
 await until(client.page,v=>v.scrolls.some(r=>r.path===storyScroll.path&&r.value>storyScroll.value),'native touch scroll changed chapter viewport');
 await client.page.screenshot({path:join(output,'touch-story-scroll.png')});
 await tapButton(client,'前往本章秘境');
 await tapButton(client,'进入秘境');
 await fight(client);
 await tapButton(client,'返回秘境');
 await until(client.page,s=>s.equipment.qi===100&&s.equipment.inventory.length===1,'touch first-clear inventory');
 await tapButton(client,'装备与锻造');
 await tapButton(client,'祈愿装备');
 await tapButton(client,'祈愿一次',true);
 await until(client.page,s=>s.equipment.qi===30&&s.equipment.inventory.length===2,'touch reward-funded wish');
 await client.page.setViewportSize({width:960,height:540});await pause(400);
 await client.page.screenshot({path:join(output,'touch-960-wish.png')});
 await client.page.setViewportSize({width:430,height:844});await pause(300);
 assert.equal(await client.page.locator('#rotate').evaluate(node=>getComputedStyle(node).display),'block','Portrait must show a rotation hint');
 await client.page.screenshot({path:join(output,'touch-portrait-hint.png')});
 const audio=await client.page.evaluate(async()=>{
  let peak=0;
  for(let sample=0;sample<10;sample++){
   for(const analyser of window.__touchAudioAnalysers){const data=new Float32Array(analyser.fftSize);analyser.getFloatTimeDomainData(data);for(const value of data)peak=Math.max(peak,Math.abs(value));}
   await new Promise(resolve=>setTimeout(resolve,80));
  }
  return {gesture:navigator.userActivation.hasBeenActive,contexts:window.__touchAudioContexts.map(c=>c.state),analysers:window.__touchAudioAnalysers.length,peak};
 });
 assert(audio.gesture,'The run must use actual browser user gestures');
 assert(audio.contexts.includes('running')&&audio.peak>0.000001,'Gesture must unlock a running WebAudio context with real rendered audio samples');
 assert.equal(errors.length,0,JSON.stringify(errors));assert.equal(httpFailures.length,0,JSON.stringify(httpFailures));
 const final=await state(client.page);
 writeFileSync(join(output,'touch-online-report.json'),JSON.stringify({work,site,packHash,logs,errors,httpFailures,audio,final},null,2));
 log('Touch flow complete: registration/native keyboard, story scrolling, real battle, reward wish, two landscape sizes and portrait hint');
}catch(error){writeFileSync(join(work,'error.txt'),String(error.stack));throw error;}
finally{for(const context of contexts)await context.close();await server.app.close();}

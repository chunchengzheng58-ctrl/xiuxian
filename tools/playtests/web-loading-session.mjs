import {createRequire} from 'node:module';
import {readFileSync,writeFileSync,mkdirSync,linkSync,readdirSync,statSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const repo=resolve(import.meta.dirname,'../..'), site=resolve(process.argv[2]);
const out=resolve(repo,'../../work/loading-verification');mkdirSync(out,{recursive:true});
const root=join(out,'site'), version='web-'+'a'.repeat(40), dir=join(root,version);mkdirSync(dir,{recursive:true});
for(const name of readdirSync(site))if(statSync(join(site,name)).isFile()&&name!=='index.html')try{linkSync(join(site,name),join(dir,name))}catch{}
mkdirSync(join(dir,'loading'),{recursive:true});try{linkSync(join(site,'loading/title.png'),join(dir,'loading/title.png'))}catch{}
writeFileSync(join(root,'game-cache-sw.js'),readFileSync(join(site,'game-cache-sw.js')));
const control=readFileSync(join(repo,'tools/playtests/web-control.gd'),'utf8').replace('"field":','"logout-test":\n\t\t\tscene.account_api.logout()\n\t\t"field":');
const scene='[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://web-test.gd" id="1"]\n[node name="WebTest" type="Node"]\nscript = ExtResource("1")\n';
const files=[['/web-test.gd',control],['/override.cfg','[application]\nrun/main_scene="res://web-test.tscn"\n'],['/web-test.tscn',scene]];
const preload=files.map(([name,data])=>`await engine.preloadFile(Uint8Array.from(atob('${Buffer.from(data).toString('base64')}'),c=>c.charCodeAt(0)), '${name}');`).join('\n');
let html=readFileSync(join(site,'index.html'),'utf8').replace('<meta charset="utf-8">',`<meta charset="utf-8"><base href="/${version}/">`)
 .replace('prepareCache().then(() => engine.startGame({',`prepareCache().then(async () => {${preload} return engine.startGame({`)
 .replace('})).then(() => { finishOpening();','}); }).then(() => { finishOpening();');
writeFileSync(join(root,'index.html'),html);
const {buildApp}=await import(pathToFileURL(join(repo,'server/dist/src/app.js')));
const server=await buildApp({worker:false,web:{root},origins:[]});
const username='remember_fixture',password='remember-fixture-password-123';
await server.app.inject({method:'POST',url:'/api/v2/auth/register',payload:{username,password}});
await server.app.listen({host:'127.0.0.1',port:0});
const origin='http://127.0.0.1:'+server.app.server.address().port;
const require=createRequire(import.meta.url);const {chromium}=require('C:/Users/zcc36/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const browser=await chromium.launch({executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',args:['--enable-unsafe-swiftshader']});
const context=await browser.newContext({viewport:{width:1440,height:900}}),page=await context.newPage();let serial=0;const errors=[];page.on('console',m=>{if(m.text().includes('SCRIPT ERROR'))errors.push(m.text())});
const action=async data=>{const id=++serial;await page.evaluate(x=>{window.__gameResult=null;window.__gameRequest=JSON.stringify(x)},{id,...data});await page.waitForFunction(id=>{try{return JSON.parse(window.__gameResult)?.id===id}catch{return false}},id);return (await page.evaluate(()=>JSON.parse(window.__gameResult))).result};
const until=async expected=>{for(let i=0;i<150;i++){if((await action({op:'inspect'})).ready===expected)return;await page.waitForTimeout(100)}throw Error('Login readiness timeout: '+expected)};
const prefs=()=>page.evaluate(()=>JSON.parse(localStorage.getItem('xiuxian.login.v1')||'{}'));
try{
 await page.goto(origin);await page.waitForFunction(()=>window.__gameReady===true,null,{timeout:90000});
 await page.screenshot({path:join(out,'login-checkbox.png')});
 assert((await action({op:'click',text:'记住账号并保持登录（此设备）'})).ok);
 await action({op:'login',username,password});await until(true);
 let saved=await prefs();assert(saved.token);assert.equal(saved.username,username);assert(!JSON.stringify(saved).includes(password));
 await page.waitForFunction(async()=>{const c=await caches.open('xiuxian-game-resources-v1');return !!await c.match(new URL('index.pck',document.baseURI))});
 const count=await page.evaluate(async()=> (await (await caches.open('xiuxian-game-resources-v1')).keys()).length);assert(count>=2);
 await page.reload();await page.waitForFunction(()=>window.__gameReady===true,null,{timeout:90000});await until(true);
 assert.equal((await prefs()).token,saved.token);console.log('PASS remembered session restores after reload; no plaintext password saved');
 await action({op:'logout-test'});await until(false);assert.equal((await prefs()).token,'');
 await action({op:'click',text:'记住账号并保持登录（此设备）'});
 await action({op:'login',username,password});await until(true);assert.equal((await prefs()).token,'');console.log('PASS explicit logout and unchecked remember clear saved session');
 await action({op:'logout-test'});await until(false);
 await action({op:'click',text:'记住账号并保持登录（此设备）'});await action({op:'login',username,password});await until(true);saved=await prefs();
 assert.equal((await server.app.inject({method:'POST',url:'/api/v2/auth/logout',payload:{},headers:{authorization:'Bearer '+saved.token}})).statusCode,200);
 await page.reload();await page.waitForFunction(()=>window.__gameReady===true,null,{timeout:90000});await page.waitForTimeout(1500);await until(false);assert.equal((await prefs()).token,'');console.log('PASS expired/revoked session requires login');
 await context.setOffline(true);
 const offline=await page.evaluate(async()=>{const r=await fetch(new URL('index.pck',document.baseURI));return {ok:r.ok,size:(await r.arrayBuffer()).byteLength}});assert(offline.ok);assert.equal(offline.size,statSync(join(site,'index.pck')).size);console.log('PASS complete PCK served from cache with network offline');
 assert.deepEqual(errors,[]);console.log('ALL LOADING AND REMEMBER-LOGIN CHECKS PASSED');
}finally{await browser.close();await server.app.close()}

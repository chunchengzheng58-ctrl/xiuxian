import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {mkdirSync,mkdtempSync,existsSync,readFileSync,unlinkSync,writeFileSync,linkSync,cpSync,symlinkSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {join,dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const project=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const folder=resolve(process.argv[2]??join(project,'../../outputs/commercial-preview/windows'));
const base=join(project,'work/windows-build/tests');mkdirSync(base,{recursive:true});
const work=mkdtempSync(join(base,'desktop-'));
const testPackage=join(work,'package');mkdirSync(testPackage);
for(const file of ['Xiuxian.exe','Xiuxian.pck'])linkSync(join(folder,file),join(testPackage,file));
for(const file of ['desktop.mjs','Play.vbs','manifest.json'])cpSync(join(folder,file),join(testPackage,file));
for(const directory of ['runtime','server','data'])symlinkSync(join(folder,directory),join(testPackage,directory),'junction');
const packHash=createHash('sha256').update(readFileSync(join(folder,'Xiuxian.pck'))).digest('hex');
cpSync(join(project,'tools/pack-windows.login.gd'),join(testPackage,'desktop-test.gd'));
writeFileSync(join(testPackage,'desktop-test.tscn'),'[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://desktop-test.gd" id="1"]\n[node name="DesktopReleaseTest" type="Node"]\nscript = ExtResource("1")\n');
writeFileSync(join(testPackage,'override.cfg'),'[application]\nrun/main_scene="res://desktop-test.tscn"\n');
mkdirSync(join(work,'temp'),{recursive:true});
const env={...process.env,TEMP:join(work,'temp'),TMP:join(work,'temp'),XIUXIAN_DESKTOP_DATA:join(work,'data'),XIUXIAN_PACK_TEST_WORK:work,
 XIUXIAN_PACK_TEST_CAPTURE:join(folder,'windows-login.png'),XIUXIAN_GAME_ARGS_JSON:JSON.stringify([
 '--position','-12000,-12000','--','--skip-intro','--kernel-ephemeral'])};
async function waitFor(check,timeout=25000){const end=Date.now()+timeout;while(Date.now()<end){const value=check();if(value)return value;await new Promise(res=>setTimeout(res,100));}throw new Error('Desktop smoke timed out');}
function service(){
 const child=spawn(join(testPackage,'runtime/node.exe'),[join(testPackage,'desktop.mjs'),'--service-test'],{cwd:testPackage,env,windowsHide:true,stdio:['ignore','pipe','pipe']});
 let output='';child.stdout.on('data',chunk=>output+=chunk);child.stderr.on('data',chunk=>output+=chunk);
 child.once('exit',code=>{if(code)console.error(output);});
 return {child,hello:()=>{const line=output.split('\n').find(line=>line.startsWith('{"ok":true'));return line?JSON.parse(line):null;},output:()=>output};
}
async function api(port,path,body,token){
 const response=await fetch(`http://127.0.0.1:${port}`+path,{method:body?'POST':'GET',headers:{...(body?{'content-type':'application/json'}:{}),...(token?{authorization:'Bearer '+token}:{})},body:body?JSON.stringify(body):undefined});
 const result=await response.json();assert.equal(response.status,200,JSON.stringify(result));assert.equal(result.ok,true);return result.data;
}
let identity;
for(let run=0;run<2;run++){
 env.XIUXIAN_PACK_REGISTER=run===0?'1':'0';
 const launched=spawn('wscript.exe',['//nologo',join(testPackage,'Play.vbs')],{cwd:testPackage,env,windowsHide:true});
 let wscriptExit;
 launched.once('exit',code=>{wscriptExit=code;});
 try{
  const statePath=join(work,'data/desktop-session.json');
  const hello=await waitFor(()=>{try{return JSON.parse(readFileSync(statePath,'utf8'));}catch{return null;}});
  assert.equal(hello.root,testPackage);assert.notEqual(hello.port,8080);assert.equal((await api(hello.port,'/healthz')).service,'xiuxian');
  const second=service();
  const reused=await waitFor(second.hello);assert.equal(reused.pid,hello.pid);assert.equal(reused.port,hello.port,'Only the verified service for this data folder is reused');
  const resultPath=join(work,'login-result.json');
  const result=await waitFor(()=>{try{return existsSync(resultPath)?JSON.parse(readFileSync(resultPath,'utf8')):null;}catch{return null;}});
  assert.equal(result.ok,true);assert.equal(result.remote,true);assert.equal(result.saved,true);
  if(identity)assert.equal(result.cultivator_id,identity);identity=result.cultivator_id;
  const login=await api(hello.port,'/api/v2/auth/login',{username:'desktop_player',password:'desktop-fixture-password'});
  const snapshot=await api(hello.port,'/api/v2/commands',{version:1,command:'growth.list',payload:{}},login.token);
  assert.equal(snapshot.cultivators.filter(actor=>actor.role==='self').length,1);
  assert.equal(snapshot.cultivators[0].cultivator_id,identity);
  if(env.XIUXIAN_PACK_CAMPAIGN==='1'){
   assert.equal(result.campaign,true,'Delivered PCK must open real campaign UI and save its intro');
   const story=await api(hello.port,'/api/v2/commands',{version:1,command:'story.snapshot',payload:{cultivator_id:identity}},login.token);
   const lobby=await api(hello.port,'/api/v2/commands',{version:1,command:'combat.expedition_lobby',payload:{cultivator_id:identity}},login.token);
   assert.equal(lobby.stages.length,20);assert.equal(lobby.adventure.level,1);
   assert.equal(story.chapters.find(chapter=>chapter.id==='wood').nodes.find(node=>node.id==='wood.intro').completed,true);
  }
  await waitFor(()=>wscriptExit!==undefined,12000);assert.equal(wscriptExit,0);
  unlinkSync(resultPath);
  console.log('WINDOWS_RELEASE_SMOKE PASS '+(run?'direct cold VBS restart, persisted account login and save':'first direct cold VBS launch, actual UI registration, login and save'));
 }catch(error){launched.kill();throw error;}
}
assert.equal(createHash('sha256').update(readFileSync(join(folder,'Xiuxian.pck'))).digest('hex'),packHash);
assert.equal(existsSync(join(folder,'override.cfg')),false);
for(const[name,args]of [['backup.js',[join(work,'data/server/var/game.sqlite'),join(work,'pack-backup.sqlite')]],
 ['restore.js',[join(work,'pack-backup.sqlite'),join(work,'restored/game.sqlite')]]]){
 const checked=spawnSync(join(folder,'runtime/node.exe'),[join(folder,'server/dist/tools',name),...args],{cwd:folder,env,windowsHide:true,encoding:'utf8',timeout:20000});
 assert.equal(checked.status,0,checked.stdout+checked.stderr);
}
const failed=join(work,'missing-game-package');mkdirSync(failed);
for(const file of ['desktop.mjs','manifest.json'])cpSync(join(folder,file),join(failed,file));
for(const directory of ['runtime','server','data'])symlinkSync(join(folder,directory),join(failed,directory),'junction');
const failedData=join(work,'missing-game-data');
const failure=spawnSync(join(failed,'runtime/node.exe'),[join(failed,'desktop.mjs')],{cwd:failed,env:{...env,XIUXIAN_DESKTOP_DATA:failedData},windowsHide:true,encoding:'utf8',timeout:20000});
assert.equal(failure.status,1);
const fatalLog=readFileSync(join(failedData,'logs/desktop.log'),'utf8');
assert(fatalLog.includes('Xiuxian.exe is missing')&&fatalLog.includes('Startup failed')&&fatalLog.includes('Fatal'),'Fatal startup diagnostics must persist even with hidden stderr');
writeFileSync(join(work,'verification.json'),JSON.stringify({passed:true,package:folder,dataRoot:env.XIUXIAN_DESKTOP_DATA,cultivatorId:identity,pckSha256:packHash,backupRestoreCli:true,serviceReuse:true,coldDirectVbs:true,fatalLogging:true,campaign:env.XIUXIAN_PACK_CAMPAIGN==='1',scope:'Official Windows release exe; bundled Node and production server; first direct cold VBS/UI registration/login/save, second direct cold VBS/login after backend restart; no --service-test prewarming. Campaign mode also opens production story UI, clicks through and saves the wood intro, checks 20 stages and level projection, then confirms saved intro after cold restart. A loose override.cfg/test scene exists only in the isolated test package; production PCK bytes are unchanged and delivered package has no override.'},null,2));
console.log('WINDOWS_RELEASE_SMOKE 0 failures '+work);

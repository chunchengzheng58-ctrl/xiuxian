import {readFileSync,writeFileSync,readdirSync,statSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
const project=resolve(fileURLToPath(new URL('.',import.meta.url)),'../..');
const site=process.env.XIUXIAN_WEB_SITE??resolve(project,'../../outputs/commercial-preview/web');
const work=process.env.XIUXIAN_WEB_WORK??resolve(project,'../commercial-verification/web-export');
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const files=readdirSync(site).filter(name=>name.startsWith('index.')).sort().map(name=>({name,bytes:statSync(join(site,name)).size,sha256:hash(readFileSync(join(site,name)))}));
const paths=[...new Set(execFileSync('git',['ls-files','-c','-o','--exclude-standard','-z'],{cwd:project,encoding:'utf8'}).split('\0'))].filter(name=>/^(scripts\/|scenes\/|assets\/|data\/|web\/)/.test(name)||['project.godot','export_presets.cfg','icon.svg'].includes(name)).sort();
const sourceHashes=paths.map(name=>({name,sha256:hash(readFileSync(join(project,name)))}));
const pending=process.argv.includes('--pending');
if(!pending){
 const identified=JSON.parse(readFileSync(join(site,'manifest.json'),'utf8'));
 assert.equal(identified.runtimeSourceFingerprint,hash(JSON.stringify(sourceHashes)),'Runtime sources must not change after export');
 assert.deepEqual(identified.files,files,'Exported files must not change during validation');
}
let validation={state:'pending'};
if(!pending){
 const audit=JSON.parse(readFileSync(join(work,'pack-audit.json'),'utf8'));
 const browser=JSON.parse(readFileSync(join(work,'browser-smoke-final.json'),'utf8'));
 const online=JSON.parse(readFileSync(process.env.XIUXIAN_WEB_ONLINE_REPORT??resolve(project,'../../outputs/commercial-preview/web-online/web-online-report.json'),'utf8'));
 assert.equal(audit.failures,0);assert.equal(browser.errors.length,0);assert.equal(browser.failed.length,0);assert.equal(browser.badResponses.length,0);
 assert.equal(audit.pck_sha256,files.find(f=>f.name==='index.pck').sha256,'PCK audit must identify this exact export');
 assert.equal(online.errors.length,0);assert.equal(online.httpFailures.length,0);
 assert.equal(online.unexpectedNetworkFailures.length,0);
 assert.equal(online.expectedNetworkFaults.filter(f=>f.kind==='request').length,1,'Only the intentionally dropped draw response is expected');
 assert.equal(online.pckHash,files.find(f=>f.name==='index.pck').sha256);
 assert(online.logs.some(line=>typeof line==='string'&&line.includes('1012/988')),'Public ranked Web path must be verified');
 assert(online.logs.some(line=>typeof line==='string'&&line.includes('Wish response intentionally dropped')),'Committed wish recovery after refresh must be verified');
 let touch;
 if(process.env.XIUXIAN_WEB_TOUCH_REPORT){
  touch=JSON.parse(readFileSync(process.env.XIUXIAN_WEB_TOUCH_REPORT,'utf8'));
  assert.equal(touch.packHash,files.find(f=>f.name==='index.pck').sha256,'Touch test must identify this exact export');
  assert.equal(touch.errors.length,0);assert.equal(touch.httpFailures.length,0);
  assert(touch.audio.contexts.includes('running')&&touch.audio.peak>0.000001,'Real user gesture must unlock nonzero browser audio');
  assert(touch.logs.some(line=>line.includes('online battle keeps ticking')),'Settings must release real touch controls while battle continues');
  assert(touch.logs.some(line=>line.includes('Touch flow complete')),'Complete real touch flow must pass');
 }
 validation={state:'passed',cleanImport:'passed',releaseExport:'passed',packAuditFailures:0,packResourceCount:audit.file_count,
  browser:'Unmodified release HTML: desktop login/guest/wish/corridor and mobile native input/keyboard resize; test-only virtual Node harness: two production-PCK online clients',
  online:['new player PVE victory','actual WebSocket loss/reconnecting/frozen health/same-room recovery','reward-funded wish','committed wish response dropped, pending recovery after refresh/login, original item and one debit','equip/upgrade/unequip','upgraded school equipment trade across two accounts','friend request/accept/private message','friendly PVP knockout and history','ranked queue/cancel/requeue/auto-enter/knockout/exact rating and leaderboard'],
  runtimeErrors:0,unexpectedNetworkFailures:online.unexpectedNetworkFailures.length,expectedDrawResponseFailures:online.expectedNetworkFaults.filter(f=>f.kind==='request').length,expectedFaultConsoleMessages:online.expectedNetworkFaults.filter(f=>f.kind==='console').length,httpFailures:online.httpFailures.length,
  testHarness:'Only temporary test HTML and WASM virtual FS; release PCK and delivered HTML contain no test bridge',
  excluded:['editor plugin and helper autoload','health sample images','server','work','output','outputs','tests','tools','docs'],
  scope:'Local release Web client and listed online gameplay are verified; public deployment, weak-network performance, prolonged operations and independent desktop installer are not certified.'};
 if(touch)validation.mobile={device:'Edge mobile emulation with actual CDP multi-touch, not physical hardware',viewports:['844×390','960×540','430×844 portrait hint'],paths:['registration and native input/keyboard resize','touch mainline dialogue and scroll','multitouch joystick and skill battle with authoritative first-clear victory','settings releases fingers while authority continues','actual transport outage and same-room recovery','reward-funded wish','real gesture unlock and nonzero WebAudio samples'],runtimeErrors:0,audioPeak:touch.audio.peak};
}
const manifest={format:'xiuxian-web-preview-v2',builtAt:new Date().toISOString(),godot:'4.7.2.stable.official.ed1daf0bf',sourceCommit:execFileSync('git',['rev-parse','HEAD'],{cwd:project,encoding:'utf8'}).trim(),uncommittedSource:true,runtimeSourceFingerprint:hash(JSON.stringify(sourceHashes)),runtimeSourceFileCount:sourceHashes.length,files,totalExportBytes:files.reduce((total,f)=>total+f.bytes,0),validation};
writeFileSync(join(site,'manifest.json'),JSON.stringify(manifest,null,2)+'\n');
writeFileSync(join(work,'runtime-source-hashes.json'),JSON.stringify(sourceHashes,null,2)+'\n');
console.log(JSON.stringify({state:validation.state,pckHash:files.find(f=>f.name==='index.pck').sha256,sourceFiles:sourceHashes.length,totalExportBytes:manifest.totalExportBytes}));

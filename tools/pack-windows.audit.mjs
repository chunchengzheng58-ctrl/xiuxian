import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,readdirSync,statSync,existsSync} from 'node:fs';
import {resolve,dirname,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const project=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const folder=resolve(process.argv[2]??join(project,'../../outputs/commercial-preview/windows'));
const work=join(project,'work/windows-build');
const hash=path=>createHash('sha256').update(readFileSync(path)).digest('hex');
const manifest=JSON.parse(readFileSync(join(folder,'manifest.json'),'utf8'));
for(const file of manifest.files)if(file.name!=='windows-login.png')assert.equal(hash(join(folder,file.name)),file.sha256,'Package file changed: '+file.name);
assert.equal(existsSync(join(folder,'override.cfg')),false);
assert(!manifest.files.some(file=>file.name.startsWith('data-save/')),'Player data must never enter the published payload');
assert(!manifest.files.some(file=>/(^|\/)(\.env|desktop-test\.|game\.sqlite)/.test(file.name)));
const candidates=readdirSync(join(work,'tests'),{withFileTypes:true}).filter(item=>item.isDirectory()&&existsSync(join(work,'tests',item.name,'verification.json')))
 .map(item=>join(work,'tests',item.name,'verification.json')).sort((a,b)=>statSync(b).mtimeMs-statSync(a).mtimeMs);
const verification=JSON.parse(readFileSync(process.argv[3]??candidates[0],'utf8'));
assert.equal(verification.passed,true);assert.equal(verification.package,folder);
assert.equal(verification.pckSha256,hash(join(folder,'Xiuxian.pck')));
assert.equal(verification.backupRestoreCli,true);assert.equal(verification.serviceReuse,true);
assert.equal(verification.coldDirectVbs,true,'The first VBS launch must be tested without a warmed-up service');
const auditPath=process.argv[4]??join(work,'pack-audit.json');
const pckAudit=JSON.parse(readFileSync(auditPath,'utf8'));assert.equal(pckAudit.passed,true);
if(verification.campaign){
 assert.equal(pckAudit.pckSha256,verification.pckSha256,'Campaign PCK inspection must identify this exact binary');
 assert.equal(pckAudit.campaignRulesSha256,hash(join(folder,'data/adventure-campaign.v1.json')),'Client and server must use the same tested campaign rules');
 for(const name of ['CAMPAIGN_PLAYTEST.md','PLAYTEST_GUIDE.md'])assert(existsSync(join(folder,'docs',name)),'Player guide missing: '+name);
}
const bootPath=process.argv[5]??join(work,'normal-boot.log');
const boot=readFileSync(bootPath,'utf8');assert(boot.includes('OpenGL'));assert(!/SCRIPT ERROR|ERROR:/.test(boot));
manifest.runtimeSourceScope='scripts/, scenes/, assets/, data/, project.godot, icon.svg; excludes web/ and shared export_presets.cfg; isolated Windows platform preset';
manifest.validation={officialReleaseTemplateVersion:'4.7.2.stable.official.ed1daf0bf',normalMainSceneBoot:'passed without overrides',
 releaseUiLoginAndSave:'passed first direct cold VBS launch with UI registration, then another cold launch/login after backend restart; same remote cultivator',serviceIdentityReuse:'passed; random non-8080 local port',backupRestoreCli:'passed using bundled runtime/tools',fatalStartupLogging:'passed with naturally missing game executable',
 pckTreasureMethods:['refresh_wish_controls','wish_projection_signature'],pckAudit:'passed',pckSha256:verification.pckSha256,
 testControl:'A loose override.cfg/test scene was present only in an isolated test-package copy. It instantiated the unchanged production PCK main scene; delivered package contains no overrides.',
 scope:'Native release startup/login/save/restart/launcher/backup CLI validation. Full native multiplayer/weak-network/long-duration certification is not implied.'};
if(verification.campaign)manifest.validation.campaign={version:'adventure-campaign-v1',formalStages:20,adventureLevels:30,
 campaignRulesSha256:pckAudit.campaignRulesSha256,pckScriptInspection:'passed; story UI/module, all twenty stages, thirty levels, final boss pacing and story commands present',
 storyUiColdRestart:'passed; wood intro read and saved through production UI, persisted after a cold restart',auditPath,bootPath};
const screenshot='windows-login.png';
manifest.files=manifest.files.filter(file=>file.name!==screenshot);
manifest.files.push({name:screenshot,bytes:statSync(join(folder,screenshot)).size,sha256:hash(join(folder,screenshot))});
writeFileSync(join(folder,'manifest.json'),JSON.stringify(manifest,null,2));
writeFileSync(join(work,'final-package-audit.json'),JSON.stringify({passed:true,files:manifest.files.length,bytes:manifest.files.reduce((n,file)=>n+file.bytes,0),pckSha256:verification.pckSha256,verificationPath:process.argv[3]??candidates[0]},null,2));
console.log('WINDOWS_PACKAGE_AUDIT PASS '+manifest.files.length+' files');

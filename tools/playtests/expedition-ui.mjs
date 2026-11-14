import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {mkdirSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const scripts=fileURLToPath(new URL('.',import.meta.url));
const project=process.argv[2]??resolve(scripts,'../..');
const output=process.argv[3]??join(project,'outputs/playtests');
const work=join(project,'work/playtests');
const state=join(work,'expedition-'+randomUUID());
mkdirSync(state,{recursive:true});
mkdirSync(output,{recursive:true});
const {buildApp}=await import(pathToFileURL(join(project,'server/dist/src/app.js')));
const server=await buildApp({worker:false,randomInt:()=>0});
try{
 const credentials={username:'explorer',password:'explorer-fixture-password'};
 assert.equal((await server.app.inject({method:'POST',url:'/api/v2/auth/register',payload:credentials})).statusCode,200);
 const session=(await server.app.inject({method:'POST',url:'/api/v2/auth/login',payload:credentials})).json().data;
 const actor=server.game.execute(session.account_id,'growth.create_member',{role:'self',name:'林间客',profile:{title:'林间客',avatar:'female'},request_id:randomUUID()}).cultivator_id;
 const original=server.game.characterSnapshot(session.account_id,actor);
 assert.equal(original.initial_score,null);
 assert.equal(original.equipment.length,0);
 await server.app.listen({host:'127.0.0.1',port:0});
 const child=spawn(process.env.GODOT4_CONSOLE??'D:/Projects/Codex/tools/godot-4.7.2/Godot_v4.7.2-stable_win64_console.exe',
  ['--path',project,'--rendering-method','gl_compatibility','--script',join(scripts,'expedition-ui.gd'),'--log-file',join(state,'client.log'),'--','--kernel-ephemeral','--skip-intro'],
  {windowsHide:true,env:{...process.env,APPDATA:join(work,'godot-data'),XIUXIAN_BACKEND_URL:server.app.listeningOrigin,XIUXIAN_EXPEDITION_WORK:state,XIUXIAN_EXPEDITION_OUTPUT:output},stdio:['ignore','inherit','inherit']});
 const timeout=setTimeout(()=>child.kill(),220000);
 const code=await new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject)}).finally(()=>clearTimeout(timeout));
 assert.equal(code,0,'Rendered new-player expedition flow');
 const final=server.game.characterSnapshot(session.account_id,actor);
 assert.equal(final.initial_score,50);
 assert.equal(final.initial_profile_id,'adventurer-default-v1');
 assert.equal(server.db.get('SELECT COUNT(*) AS count FROM baselines WHERE cultivator_id=?',actor).count,0,'Adventure does not fabricate health baselines');
 assert(final.equipment.length>=2,'Combat reward equipment plus a real wish');
 assert(final.draw_count>=1,'Wish succeeds after adventuring');
 console.log('EXPEDITION_UI_SERVER: real new-player account, authoritative boss victory, reward equipment, progression and wish without a health baseline');
}finally{await server.app.close();}

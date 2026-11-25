import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {mkdirSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const scripts=fileURLToPath(new URL('.',import.meta.url));
const project=process.argv[2]??resolve(scripts,'../..');
const output=process.argv[3]??join(project,'outputs/playtests');
const state=join(project,'work/playtests','matchmaking-'+randomUUID());
mkdirSync(state,{recursive:true});
mkdirSync(output,{recursive:true});
const {buildApp}=await import(pathToFileURL(join(project,'server/dist/src/app.js')));
const server=await buildApp({worker:false});
const accounts=[];
async function create(username,avatar){
 const credentials={username,password:'matchmaking-fixture-password'};
 assert.equal((await server.app.inject({method:'POST',url:'/api/v2/auth/register',payload:credentials})).statusCode,200);
 const session=(await server.app.inject({method:'POST',url:'/api/v2/auth/login',payload:credentials})).json().data;
 const actor=server.game.execute(session.account_id,'growth.create_member',{role:'self',name:'不公开的角色名',profile:{title:'本人',avatar},request_id:randomUUID()}).cultivator_id;
 accounts.push({account:session.account_id,id:actor});
}
function client(role){
 const child=spawn(process.env.GODOT4_CONSOLE??'D:/Projects/Codex/tools/godot-4.7.2/Godot_v4.7.2-stable_win64_console.exe',
  ['--path',project,'--rendering-method','gl_compatibility','--script',join(scripts,'matchmaking-ui.gd'),'--log-file',join(state,role+'.log'),'--','--kernel-ephemeral','--skip-intro'],
  {windowsHide:true,env:{...process.env,APPDATA:join(state,'appdata'),XIUXIAN_BACKEND_URL:server.app.listeningOrigin,XIUXIAN_MATCHMAKING_ROLE:role,XIUXIAN_MATCHMAKING_WORK:state,XIUXIAN_MATCHMAKING_OUTPUT:output},stdio:['ignore','inherit','inherit']});
 const timeout=setTimeout(()=>child.kill(),90000);
 return new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject)}).finally(()=>clearTimeout(timeout));
}
try{
 await create('queuealpha','male');
 await create('queuebeta','female');
 await server.app.listen({host:'127.0.0.1',port:0});
 assert.deepEqual(await Promise.all([client('queuealpha'),client('queuebeta')]),[0,0]);
 const lobbies=accounts.map(actor=>server.game.execute(actor.account,'combat.matchmaking_lobby',{cultivator_id:actor.id}));
 assert.equal(lobbies[0].rating.wins,1);
 assert.equal(lobbies[1].rating.losses,1);
 assert.equal(lobbies[0].rating.rating,1012);
 assert.equal(lobbies[1].rating.rating,988);
 for(const lobby of lobbies){
  assert.equal(lobby.recent.length,1);
  assert.equal(lobby.recent[0].mode,'ranked');
  assert.equal(lobby.recent[0].reason,'knockout');
  assert.equal(lobby.leaderboard.length,30);
  assert.ok(lobby.leaderboard.some(entry=>entry.alias!=='松风'&&entry.alias!=='云栖'&&entry.play_days>0));
  assert.equal(lobby.queue,null);
  assert.equal(lobby.active,null);
 }
 assert.equal(lobbies[0].recent[0].rating_delta,12);
 assert.equal(lobbies[1].recent[0].rating_delta,-12);
 assert.equal(lobbies[0].leaderboard[0].alias,'松风');
 assert.equal(server.db.get('SELECT COUNT(*) AS count FROM social_relations').count,0,'Public PvP needs no friend relationship');
 assert.equal(server.db.get('SELECT COUNT(*) AS count FROM arena_duels').count,1,'Cancel and retry create only one actual match');
 console.log('MATCHMAKING_UI_SERVER: two fresh players, public aliases, cancel/rejoin, automatic entry, reconnect, authoritative knockout, exact one-time ratings and leaderboard without adding friends');
}finally{await server.app.close();}

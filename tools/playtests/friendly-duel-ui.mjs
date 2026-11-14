import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';
const scripts = fileURLToPath(new URL('.', import.meta.url));
const project = process.argv[2] ?? resolve(scripts, '../..');
const output = process.argv[3] ?? join(project, 'outputs/playtests');
const work = join(project, 'work/playtests');
const state = join(work, 'duel-' + randomUUID());
mkdirSync(state, {recursive:true});
mkdirSync(output, {recursive:true});
const { buildApp } = await import(pathToFileURL(join(project, 'server/dist/src/app.js')));
const server = await buildApp({ worker: false });
const password = 'duel-fixture-password';
async function player(username, alias, avatar) {
  const credentials = { username, password };
  assert.equal((await server.app.inject({ method: 'POST', url: '/api/v2/auth/register', payload: credentials })).statusCode, 200);
  const session = (await server.app.inject({ method: 'POST', url: '/api/v2/auth/login', payload: credentials })).json().data;
  const character = server.game.execute(session.account_id, 'growth.create_member', { role: 'self', name: alias, profile: { title: alias, avatar }, request_id: randomUUID() }).cultivator_id;
  server.game.execute(session.account_id, 'social.profile', {cultivator_id: character, alias, rotate_code:false}, randomUUID());
  return {account: session.account_id, id: character};
}
function client(role) {
  const child = spawn(process.env.GODOT4_CONSOLE ?? 'D:/Projects/Codex/tools/godot-4.7.2/Godot_v4.7.2-stable_win64_console.exe',
    ['--path', project, '--rendering-method', 'gl_compatibility', '--script', join(scripts, 'friendly-duel-ui.gd'),
      '--log-file', join(state, role + '.log'), '--', '--kernel-ephemeral', '--skip-intro'],
    { windowsHide:true, env:{...process.env, APPDATA:join(work,'godot-data'), XIUXIAN_BACKEND_URL:server.app.listeningOrigin,
      XIUXIAN_DUEL_ROLE:role, XIUXIAN_DUEL_WORK:state, XIUXIAN_DUEL_OUTPUT:output}, stdio:['ignore','inherit','inherit'] });
  const timer = setTimeout(() => child.kill(), 60000);
  return new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject)}).finally(()=>clearTimeout(timer));
}
try {
  const alpha = await player('alpha','松风','male');
  const beta = await player('beta','云栖','female');
  const code = server.game.execute(beta.account,'social.home',{cultivator_id:beta.id}).profile.invite_code;
  server.game.execute(alpha.account,'social.invite',{cultivator_id:alpha.id,invite_code:code},randomUUID());
  const relation = server.game.execute(beta.account,'social.home',{cultivator_id:beta.id}).requests[0].relation_id;
  server.game.execute(beta.account,'social.respond',{cultivator_id:beta.id,relation_id:relation,action:'accept'},randomUUID());
  await server.app.listen({host:'127.0.0.1',port:0});
  const codes = await Promise.all([client('alpha'),client('beta')]);
  assert.deepEqual(codes,[0,0]);
  const rows = server.db.all('SELECT * FROM arena_duels');
  assert.equal(rows.length,1);
  assert.equal(rows[0].status,'finished');
  assert.equal(rows[0].reason,'knockout');
  assert.equal(rows[0].winner,0);
  assert.equal(rows[0].opponent_hp,0);
  assert.equal(rows[0].mode,'friendly');
  assert.equal(rows[0].challenger_rating_after,null);
  assert.equal(rows[0].opponent_rating_after,null);
  console.log('DUEL_UI_SERVER: two clients, invite, acceptance, real combat and authoritative knockout');
} finally {await server.app.close();}

import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import test, { type TestContext } from 'node:test';
import { buildApp } from '../src/app.js';
import { repositoryRoot } from '../src/contracts.js';
import { secret } from '../src/core.js';
import { ArenaService, type ArenaSubscription } from '../src/game/arena.js';
import { fixture } from './helpers.js';

async function players(context: TestContext) {
  const app = await fixture(context);
  const create = async (username: string, alias: string | null) => {
    const session = await app.account(username);
    const actor = await app.command(session.token, 'growth.create_member', {role:'self',name:'私人角色',profile:{title:'私人称号',avatar:'female'},request_id:secret()});
    const id = actor.cultivator_id as string;
    const send = (command: string, fields: object = {}, key = secret()) => app.command(session.token, command, {cultivator_id:id,...fields},key);
    const request = (command: string, fields: object = {}) => app.request('/api/v2/commands',{version:1,command,payload:{cultivator_id:id,...fields}},session.token,'POST',secret());
    if (alias) await send('social.profile',{alias,rotate_code:false});
    return {...session,id,send,request};
  };
  const left = await create('rank_left','松风');
  const right = await create('rank_right','云栖');
  return {app,left,right,create};
}

type Setup = Awaited<ReturnType<typeof players>>;
async function pair(setup: Setup) {
  const {app,left,right}=setup;
  await left.send('combat.matchmaking_join');
  await right.send('combat.matchmaking_join');
  const lobby = await left.send('combat.matchmaking_lobby');
  const matchId = lobby.active.match_id as string;
  const first=app.game.arena.subscribe(left.account_id,matchId);
  const second=app.game.arena.subscribe(right.account_id,matchId);
  return {matchId,first,second};
}
function enter(app: Setup['app'], first: ArenaSubscription, second: ArenaSubscription) {
  app.game.arena.connect(first,true);
  app.game.arena.connect(second,true);
  app.game.arena.step(50);
  assert.equal(app.game.arena.state(first)!.phase,'fighting');
}
function knockout(app: Setup['app'], first: ArenaSubscription, second: ArenaSubscription) {
  enter(app,first,second);
  for(let tick=1;tick<1500;tick++){
    const state=app.game.arena.state(first)!;
    if(state.result) return state;
    const own=state.players[first.seat]!, enemy=state.players[second.seat]!;
    const dx=enemy.x-own.x,dy=enemy.y-own.y,distance=Math.hypot(dx,dy);
    app.game.arena.input(first,{seq:tick,x:distance>85?dx/Math.max(1,distance):0,y:distance>85?dy/Math.max(1,distance):0,action:distance<120?1:2});
    app.game.arena.step(1);
  }
  throw new Error('Authoritative combat did not end');
}

test('公开匹配：无好友也能排队、重试不续期、双方进入相同的权威对局并一次计分',async context=>{
  const setup=await players(context),{app,left,right}=setup;
  const initial=await left.send('combat.matchmaking_lobby');
  assert.equal(initial.rating.rating,1000);
  assert.equal(initial.rating.rank,null);
  const queued=await left.send('combat.matchmaking_join',{},'join-left');
  assert.equal(queued.queue.expires_at,app.now()+15);
  assert.equal(app.game.snapshot(left.account_id).duel.queued,true);
  app.advance(2);
  const retry=await left.send('combat.matchmaking_join');
  assert.equal(retry.queue.expires_at,queued.queue.expires_at);
  assert.deepEqual(await left.send('combat.matchmaking_join',{},'join-left'),queued);
  const matched=await right.send('combat.matchmaking_join');
  const matchId=matched.active.match_id;
  assert.equal((await left.send('combat.matchmaking_lobby')).active.match_id,matchId);
  assert.equal(app.game.snapshot(left.account_id).duel.active_mode,'ranked');
  assert.equal(app.game.snapshot(left.account_id).duel.queued,false);
  assert.equal((await left.send('combat.matchmaking_cancel')).active.match_id,matchId,'Late queue cancellation cannot destroy a committed match');
  const first=app.game.arena.subscribe(left.account_id,matchId),second=app.game.arena.subscribe(right.account_id,matchId);
  const result=knockout(app,first,second);
  assert.equal(result.mode,'ranked');
  assert.equal(result.result!.winner,first.seat);
  assert.equal(result.result!.reason,'knockout');
  assert.deepEqual(result.rating_change,{before:1000,after:1012,delta:12});
  const before=await left.send('combat.matchmaking_lobby');
  assert.deepEqual(before.rating,{rating:1012,wins:1,losses:0,draws:0,rank:1});
  assert.deepEqual((await right.send('combat.matchmaking_lobby')).rating,{rating:988,wins:0,losses:1,draws:0,rank:2});
  for(let retry=0;retry<3;retry++){
    await left.send('combat.duel_leave',{match_id:matchId});
    app.game.arena.step(10);
  }
  assert.deepEqual((await left.send('combat.matchmaking_lobby')).rating,before.rating);
  app.advance(16);app.game.arena.step(1);
  assert.deepEqual(app.game.arena.state(second)!.rating_change,{before:1000,after:988,delta:-12});
  const serialized=JSON.stringify(before.leaderboard);
  assert(serialized.includes('松风')&&serialized.includes('云栖'));
  assert(!serialized.includes('私人')&&!serialized.includes('rank_left')&&!serialized.includes('cultivator_'));
  assert.deepEqual(app.db.all("SELECT * FROM ledger WHERE reason LIKE 'duel_%' OR reason LIKE 'ranked_%'"),[]);
});

test('公开匹配：缺名片与角色归属拒绝，排队阻止PVE/好友约战，取消和超时可恢复',async context=>{
  const {app,left,right,create}=await players(context);
  const anonymous=await create('no_rank_profile',null);
  assert.equal((await anonymous.request('combat.matchmaking_join')).body.code,'SOCIAL_PROFILE_REQUIRED');
  assert.equal((await left.request('combat.matchmaking_lobby',{cultivator_id:right.id})).body.code,'NOT_FOUND');
  const home=await right.send('social.home');
  await left.send('social.invite',{invite_code:home.profile.invite_code});
  const relation=(await right.send('social.home')).requests[0].relation_id;
  await right.send('social.respond',{relation_id:relation,action:'accept'});
  await left.send('combat.matchmaking_join');
  assert.equal((await left.request('combat.expedition_start',{stage_id:'b01'})).body.code,'MATCHMAKING_QUEUED');
  assert.equal((await left.request('combat.duel_invite',{relation_id:relation})).body.code,'MATCHMAKING_QUEUED');
  await left.send('combat.matchmaking_cancel');
  assert.equal((await left.send('combat.matchmaking_lobby')).queue,null);
  await left.send('combat.matchmaking_cancel');
  const expedition=await left.send('combat.expedition_start',{stage_id:'b01'});
  assert.equal((await left.request('combat.matchmaking_join')).body.code,'EXPEDITION_ACTIVE');
  await left.send('combat.expedition_leave',{run_id:expedition.run_id});
  await left.send('combat.matchmaking_join');
  app.advance(14);app.game.arena.step(1);
  assert.equal((await left.send('combat.matchmaking_lobby')).active,null);
  await left.send('combat.matchmaking_cancel');
  app.advance(1);app.game.arena.step(1);
  assert.equal((await left.send('combat.matchmaking_lobby')).active,null);
  assert.equal(app.game.snapshot(left.account_id).duel.queued,false);
  const elder=await app.command(right.token,'growth.create_member',{role:'elder',name:'家人',profile:{title:'家人',avatar:'male',relation:'父亲',age:70,sex:'男',mode:'family',consent:true},request_id:secret()});
  assert.equal((await right.request('combat.matchmaking_join',{cultivator_id:elder.cultivator_id})).body.code,'DUEL_SELF_REQUIRED');
});

test('公开匹配：准备退出、未入场、服务重启和生命周期中断均不改变积分',async context=>{
  const setup=await players(context),{app,left,right}=setup;
  const first=await pair(setup);
  await left.send('combat.duel_leave',{match_id:first.matchId});
  assert.equal((await left.send('combat.matchmaking_lobby')).recent[0].rating_delta,null);
  const absent=await pair(setup);app.advance(46);app.game.arena.step(1125);
  assert.equal(app.game.arena.state(absent.first)!.result!.reason,'absent');
  const interrupted=await pair(setup);
  const restarted=new ArenaService(app.db,app.now,app.game.social);
  assert.equal(restarted.state(interrupted.first)!.result!.reason,'interrupted');
  assert.equal(restarted.state(interrupted.first)!.rating_change,null);
  await left.send('combat.matchmaking_join');
  new ArenaService(app.db,app.now,app.game.social);
  assert.equal((await left.send('combat.matchmaking_lobby')).queue,null,'A server restart clears stranded queues');
  const unavailable=await pair(setup);enter(app,unavailable.first,unavailable.second);
  app.db.run("UPDATE cultivators SET lifecycle='tribulation' WHERE id=?",left.id);app.game.arena.step(1);
  assert.equal(app.game.arena.state(unavailable.first)!.result!.reason,'unavailable');
  for(const player of [left,right])assert.deepEqual((await player.send('combat.matchmaking_lobby')).rating,{rating:1000,wins:0,losses:0,draws:0,rank:null});
});

test('公开匹配：平局与认输按权威终态计分，好友切磋不计入排行榜',async context=>{
  const setup=await players(context),{app,left,right}=setup;
  const draw=await pair(setup);enter(app,draw.first,draw.second);app.game.arena.step(2250);
  assert.equal((await left.send('combat.matchmaking_lobby')).rating.draws,1);
  assert.equal((await left.send('combat.matchmaking_lobby')).rating.rating,1000);
  const forfeit=await pair(setup);enter(app,forfeit.first,forfeit.second);
  await left.send('combat.duel_leave',{match_id:forfeit.matchId});
  const ranked=await left.send('combat.matchmaking_lobby');
  assert.deepEqual(ranked.rating,{rating:988,wins:0,losses:1,draws:1,rank:2});
  await left.send('social.invite',{invite_code:(await right.send('social.home')).profile.invite_code});
  const relation=(await right.send('social.home')).requests[0].relation_id;
  await right.send('social.respond',{relation_id:relation,action:'accept'});
  const friendly=await left.send('combat.duel_invite',{relation_id:relation});
  await right.send('combat.duel_reply',{match_id:friendly.match_id,action:'accept'});
  const a=app.game.arena.subscribe(left.account_id,friendly.match_id),b=app.game.arena.subscribe(right.account_id,friendly.match_id);
  enter(app,a,b);await right.send('combat.duel_leave',{match_id:friendly.match_id});
  assert.equal(app.game.arena.state(a)!.mode,'friendly');
  assert.equal(app.game.arena.state(a)!.rating_change,null);
  assert.deepEqual((await left.send('combat.matchmaking_lobby')).rating,ranked.rating);
});

test('公开匹配：排队会话失效/生命周期变化清除，积分差距随等待扩大且屏蔽双方不匹配',async context=>{
  const setup=await players(context),{app,left,right}=setup;
  await left.send('combat.matchmaking_join');
  app.auth.logout(app.auth.authenticate('Bearer '+left.token),true);
  app.advance(1);
  app.game.arena.step(1);
  assert.equal(app.db.get('SELECT 1 FROM arena_queue WHERE cultivator_id=?',left.id),undefined);
  const relogin=await app.ok('/api/v2/auth/login',{username:'rank_left',password:'a-secure-password-123'});
  left.token=relogin.token;
  // Existing helpers close over the initial token; this path calls the public command with the new session.
  const sendLeft=(command:string)=>app.command(left.token,command,{cultivator_id:left.id},secret());
  await sendLeft('combat.matchmaking_join');
  app.db.run("UPDATE cultivators SET lifecycle='tribulation' WHERE id=?",left.id);app.advance(1);app.game.arena.step(1);
  assert.equal(app.db.get('SELECT 1 FROM arena_queue WHERE cultivator_id=?',left.id),undefined);
  app.db.run("UPDATE cultivators SET lifecycle='cultivating' WHERE id=?",left.id);
  app.db.run('UPDATE arena_ratings SET rating=2000 WHERE cultivator_id=?',left.id);
  await sendLeft('combat.matchmaking_join');await right.send('combat.matchmaking_join');
  assert.equal((await sendLeft('combat.matchmaking_lobby')).active,null);
  app.advance(15);app.game.arena.step(1);
  const matched=await sendLeft('combat.matchmaking_lobby');assert(matched.active);
  await app.command(left.token,'combat.duel_leave',{cultivator_id:left.id,match_id:matched.active.match_id},secret());
  // Public matching also respects an existing social block without exposing its reason.
  app.db.run('INSERT INTO social_blocks VALUES (?,?)',left.id,right.id);
  app.db.run('UPDATE arena_ratings SET rating=1000 WHERE cultivator_id=?',left.id);
  await sendLeft('combat.matchmaking_join');await right.send('combat.matchmaking_join');
  app.advance(15);app.game.arena.step(1);
  const leftBot=(await sendLeft('combat.matchmaking_lobby')).active;
  const rightBot=(await right.send('combat.matchmaking_lobby')).active;
  assert.match(leftBot.opponent, /^[\p{Script=Han}A-Za-z]+_?\d{0,4}$/u);
  assert.match(rightBot.opponent, /^[\p{Script=Han}A-Za-z]+_?\d{0,4}$/u);
  assert.ok(!('bot' in leftBot));
  assert.notEqual(leftBot.match_id,rightBot.match_id);
});


test('公开匹配：第 15 秒进入弱 AI 擂台，击倒结算不计排位', async context => {
  const { app, left, right } = await players(context);
  const before = (await left.send('combat.matchmaking_lobby')).rating;
  await left.send('combat.matchmaking_join');
  app.advance(14);
  app.game.arena.step(1);
  assert.equal((await left.send('combat.matchmaking_lobby')).active, null);
  app.advance(1);
  app.game.arena.step(1);
  const { active, queue } = await left.send('combat.matchmaking_lobby');
  assert.equal(queue, null);
  assert.match(active.opponent, /^[\p{Script=Han}A-Za-z]+_?\d{0,4}$/u);
  assert.ok(!('bot' in active));
  assert.equal(app.db.get<{ count: number }>('SELECT COUNT(*) AS count FROM accounts')?.count, 2);
  assert.equal(app.db.get<{ opponent_alias: string }>('SELECT opponent_alias FROM arena_duels WHERE id = ?', active.match_id)?.opponent_alias, active.opponent);
  assert.throws(() => app.game.arena.subscribe(right.account_id, active.match_id), /对战不存在/);

  const subscription = app.game.arena.subscribe(left.account_id, active.match_id);
  app.game.arena.connect(subscription, true);
  app.game.arena.step(52);
  const opened = app.game.arena.state(subscription)!;
  assert.equal(opened.phase, 'fighting');
  assert.equal(opened.players[1]?.max_hp, opened.players[0]?.max_hp);
  assert.equal(opened.names[1], active.opponent);
  assert.ok(!('bot' in opened));
  app.game.arena.step(1400);
  const finished = app.game.arena.state(subscription)!;
  assert.equal(finished.result?.reason, 'knockout');
  assert.equal(finished.rating_change, null);
  const lobby = await left.send('combat.matchmaking_lobby');
  assert.deepEqual(lobby.rating, before);
  assert.deepEqual(lobby.leaderboard, []);
  assert.equal(lobby.recent[0].opponent, active.opponent);
  assert.equal(lobby.recent[0].mode, 'ranked');
  assert.equal(lobby.recent[0].rating_delta, null);
});

test('八名虚拟玩家轮换，战绩保存到原账号并可重开读取', async () => {
  const testDirectory = join(repositoryRoot, 'work/arena-history-tests');
  mkdirSync(testDirectory, { recursive: true });
  let now = 1795255200;
  const options = { databasePath: join(mkdtempSync(join(testDirectory, 'history-')), 'game.sqlite'), now: () => now, worker: false };
  const credentials = { username: 'arena_history_player', password: 'arena-history-fixture-password' };
  const first = await buildApp(options);
  let actorId: string;
  const encountered = new Map<string, string>();
  const history: { match_id: string; opponent: string; reason: string; winner: number }[] = [];
  try {
    await first.auth.register(credentials);
    const { account_id } = await first.auth.login(credentials);
    const created = first.game.execute(account_id, 'growth.create_member', { role: 'self', name: '试剑者', profile: { title: '试剑者', avatar: 'male' }, request_id: secret() }) as { cultivator_id: string };
    actorId = created.cultivator_id;
    const actor = first.game.own(account_id, actorId);
    first.game.social.saveProfile(actor, '试剑者', false);
    for (let round = 0; round < 9; round++) {
      first.game.arena.matchmakingJoin(actor);
      now += 15;
      first.game.arena.step(1);
      const active = first.game.arena.matchmakingLobby(actor).active!;
      const entry = first.game.arena.subscribe(account_id, active.match_id);
      first.game.arena.connect(entry, true);
      first.game.arena.step(52);
      const fight = first.game.arena.state(entry)!;
      assert.equal(fight.phase, 'fighting');
      assert.equal(fight.names[1], active.opponent);
      if (round < 8) assert.equal(encountered.has(active.opponent), false);
      else assert.equal(encountered.get(active.opponent), fight.avatars[1]);
      encountered.set(active.opponent, fight.avatars[1]!);
      const result = first.game.arena.leave(actor, active.match_id);
      assert.equal(result.rating_delta, null);
      assert.equal(result.opponent, active.opponent);
      history.unshift({ match_id: active.match_id, opponent: active.opponent, reason: 'forfeit', winner: 1 });
    }
    assert.equal(encountered.size, 8);
    assert.deepEqual(new Set(encountered.values()), new Set(['male', 'female']));
    assert.equal(first.db.get<{ count: number }>('SELECT COUNT(*) AS count FROM accounts')?.count, 1);
    const legacy = history.at(-1)!;
    first.db.run("UPDATE arena_duels SET opponent_alias = '一叶归舟7183' WHERE id = ?", legacy.match_id);
    legacy.opponent = '一叶归舟7183';
  } finally { await first.app.close(); }

  const restarted = await buildApp(options);
  try {
    const session = await restarted.auth.login(credentials);
    const response = await restarted.app.inject({ method: 'POST', url: '/api/v2/commands',
      headers: { authorization: `Bearer ${session.token}` },
      payload: { version: 1, command: 'combat.matchmaking_lobby', payload: { cultivator_id: actorId } } });
    assert.equal(response.statusCode, 200);
    const lobby = response.json().data as ReturnType<ArenaService['matchmakingLobby']>;
    assert.deepEqual(lobby.recent.map(({ match_id, opponent, reason, winner }) => ({ match_id, opponent, reason, winner })), history);
    assert.equal(lobby.rating.rating, 1000);
    assert.deepEqual(lobby.leaderboard, []);
  } finally { await restarted.app.close(); }
});

test('全服论剑榜只返回积分前 30 名，榜外玩家仍可查询自己的名次', async context => {
  const { app, left } = await players(context);
  app.db.run('INSERT INTO arena_ratings (cultivator_id, rating, losses) VALUES (?, 900, 1)', left.id);
  for (let rank = 1; rank <= 31; rank++) {
    const id = `ranking-fixture-${rank}`;
    app.db.run("INSERT INTO cultivators (id, account_id, name, element, created_at) VALUES (?, ?, '临时角色', 'water', ?)", id, left.account_id, app.now());
    app.db.run('INSERT INTO social_profiles (cultivator_id, alias, invite_code) VALUES (?, ?, ?)', id, `玩家${rank}`, rank.toString(16).padStart(16, '0'));
    app.db.run('INSERT INTO arena_ratings (cultivator_id, rating, wins) VALUES (?, ?, 1)', id, 2000 - rank);
  }
  const lobby = await left.send('combat.matchmaking_lobby');
  assert.equal(lobby.leaderboard.length, 30);
  assert.equal(lobby.leaderboard[29].alias, '玩家30');
  assert.equal(lobby.rating.rank, 32);
});

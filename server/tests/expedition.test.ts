import assert from 'node:assert/strict';
import test, { type TestContext } from 'node:test';
import WebSocket from 'ws';
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, mkdtempSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { buildApp } from '../src/app.js';
import { repositoryRoot } from '../src/contracts.js';
import { secret } from '../src/core.js';
import { ExpeditionMatch } from '../src/game/expedition-match.js';
import type { FighterStats } from '../src/game/arena-match.js';
import { ExpeditionService } from '../src/game/expedition.js';
import { fixture } from './helpers.js';

const starter: FighterStats = { life: 100, attack: 12, defense: 0, spirit: 100, stamina: 100 };
function step(match: ExpeditionMatch, count: number) { for (let i = 0; i < count; i++) match.step(); }
function fight(send: (input: { seq: number; x: number; y: number; action: number }) => void,
  advance: () => void, state: () => ReturnType<ExpeditionMatch['state']>) {
  for (let tick = 1; tick < 5000; tick++) {
    const value = state();
    if (value.result) return value.result;
    const player = value.player, enemy = value.enemy;
    const dx = enemy.x - player.x, dy = enemy.y - player.y;
    const distance = Math.hypot(dx, dy);
    let action = distance < 120 ? 1 : 0;
    if (player.hp < player.max_hp * 0.6 && player.cd[5] === 0 && player.mp >= 40) action = 5;
    else if (player.cd[4] === 0 && player.mp >= 24 && value.telegraphs.some(effect => effect.remaining < 0.24)) action = 4;
    send({ seq: tick, x: distance > 95 ? dx / Math.max(1, distance) : 0, y: distance > 95 ? dy / Math.max(1, distance) : 0, action });
    advance();
  }
  throw new Error('Combat did not finish');
}

test('秘境内核：无装备可打首关，技能有预警且三关使用不同攻势', () => {
  const match = new ExpeditionMatch('b01', starter);
  match.connect(true);
  const result = fight(input => match.input(input), () => match.step(), () => match.state());
  assert.equal(result.won, true);
  assert.ok(match.tick > 50, 'A victory requires the countdown and actual attacks');
  const stationary = new ExpeditionMatch('b01', starter);
  stationary.connect(true);
  step(stationary, 115);
  assert.ok(stationary.player.hp < stationary.player.maxHp, 'Standing in a telegraphed attack receives real boss damage');
  const signatures: string[] = [];
  for (const stage of ['b01', 'b02', 'b03'] as const) {
    const boss = new ExpeditionMatch(stage, { ...starter, life: 1000 });
    boss.connect(true);
    step(boss, 82);
    const warning = boss.state().telegraphs;
    assert.ok(warning.length);
    assert.ok(warning.every(item => item.remaining > 0 && item.total > 0));
    signatures.push(warning.map(item => `${item.kind}:${item.radius ?? item.width}`).join(','));
  }
  assert.equal(new Set(signatures).size, 3);
});

test('秘境内核：断线冻结、恢复、累计重连超时，输入不能越界或重放', () => {
  const match = new ExpeditionMatch('b01', starter);
  match.connect(true);
  step(match, 50);
  match.input({ seq: 100, x: 1, y: 1, action: 0 });
  step(match, 4);
  const before = match.player.x;
  match.input({ seq: 99, x: -1, y: 0, action: 0 });
  step(match, 4);
  assert.ok(match.player.x > before);
  step(match, 20);
  const stopped = match.player.x;
  step(match, 4);
  assert.equal(match.player.x, stopped);
  match.connect(false);
  const snapshot = match.state();
  step(match, 100);
  assert.equal(match.phase, 'reconnecting');
  assert.equal(match.player.hp, snapshot.player.hp);
  assert.equal(match.state().telegraphs[0]?.remaining, snapshot.telegraphs[0]?.remaining);
  match.connect(true);
  step(match, 1);
  assert.equal(match.phase, 'fighting');
  match.connect(false);
  step(match, 275);
  assert.equal(match.result?.reason, 'disconnect');
  assert.equal(match.result?.won, false);
});

async function adventurer(context: TestContext) {
  const app = await fixture(context);
  const account = await app.account('adventurer');
  const member = await app.command(account.token, 'growth.create_member', { role: 'self', name: '行者', profile: { title: '行者', avatar: 'male' }, request_id: secret() });
  const id = member.cultivator_id as string;
  const send = (command: string, fields: object = {}, key = secret()) => app.command(account.token, command, { cultivator_id: id, ...fields }, key);
  const request = (command: string, fields: object = {}) => app.request('/api/v2/commands', { version: 1, command, payload: { cultivator_id: id, ...fields } }, account.token, 'POST', secret());
  return { app, account, id, send, request };
}

function win(app: Pick<Awaited<ReturnType<typeof fixture>>, 'game'>, accountId: string, runId: string) {
  const subscription = app.game.expedition.subscribe(accountId, runId);
  app.game.expedition.connect(subscription, true);
  const result = fight(input => app.game.expedition.input(subscription, input), () => app.game.expedition.step(1),
    () => app.game.expedition.state(subscription)!);
  assert.equal(result.won, true);
  return app.game.expedition.state(subscription)!.result!;
}

test('真实新角色：无健康基线入场、权威首通、奖励抽卡、装备强化和逐关解锁', async context => {
  const { app, account, id, send, request } = await adventurer(context);
  assert.equal(app.game.characterSnapshot(account.account_id, id).initial_score, null);
  assert.equal((await request('combat.expedition_start', { stage_id: 'b02' })).body.code, 'EXPEDITION_LOCKED');
  const first = await send('combat.expedition_start', { stage_id: 'b01' }, 'stable-start');
  assert.deepEqual(await send('combat.expedition_start', { stage_id: 'b01' }, 'stable-start'), first);
  assert.equal((await request('combat.expedition_start', { stage_id: 'b01' })).body.code, 'EXPEDITION_ACTIVE');
  assert.equal(app.game.characterSnapshot(account.account_id, id).initial_score, 50);
  assert.deepEqual(app.db.all('SELECT * FROM baselines WHERE cultivator_id = ?', id), []);
  const result = win(app, account.account_id, first.run_id);
  assert.equal(result.reward.first_clear, true);
  assert.equal(result.reward.spirit_stones, 100);
  assert.equal(result.reward.materials, 8);
  const originalBalance = app.game.characterSnapshot(account.account_id, id).resources.spirit_stones;
  for (let retry = 0; retry < 3; retry++) {
    assert.equal((await send('combat.expedition_leave', { run_id: first.run_id })).reward.spirit_stones, 100);
    app.game.expedition.step(10);
  }
  assert.equal(app.game.characterSnapshot(account.account_id, id).resources.spirit_stones, originalBalance);
  assert.equal(app.db.all('SELECT * FROM ledger WHERE operation_id = ?', first.run_id).length, 2);
  const drawn = await send('growth.draw', { count: 1, request_id: 'new-player-draw' }, 'new-player-draw');
  assert.equal(drawn.items.length, 1);
  const drop = result.reward.equipment!;
  await send('growth.upgrade', { equipment_id: drop.equipment_id, expected_level: 0 });
  await send('growth.equip', { equipment_id: drop.equipment_id, slot: 'weapon' });
  const second = await send('combat.expedition_start', { stage_id: 'b02' });
  const subscription = app.game.expedition.subscribe(account.account_id, second.run_id);
  assert.ok(app.game.expedition.state(subscription)!.player.max_hp >= 100);
  const frozenStats = JSON.parse(app.db.get<{ stats: string }>('SELECT stats FROM expedition_runs WHERE id = ?', second.run_id)!.stats);
  assert.equal(frozenStats.attack, second.base_stats.attack + 7, 'The upgraded fine weapon adds to the earned adventure level');
  const lobby = await send('combat.expedition_lobby');
  assert.equal(lobby.stages.length, 20);
  assert.deepEqual(lobby.stages.filter((stage: { unlocked: boolean }) => stage.unlocked).map((stage: { stage_id: string }) => stage.stage_id), ['b00', 'b01', 'b02']);
  await send('combat.expedition_leave', { run_id: second.run_id });
  assert.equal((await send('combat.expedition_lobby')).recent[0].reward.spirit_stones, 0);
});

test('重复通关只给重复奖励，旧练习战果不能解锁或生成资源', async context => {
  const { app, account, id, send, request } = await adventurer(context);
  const practice = await send('combat.start', { encounter_id: 'b01' });
  app.advance(10);
  await app.command(account.token, 'combat.finish', { session_id: practice.session_id, won: true, duration_seconds: 10 });
  assert.equal((await request('combat.expedition_start', { stage_id: 'b02' })).body.code, 'EXPEDITION_LOCKED');
  const first = await send('combat.expedition_start', { stage_id: 'b01' });
  win(app, account.account_id, first.run_id);
  const second = await send('combat.expedition_start', { stage_id: 'b01' });
  const repeat = win(app, account.account_id, second.run_id);
  assert.equal(repeat.reward.first_clear, false);
  assert.equal(repeat.reward.spirit_stones, 15);
  assert.equal(repeat.reward.materials, 2);
  assert.equal(app.db.all('SELECT * FROM expedition_clears WHERE cultivator_id = ?', id).length, 1);
});

test('秘境归属、生命周期、准备超时与服务重启中断不会奖励', async context => {
  const { app, account, id, send, request } = await adventurer(context);
  const other = await app.account('stranger');
  const first = await send('combat.expedition_start', { stage_id: 'b01' });
  assert.throws(() => app.game.expedition.subscribe(other.account_id, first.run_id), { code: 'EXPEDITION_NOT_FOUND' });
  assert.equal((await request('combat.expedition_leave', { run_id: 'missing' })).body.code, 'EXPEDITION_NOT_FOUND');
  const entry = app.game.expedition.subscribe(account.account_id, first.run_id);
  app.game.expedition.connect(entry, true);
  app.db.run("UPDATE cultivators SET lifecycle = 'tribulation', lifecycle_version = 1 WHERE id = ?", id);
  app.game.expedition.step(1);
  assert.equal(app.game.expedition.state(entry)!.result!.reason, 'unavailable');
  assert.equal((await request('combat.expedition_start', { stage_id: 'b01' })).body.code, 'EXPEDITION_UNAVAILABLE');
  app.db.run("UPDATE cultivators SET lifecycle = 'cultivating' WHERE id = ?", id);
  const absent = await send('combat.expedition_start', { stage_id: 'b01' });
  app.advance(46);
  app.game.expedition.step(1);
  assert.equal(app.game.expedition.state({ id: absent.run_id })!.result!.reason, 'absent');
  const interrupted = await send('combat.expedition_start', { stage_id: 'b01' });
  const restarted = new ExpeditionService(app.db, app.now, app.game.ledger, () => 0);
  assert.equal(restarted.state({ id: interrupted.run_id })!.result!.reason, 'interrupted');
  assert.equal(app.game.characterSnapshot(account.account_id, id).resources.spirit_stones, 0);
  assert.deepEqual(app.db.all("SELECT * FROM ledger WHERE reason = 'expedition_clear'"), []);
});

test('同角色PVP与PVE互斥，家人角色不能参加秘境，客户端不能提交秘境胜利', async context => {
  const { app, account, id, send, request } = await adventurer(context);
  const friend = await app.account('duel_friend');
  const other = await app.command(friend.token, 'growth.create_member', { role: 'self', name: '剑友', profile: { title: '剑友', avatar: 'female' }, request_id: secret() });
  const peer = (command: string, fields: object = {}) => app.command(friend.token, command, { cultivator_id: other.cultivator_id, ...fields }, secret());
  await send('social.profile', { alias: '行者', rotate_code: false });
  await peer('social.profile', { alias: '剑友', rotate_code: false });
  const code = (await peer('social.home')).profile.invite_code;
  await send('social.invite', { invite_code: code });
  const relation = (await peer('social.home')).requests[0].relation_id;
  await peer('social.respond', { relation_id: relation, action: 'accept' });
  const expedition = await send('combat.expedition_start', { stage_id: 'b01' });
  assert.equal((await request('combat.duel_invite', { relation_id: relation })).body.code, 'EXPEDITION_ACTIVE');
  const forged = await app.request('/api/v2/commands', { version: 1, command: 'combat.expedition_finish', payload: { cultivator_id: id, run_id: expedition.run_id, won: true } }, account.token, 'POST', secret());
  assert.equal(forged.status, 400, 'The HTTP contract rejects a client-supplied expedition result');
  await send('combat.expedition_leave', { run_id: expedition.run_id });
  const invite = await send('combat.duel_invite', { relation_id: relation });
  assert.equal((await request('combat.expedition_start', { stage_id: 'b01' })).body.code, 'DUEL_ALREADY_PENDING');
  await send('combat.duel_reply', { match_id: invite.match_id, action: 'cancel' });
  const elder = await app.command(account.token, 'growth.create_member', { role: 'elder', name: '长辈',
    profile: { title: '长辈', avatar: 'male', relation: '父亲', age: 70, sex: '男', mode: 'family', consent: true }, request_id: secret() });
  const denied = await app.request('/api/v2/commands', { version: 1, command: 'combat.expedition_start', payload: { cultivator_id: elder.cultivator_id, stage_id: 'b01' } }, account.token, 'POST', secret());
  assert.equal(denied.body.code, 'EXPEDITION_SELF_REQUIRED');
});

test('三个首通均可凭装备增益打通，历史终态和奖励在房间回收后保留', async context => {
  const { app, account, id, send } = await adventurer(context);
  // A full level-10 set represents progression; the combat snapshot must use these actual instances.
  for (const [template, slot] of [[0, 'weapon'], [1, 'robe'], [3, 'boots'], [4, 'amulet']] as const) {
    app.db.run(`INSERT INTO equipment (id, cultivator_id, catalogue_id, catalogue_version, slot, rarity, equipped, school, upgrade_level)
      VALUES (?, ?, ?, 'pixel-equipment-v1', ?, 'legendary', 1, 0, 10)`, secret(), id, `pixel:${template}`, slot);
  }
  for (const stage of ['b01', 'b02', 'b03']) {
    const run = await send('combat.expedition_start', { stage_id: stage });
    const result = win(app, account.account_id, run.run_id);
    assert.equal(result.reward.first_clear, true);
    assert.equal(result.enemy_hp, 0);
    app.advance(16);
    app.game.expedition.step(1);
    const restored = app.game.expedition.state({ id: run.run_id })!;
    assert.equal(restored.enemy.hp, 0);
    assert.equal(restored.result!.won, true);
    assert.equal(restored.player.hp, result.hp);
  }
  assert.equal((await send('combat.expedition_lobby')).stages.filter((stage: { cleared: boolean }) => stage.cleared).length, 3);
});

test('自然养成：新账号仅靠首通掉落与有限资源强化，逐关通关苍梧三关', async context => {
  const { app, account, id, send } = await adventurer(context);
  const first = await send('combat.expedition_start', { stage_id: 'b01' });
  const firstResult = win(app, account.account_id, first.run_id);
  const sword = firstResult.reward.equipment!;
  await send('growth.equip', { equipment_id: sword.equipment_id, slot: 'weapon' });
  for (let level = 0; level < 2; level++) await send('growth.upgrade', { equipment_id: sword.equipment_id, expected_level: level });
  assert.equal(app.game.characterSnapshot(account.account_id, id).resources.spirit_stones, 70);
  assert.equal(app.game.characterSnapshot(account.account_id, id).resources.materials, 2);
  const second = await send('combat.expedition_start', { stage_id: 'b02' });
  const secondResult = win(app, account.account_id, second.run_id);
  const robe = secondResult.reward.equipment!;
  await send('growth.equip', { equipment_id: robe.equipment_id, slot: 'robe' });
  await send('growth.upgrade', { equipment_id: sword.equipment_id, expected_level: 2 });
  for (let level = 0; level < 2; level++) await send('growth.upgrade', { equipment_id: robe.equipment_id, expected_level: level });
  assert.equal(app.game.characterSnapshot(account.account_id, id).resources.spirit_stones, 170);
  assert.equal(app.game.characterSnapshot(account.account_id, id).resources.materials, 2);
  const third = await send('combat.expedition_start', { stage_id: 'b03' });
  const thirdResult = win(app, account.account_id, third.run_id);
  assert.equal(thirdResult.reward.first_clear, true);
  const final = app.game.characterSnapshot(account.account_id, id);
  assert.equal(final.resources.spirit_stones, 410);
  assert.equal(final.resources.materials, 20);
  assert.equal(final.equipment.length, 3);
  assert.deepEqual(app.db.all('SELECT * FROM baselines WHERE cultivator_id = ?', id), []);
  context.diagnostic(JSON.stringify({ stages: [firstResult, secondResult, thirdResult].map(result => ({
    hp: result.hp, seconds: result.duration_seconds, won: result.won,
  })), final: final.resources }));
});

test('v7存档迁移最新版保留余额、流派强化装备、账号会话与历史账本', async () => {
  const base = join(repositoryRoot, 'work/expedition-migrations');
  mkdirSync(base, { recursive: true });
  const path = join(mkdtempSync(join(base, 'v7-')), 'game.sqlite');
  const options = { databasePath: path, worker: false, randomInt: () => 0 };
  const first = await buildApp(options);
  const account = await first.auth.register({ username: 'migrated_player', password: 'migration-password-123' });
  const login = await first.auth.login({ username: 'migrated_player', password: 'migration-password-123' });
  const member = first.game.execute(account.account_id, 'growth.create_member', { role: 'self', name: '旧档行者', profile: { title: '旧档行者', avatar: 'female' }, request_id: secret() }) as { cultivator_id: string };
  const actor = member.cultivator_id;
  first.db.transaction(() => {
    first.game.ledger.change(account.account_id, actor, 'spirit_stones', 123, secret(), 'migration_fixture');
    first.game.ledger.change(account.account_id, actor, 'materials', 12, secret(), 'migration_fixture');
  });
  first.db.run(`INSERT INTO equipment (id, cultivator_id, catalogue_id, catalogue_version, slot, rarity, equipped, school, upgrade_level)
    VALUES ('old-sword', ?, 'pixel:0', 'pixel-equipment-v1', 'weapon', 'epic', 1, 2, 3)`, actor);
  const before = first.game.characterSnapshot(account.account_id, actor);
  const ledger = first.db.all('SELECT * FROM ledger ORDER BY rowid');
  await first.app.close();
  // Remove unused later schema to construct a v7 database with valid v1..v7 checksums.
  const raw = new DatabaseSync(path);
  const arenaV6 = Array.from(readFileSync(join(repositoryRoot, 'server/src/database.ts'), 'utf8')
    .matchAll(/String\.raw`([\s\S]*?)`/g), match => match[1]!)[5]!;
  raw.exec(`DROP TABLE story_nodes; DROP TABLE adventure_awards;
    DROP TABLE arena_duels; DROP TABLE arena_queue; DROP TABLE arena_ratings;
    DROP TABLE expedition_clears; DROP TABLE expedition_runs; DELETE FROM schema_migrations WHERE version >= 8; PRAGMA user_version = 7;`);
  raw.exec(arenaV6);
  raw.close();
  const migrated = await buildApp(options);
  try {
    assert.equal(migrated.db.get<{ user_version: number }>('PRAGMA user_version')!.user_version, 11);
    assert.equal(migrated.auth.authenticate(`Bearer ${login.token}`).account_id, account.account_id);
    assert.deepEqual(migrated.game.characterSnapshot(account.account_id, actor), before);
    assert.deepEqual(migrated.db.all('SELECT * FROM ledger ORDER BY rowid'), ledger);
    assert.equal(migrated.game.expedition.lobby(migrated.game.own(account.account_id, actor)).active, null);
  } finally { await migrated.app.close(); }
});

test('掉落出错时整个奖励事务回滚，重试只结算一次', async context => {
  let invalidRandom = false;
  const app = await fixture(context, { randomInt: maximum => invalidRandom ? maximum : 0 });
  const account = await app.account('rollback_adventurer');
  const member = await app.command(account.token, 'growth.create_member', { role: 'self', name: '行者', profile: { title: '行者', avatar: 'male' }, request_id: secret() });
  const id = member.cultivator_id as string;
  const send = (fields: object) => app.command(account.token, 'combat.expedition_start', { cultivator_id: id, ...fields }, secret());
  const first = await send({ stage_id: 'b01' });
  win(app, account.account_id, first.run_id);
  const before = app.game.characterSnapshot(account.account_id, id);
  const second = await send({ stage_id: 'b01' });
  invalidRandom = true;
  assert.throws(() => win(app, account.account_id, second.run_id), { code: 'INVALID_RANDOM' });
  assert.equal(app.db.get<{ result: string | null }>('SELECT result FROM expedition_runs WHERE id = ?', second.run_id)!.result, null);
  assert.deepEqual(app.db.all('SELECT * FROM ledger WHERE operation_id = ?', second.run_id), []);
  const rolledBack = app.game.characterSnapshot(account.account_id, id);
  assert.deepEqual(rolledBack.resources, before.resources);
  assert.deepEqual(rolledBack.equipment, before.equipment);
  invalidRandom = false;
  app.game.expedition.step(1);
  app.game.expedition.step(10);
  assert.equal(app.game.characterSnapshot(account.account_id, id).resources.spirit_stones, before.resources.spirit_stones + 15);
  assert.equal(app.db.all('SELECT * FROM ledger WHERE operation_id = ?', second.run_id).length, 2);
});

test('WebSocket秘境：所有权隔离、同账号设备替换、断线重入与规范输入', async context => {
  const { app, account, send } = await adventurer(context);
  const first = await send('combat.expedition_start', { stage_id: 'b01' });
  await app.app.listen({ host: '127.0.0.1', port: 0 });
  const connect = async (token: string) => {
    const ticket = await app.ok('/api/v2/realtime/ticket', {}, token);
    const socket = new WebSocket(`${app.app.listeningOrigin.replace('http:', 'ws:')}/api/v2/realtime?ticket=${ticket.ticket}`);
    context.after(() => socket.terminate());
    const queue: any[] = [];
    socket.on('message', raw => queue.push(JSON.parse(raw.toString())));
    const next = async (type: string) => {
      const end = Date.now() + 3000;
      while (Date.now() < end) {
        const index = queue.findIndex(item => item.type === type);
        if (index >= 0) return queue.splice(index, 1)[0];
        await new Promise(resolve => setTimeout(resolve, 10));
      }
      throw new Error(`Missing ${type}`);
    };
    await next('snapshot');
    return { socket, next };
  };
  const stranger = await app.account('ws_stranger');
  const outsider = await connect(stranger.token);
  outsider.socket.send(JSON.stringify({ type: 'expedition_join', run_id: first.run_id }));
  assert.equal((await outsider.next('expedition_error')).code, 'EXPEDITION_NOT_FOUND');
  const left = await connect(account.token);
  left.socket.send(JSON.stringify({ type: 'expedition_join', run_id: first.run_id }));
  assert.equal((await left.next('expedition_state')).data.phase, 'waiting');
  const right = await connect(account.token);
  right.socket.send(JSON.stringify({ type: 'expedition_join', run_id: first.run_id }));
  assert.equal((await left.next('expedition_error')).code, 'EXPEDITION_REPLACED');
  assert.equal((await right.next('expedition_state')).data.run_id, first.run_id);
  right.socket.terminate();
  const rejoin = await connect(account.token);
  rejoin.socket.send(JSON.stringify({ type: 'expedition_join', run_id: first.run_id }));
  assert.equal((await rejoin.next('expedition_state')).data.run_id, first.run_id);
  const closed = new Promise<number>(resolve => rejoin.socket.once('close', code => resolve(code)));
  rejoin.socket.send(JSON.stringify({ type: 'expedition_input', run_id: first.run_id, seq: 1, x: 2, y: 0, action: 1 }));
  assert.equal(await closed, 1008, 'Out-of-range client movement is rejected');
});

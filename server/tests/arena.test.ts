import assert from 'node:assert/strict';
import test, { type TestContext } from 'node:test';
import { secret } from '../src/core.js';
import { ArenaMatch, type Seat } from '../src/game/arena-match.js';
import { fixture } from './helpers.js';

function step(match: ArenaMatch, ticks: number) { for (let i = 0; i < ticks; i++) match.step(); }
function ready(practiceStyle?: number) {
  const match = practiceStyle === undefined ? new ArenaMatch(1125) : new ArenaMatch(1125, { practiceStyle });
  match.connect(0, true);
  match.connect(1, true);
  step(match, 50);
  assert.equal(match.phase, 'fighting');
  return match;
}
function action(match: ArenaMatch, seat: Seat, value: number, seq = match.tick + 1, x = 0, y = 0) {
  match.input(seat, { seq, action: value, x, y });
}

test('擂台模拟：倒计时、移动限速、过期输入、冷却与命中由服务端推进', () => {
  const match = ready();
  const start = match.fighters[0].x;
  action(match, 0, 0, 100, 1);
  step(match, 4);
  assert.ok(match.fighters[0].x > start && match.fighters[0].x <= start + 42);
  const beforeReplay = match.fighters[0].x;
  action(match, 0, 0, 99, -1);
  step(match, 4);
  assert.ok(match.fighters[0].x > beforeReplay, 'A replayed packet cannot reverse movement');
  step(match, 3);
  const stopped = match.fighters[0].x;
  step(match, 10);
  assert.equal(match.fighters[0].x, stopped, 'Movement stops when fresh inputs stop');
  const sword = ready();
  action(sword, 0, 2);
  step(sword, 20);
  assert.equal(sword.fighters[1].hp, 77);
  action(sword, 0, 2);
  step(sword, 10);
  assert.equal(sword.fighters[1].hp, 77, 'Cooldown rejects another sword strike');
  const shield = ready();
  action(shield, 0, 2);
  action(shield, 1, 4);
  step(shield, 20);
  assert.equal(shield.fighters[1].hp, 100);
  const healed = ready();
  action(healed, 0, 2);
  step(healed, 20);
  action(healed, 1, 5);
  step(healed, 21);
  assert.equal(healed.fighters[1].hp, 100);
  const diagonal = ready();
  action(diagonal, 0, 0, 1, 1, 1);
  step(diagonal, 4);
  assert.ok(Math.hypot(diagonal.fighters[0].x - 520, diagonal.fighters[0].y - 570) <= 42);
});

test('擂台模拟：双方断线冻结战斗、重连恢复、超时结束与 90 秒平局', () => {
  const match = ready();
  match.connect(1, false);
  const before = match.fighters.map(({ hp, x, y }) => ({ hp, x, y }));
  step(match, 10);
  assert.equal(match.phase, 'reconnecting');
  assert.deepEqual(match.fighters.map(({ hp, x, y }) => ({ hp, x, y })), before);
  match.connect(1, true);
  match.step();
  assert.equal(match.phase, 'fighting');
  match.connect(1, false);
  step(match, 240);
  assert.equal(match.result?.reason, 'disconnect');
  assert.equal(match.result?.winner, 0);
  const timeout = ready();
  step(timeout, 2250);
  assert.deepEqual(timeout.result, { winner: null, reason: 'time', hp: [100, 100] });
  const empty = new ArenaMatch(2);
  step(empty, 2);
  assert.equal(empty.result?.reason, 'absent');
});

test('虚拟玩家使用共同的资源和冷却规则释放剑气、闪避、护盾与治疗', () => {
  const sword = ready(0);
  sword.fighters[1].x = 790;
  step(sword, 33);
  assert.ok(sword.fighters[1].cd[2]! > 0);
  assert.ok(sword.fighters[1].mp < 100);

  const dodge = ready(0);
  step(dodge, 19);
  const [player, bot] = dodge.fighters;
  dodge.blades.push({ owner: 0, x: bot.x - 90, y: bot.y, fx: 1, fy: 0, life: 10 });
  dodge.step();
  assert.ok(bot.dash > 0);
  assert.ok(bot.stamina < 100);
  assert.ok(bot.y !== player.y);

  const guard = ready(0);
  guard.fighters[1].x = 609;
  step(guard, 16);
  action(guard, 0, 2, 1, 1);
  step(guard, 4);
  assert.ok(guard.fighters[1].shield > 0);
  assert.ok(guard.fighters[1].mp < 100);

  const heal = ready(0);
  heal.fighters[1].hp = 24;
  step(heal, 33);
  assert.ok(heal.fighters[1].heal > 0);
  step(heal, 21);
  assert.equal(heal.fighters[1].hp, 48);
});

async function players(context: TestContext) {
  const app = await fixture(context);
  const player = async (name: string) => {
    const account = await app.account(name);
    const created = await app.command(account.token, 'growth.create_member', {
      role: 'self', name, profile: { title: name, avatar: 'male' }, request_id: secret(),
    });
    const id = created.cultivator_id as string;
    const send = (command: string, fields: object = {}, key = secret()) => app.command(account.token, command, { cultivator_id: id, ...fields }, key);
    const request = (command: string, fields: object) => app.request('/api/v2/commands',
      { version: 1, command, payload: { cultivator_id: id, ...fields } }, account.token, 'POST', secret());
    await send('social.profile', { alias: name, rotate_code: false });
    return { ...account, id, send, request };
  };
  const left = await player('left');
  const right = await player('right');
  const stranger = await player('stranger');
  const rightHome = await right.send('social.home');
  await left.send('social.invite', { invite_code: rightHome.profile.invite_code });
  const relationId = (await right.send('social.home')).requests[0].relation_id as string;
  await right.send('social.respond', { relation_id: relationId, action: 'accept' });
  return { app, left, right, stranger, relationId };
}

test('好友约战：确认权限、归属、占用限制、服务端战果与重复退出', async context => {
  const { app, left, right, stranger, relationId } = await players(context);
  const invite = await left.send('combat.duel_invite', { relation_id: relationId }, 'invite-1');
  assert.deepEqual(await left.send('combat.duel_invite', { relation_id: relationId }, 'invite-1'), invite);
  assert.equal((await left.request('combat.duel_invite', { relation_id: relationId })).body.code, 'DUEL_ALREADY_PENDING');
  const { match_id } = invite;
  assert.equal((await left.request('combat.duel_reply', { match_id, action: 'accept' })).body.code, 'DUEL_ACTION_UNAVAILABLE');
  assert.equal((await stranger.request('combat.duel_reply', { match_id, action: 'accept' })).body.code, 'DUEL_NOT_FOUND');
  assert.equal((await right.send('combat.duel_lobby')).matches[0].status, 'pending');
  assert.equal(app.game.snapshot(right.account_id).duel.invitations, 1);
  await right.send('combat.duel_reply', { match_id, action: 'accept' });
  assert.throws(() => app.game.arena.subscribe(stranger.account_id, match_id), { code: 'DUEL_NOT_FOUND' });
  const first = app.game.arena.subscribe(left.account_id, match_id);
  const second = app.game.arena.subscribe(right.account_id, match_id);
  app.game.arena.connect(first, true);
  app.game.arena.connect(second, true);
  app.game.arena.step(50);
  assert.equal(app.game.arena.state(first)!.phase, 'fighting');
  app.game.arena.input(first, { seq: 1, x: 0, y: 0, action: 2 });
  app.game.arena.step(20);
  assert.equal(app.game.arena.state(second)!.players[1]!.hp, 77);
  const result = await left.send('combat.duel_leave', { match_id });
  assert.equal(result.winner, 1);
  assert.equal(result.reason, 'forfeit');
  assert.deepEqual(await left.send('combat.duel_leave', { match_id }), result);
  assert.equal((await right.send('combat.duel_lobby')).matches[0].winner, 1);
  assert.equal(app.game.snapshot(left.account_id).duel.active, false);
  assert.deepEqual(app.db.all("SELECT * FROM ledger WHERE reason LIKE 'duel_%'"), []);
  assert.equal(app.game.arena.state(second)!.result!.hp[1], 77);
});

test('约战过期与好友撤销后不能接受；无入场者会释放擂台', async context => {
  const { app, left, right, relationId } = await players(context);
  const first = await left.send('combat.duel_invite', { relation_id: relationId });
  app.advance(90);
  assert.equal((await right.request('combat.duel_reply', { match_id: first.match_id, action: 'accept' })).body.code, 'DUEL_INVITE_CLOSED');
  assert.deepEqual((await right.send('combat.duel_lobby')).matches, []);
  const second = await left.send('combat.duel_invite', { relation_id: relationId });
  await right.send('combat.duel_reply', { match_id: second.match_id, action: 'accept' });
  app.advance(46);
  app.game.arena.step(1);
  assert.equal((await right.send('combat.duel_lobby')).matches[0].reason, 'absent');
  const third = await left.send('combat.duel_invite', { relation_id: relationId });
  await right.send('social.respond', { relation_id: relationId, action: 'block' });
  assert.equal((await right.request('combat.duel_reply', { match_id: third.match_id, action: 'accept' })).body.code, 'SOCIAL_RELATION_NOT_FOUND');
});

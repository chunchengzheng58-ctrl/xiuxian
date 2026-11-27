import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from './helpers.js';
import { dayKey, secret } from '../src/core.js';
import { defaultProviders } from '../src/game/rules.js';

test('神遁榜覆盖、隐私、双向好友、日周排名和每日奖励', async context => {
  const f = await fixture(context, { providers: defaultProviders });
  const create = async (name: string) => {
    const a = await f.account(name);
    const c = await f.command(a.token, 'growth.create_member', { role: 'self', name, profile: { title: '修士', avatar: 'male' }, request_id: secret() });
    return { ...a, id: c.cultivator_id };
  };
  const a = await create('shendun_a'), b = await create('shendun_b');
  const confirm = (actor: typeof a, distance: number, revision = 0) => f.ok('/api/v2/wearables/confirm', {
    cultivator_id: actor.id, date: dayKey(f.now()), rule: 'wearable-v1', source: 'oura', distance_zhang: distance,
    movement_tier: distance >= 8000 ? 3 : distance >= 5000 ? 2 : distance >= 2000 ? 1 : 0, sleep_tier: 3, expected_revision: revision,
  }, actor.token);
  const board = (actor: typeof a, scope = 'global', period = 'day') => f.ok('/api/v2/wearables/leaderboard', { cultivator_id: actor.id, scope, period, offset: 0 }, actor.token);
  const visible = (actor: typeof a, visibility: string) => f.ok('/api/v2/wearables/visibility', { cultivator_id: actor.id, visibility }, actor.token);
  const first = await confirm(a, 5000);
  assert.equal(first.effects.movement, .02);
  const expedition = await f.command(a.token, 'combat.expedition_start', { cultivator_id: a.id, stage_id: 'b01' }, secret());
  assert.equal(expedition.stats.wearable_move, .02);
  assert.equal(expedition.stats.wearable_regen, .04);
  assert.equal(JSON.parse(f.db.get<{ stats: string }>('SELECT stats FROM expedition_runs WHERE id = ?', expedition.run_id)!.stats).wearable_move, .02);
  assert.equal((await board(a)).entries.length, 0);
  const updated = await confirm(a, 8000, 1);
  assert.equal(updated.effects.movement, .02); // first daily buff is locked
  assert.equal(updated.settlement.settlement_id, first.settlement.settlement_id);
  await confirm(a, 8000, 0); // idempotent retry
  await confirm(b, 9000);
  await visible(a, 'public'); await visible(b, 'friends');
  assert.equal((await board(a)).entries.length, 1);
  assert.equal((await board(a, 'friends')).entries.length, 1);
  // Actual existing friendship and block tables, not client-supplied lists.
  for (const x of [a, b]) f.db.run('INSERT INTO social_profiles VALUES (?, ?, ?)', x.id, x.id.slice(-10), secret().slice(0, 16));
  const ids = [a.id, b.id].sort();
  f.db.run("INSERT INTO social_relations (id,left_id,right_id,requester_id,status,updated_at) VALUES ('wearable-friends',?,?,?,'accepted',?)", ids[0]!, ids[1]!, a.id, f.now());
  const friends = await board(a, 'friends');
  assert.equal(friends.entries[0].distance_zhang, 9000);
  assert.equal(friends.self.rank, 2);
  assert.equal(JSON.stringify(friends).includes('sleep_tier'), false);
  await visible(b, 'public');
  assert.equal((await board(a)).entries[0].distance_zhang, 9000);
  await confirm(b, 8000, 1);
  assert.deepEqual((await board(a)).entries.map((x: { rank: number }) => x.rank), [1, 1]);
  const wrong = await f.request('/api/v2/wearables/status', { cultivator_id: a.id }, b.token);
  assert.equal(wrong.status, 404);
  f.advance(86400);
  await confirm(a, 2000);
  assert.equal((await board(a)).self.distance_zhang, 2000);
  assert.equal((await board(a, 'global', 'week')).self.distance_zhang, 10000);
  await f.ok('/api/v2/wearables/withdraw', { cultivator_id: a.id }, a.token);
  assert.equal((await board(a)).entries.length, 0);
});

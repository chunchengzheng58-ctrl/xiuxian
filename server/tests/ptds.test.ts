import assert from 'node:assert/strict';
import test from 'node:test';
import { dayKey, secret } from '../src/core.js';
import { defaultProviders } from '../src/game/rules.js';
import { fixture } from './helpers.js';

test('PTDS 本人确认复用每日结算，重复导入只记一笔，且只接收日期', async context => {
  const f = await fixture(context, { providers: defaultProviders });
  const player = await f.account('ptds_player');
  const other = await f.account('ptds_other');
  const self = await f.command(player.token, 'growth.create_member', {
    role: 'self', name: '本人', profile: { title: '修士', avatar: 'male' }, request_id: secret(),
  });
  const body = { cultivator_id: self.cultivator_id, date: dayKey(f.now()) };
  const path = '/api/v2/ptds/confirm';
  assert.equal((await f.request(path, body)).status, 401);
  assert.equal((await f.request(path, body, other.token)).status, 404);
  assert.equal((await f.request(path, { ...body, steps: 8421 }, player.token)).status, 400);
  assert.equal((await f.request(path, { ...body, date: '2026-10-30' }, player.token)).status, 400);
  const first = await f.ok(path, body, player.token);
  const retry = await f.ok(path, body, player.token);
  assert.equal(first.verification_level, 'self_report');
  assert.equal(first.spirit_stones, 100);
  assert.equal(first.realm_xp, 10);
  assert.equal(first.seals, 1);
  assert.deepEqual(retry, first);
  const snapshot = await f.command(player.token, 'growth.snapshot', { cultivator_id: self.cultivator_id });
  assert.equal(snapshot.resources.spirit_stones, self.resources.spirit_stones + 100);
  assert.equal(snapshot.days, 1);
  f.advance(86400);
  const next = await f.ok(path, { ...body, date: dayKey(f.now()) }, player.token);
  assert.notEqual(next.settlement_id, first.settlement_id);
});

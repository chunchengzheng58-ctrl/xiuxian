import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { buildApp } from '../src/app.js';
import { repositoryRoot } from '../src/contracts.js';
import { fixture } from './helpers.js';

test('游玩日按北京时间跨天累加，同日并发或重登去重，且不发健康奖励', async context => {
  const app = await fixture(context);
  const player = await app.account('playdays_player');
  const other = await app.account('playdays_other');
  const character = await app.character(player.token);
  const path = '/api/v2/play-days';
  assert.equal((await app.request(path, {})).status, 401);
  assert.equal((await app.request(path, { day: '2099-01-01' }, player.token)).status, 400);
  const credentials = { username: 'playdays_player', password: 'a-secure-password-123' };
  const secondSession = await app.ok('/api/v2/auth/login', credentials);
  const record = (token = player.token) => app.ok(path, {}, token);
  assert.deepEqual(await Promise.all([record(), record(secondSession.token)]), [{ play_days: 1 }, { play_days: 1 }]);
  app.advance(14 * 3600 - 1);
  assert.deepEqual(await record(), { play_days: 1 });
  app.advance(1);
  assert.deepEqual(await record(), { play_days: 2 });
  assert.deepEqual(await record(other.token), { play_days: 1 });
  app.advance(2 * 86400);
  assert.deepEqual(await record(), { play_days: 3 });
  assert.equal(app.game.characterSnapshot(player.account_id, character.cultivator_id).days, 0);
  assert.equal(app.db.get<{ count: number }>('SELECT COUNT(*) AS count FROM ledger')?.count, 0);
});

test('同一存档关闭并重新打开后，累计游玩天数仍保留', async () => {
  const base = join(repositoryRoot, 'work/play-days-tests');
  mkdirSync(base, { recursive: true });
  const path = join(mkdtempSync(join(base, 'days-')), 'game.sqlite');
  let now = Date.parse('2026-11-01T23:59:59+08:00') / 1000;
  const options = { databasePath: path, now: () => now, worker: false };
  const credentials = { username: 'persisted_playdays', password: 'playdays-persistence-test' };
  async function record(register: boolean) {
    const server = await buildApp(options);
    try {
      if (register) await server.auth.register(credentials);
      const session = await server.auth.login(credentials);
      const result = await server.app.inject({ method: 'POST', url: '/api/v2/play-days', payload: {}, headers: { authorization: `Bearer ${session.token}` } });
      assert.equal(result.statusCode, 200);
      return result.json().data.play_days;
    } finally { await server.app.close(); }
  }
  assert.equal(await record(true), 1);
  assert.equal(await record(false), 1);
  now += 1;
  assert.equal(await record(false), 2);
});

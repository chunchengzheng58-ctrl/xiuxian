import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdirSync, mkdtempSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { repositoryRoot } from '../src/contracts.js';
import { digest, secret } from '../src/core.js';
import { Database } from '../src/database.js';
import { CharacterProgression, campaignConfig } from '../src/game/character-progression.js';
import type { Character } from '../src/game/rules.js';
import { fixture } from './helpers.js';

test('历练首通与重试奖励来自真实战斗，升级计入入场基础值，健康与公平论剑不受影响', async context => {
  const app = await fixture(context);
  const account = await app.account('progress_player');
  const member = await app.command(account.token, 'growth.create_member', { role: 'self', name: '行者', profile: { title: '行者', avatar: 'male' }, request_id: secret() });
  const cid = member.cultivator_id as string;
  const actor = () => app.game.own(account.account_id, cid);
  const duelBefore = app.game.arena.lobby(actor());
  assert.equal(app.game.adventure.view(actor()).level, 1);
  const battle = () => {
    const run = app.game.execute(account.account_id, 'combat.expedition_start', { cultivator_id: cid, stage_id: 'b01' }, secret()) as { run_id: string };
    const subscription = app.game.expedition.subscribe(account.account_id, run.run_id);
    app.game.expedition.connect(subscription, true);
    for (let tick = 1; tick < 5000; tick++) {
      const state = app.game.expedition.state(subscription)!;
      if (state.result) return { run, result: state.result };
      const dx = state.enemy.x - state.player.x, dy = state.enemy.y - state.player.y, distance = Math.hypot(dx, dy);
      let action = distance < 120 ? 1 : 0;
      if (state.player.hp < state.player.max_hp * 0.6 && state.player.cd[5] === 0 && state.player.mp >= 40) action = 5;
      else if (state.player.cd[4] === 0 && state.player.mp >= 24 && state.telegraphs.some(effect => effect.remaining < 0.24)) action = 4;
      app.game.expedition.input(subscription, { seq: tick, x: distance > 95 ? dx / Math.max(1, distance) : 0, y: distance > 95 ? dy / Math.max(1, distance) : 0, action });
      app.game.expedition.step(1);
    }
    throw new Error('Actual battle did not finish');
  };
  const first = battle();
  assert.equal(first.result.won, true);
  assert.equal(first.result.reward.adventure_xp, 120);
  assert.equal(app.game.adventure.view(actor()).level, 2);
  assert.equal(app.game.adventure.view(actor()).cleared_count, 1);
  assert.equal(app.game.adventure.view(actor()).seal_count, 0);
  assert.deepEqual(app.game.adventure.view(actor()).base_stats, { life: 108, attack: 13, defense: 0, spirit: 102, stamina: 102 });
  app.game.expedition.leave(actor(), first.run.run_id);
  app.game.expedition.leave(actor(), first.run.run_id);
  assert.equal(app.game.adventure.view(actor()).xp, 120);
  const repeated = battle();
  assert.equal(repeated.result.reward.adventure_xp, 15);
  assert.equal(app.game.adventure.view(actor()).xp, 135);
  const preview = app.game.expedition.lobby(actor()).loadout;
  assert.deepEqual(preview.stats, { life: 108, attack: 13, defense: 0, spirit: 102, stamina: 102 });
  const run = app.game.execute(account.account_id, 'combat.expedition_start', { cultivator_id: cid, stage_id: 'b01' }, secret()) as { run_id: string; stats: { life: number; attack: number } };
  assert.deepEqual(run.stats, preview.stats, 'Displayed next-entry preview matches the authoritative battle');
  assert.equal(run.stats.life, 108);
  assert.equal(run.stats.attack, 13);
  app.game.expedition.leave(actor(), run.run_id);
  await app.command(account.token, 'growth.equip', { cultivator_id: cid, equipment_id: first.result.reward.equipment!.equipment_id, slot: 'weapon' }, secret());
  const equipped = app.game.expedition.lobby(actor()).loadout;
  assert.equal(equipped.base_stats.attack, 13);
  assert.ok(equipped.stats.attack > preview.stats.attack, 'Preview includes the actually earned and equipped sword');
  const armed = app.game.execute(account.account_id, 'combat.expedition_start', { cultivator_id: cid, stage_id: 'b01' }, secret()) as { run_id: string; stats: unknown };
  assert.deepEqual(armed.stats, equipped.stats, 'Equipped preview and subsequent battle remain aligned');
  app.game.expedition.leave(actor(), armed.run_id);
  assert.equal(app.game.adventure.view(actor()).xp, 135);
  assert.equal(actor().realm_xp, 0);
  assert.equal(app.db.get<{ count: number }>('SELECT COUNT(*) AS count FROM baselines WHERE cultivator_id=?', cid)!.count, 0);
  assert.deepEqual(app.game.arena.lobby(actor()), duelBefore);
});

test('v9旧档无损追加迁移，旧三关历练只补记一次，二十关约束与外键完整', () => {
  const base = join(repositoryRoot, 'work/progression-migration-tests');
  mkdirSync(base, { recursive: true });
  const path = join(mkdtempSync(join(base, 'v9-')), 'fixture.sqlite');
  const migrations = Array.from(readFileSync(join(repositoryRoot, 'server/src/database.ts'), 'utf8').matchAll(/String\.raw`([\s\S]*?)`/g), match => match[1]!);
  const old = new DatabaseSync(path);
  old.exec('PRAGMA foreign_keys=ON; CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY,checksum TEXT NOT NULL)');
  for (let index = 0; index < 9; index++) {
    old.exec(migrations[index]!);
    old.prepare('INSERT INTO schema_migrations VALUES (?,?)').run(index + 1, digest(migrations[index]!));
  }
  old.exec('PRAGMA user_version=9');
  old.prepare("INSERT INTO accounts (id,username,password_hash,salt,created_at) VALUES ('a','legacy_fixture','test','salt',1)").run();
  old.prepare(`INSERT INTO cultivators (id,account_id,name,element,created_at,role,profile,spirit_stones,materials,pity,legendary_pity)
    VALUES ('c','a','旧档','earth',1,'self','{"avatar":"male"}',1234,42,7,23)`).run();
  old.prepare(`INSERT INTO equipment (id,cultivator_id,catalogue_id,catalogue_version,slot,rarity,school,upgrade_level)
    VALUES ('gear','c','pixel:0','pixel-equipment-v1','weapon','epic',2,3)`).run();
  for (const stageId of ['b01', 'b02', 'b03']) {
    old.prepare(`INSERT INTO expedition_runs (id,cultivator_id,stage_id,avatar,stats,lifecycle_version,started_at,expires_at,finished_at,result)
      VALUES (?, 'c', ?, 'male', '{}', 0, 1, 2, 2, '{"won":true}')`).run('run-' + stageId, stageId);
    old.prepare("INSERT INTO expedition_clears VALUES ('c',?,?,250,2)").run(stageId, 'run-' + stageId);
  }
  const oldCharacter = old.prepare("SELECT * FROM cultivators WHERE id='c'").get();
  const oldGear = old.prepare('SELECT * FROM equipment').all();
  const oldRuns = old.prepare('SELECT * FROM expedition_runs ORDER BY id').all();
  const oldClears = old.prepare('SELECT * FROM expedition_clears ORDER BY stage_id').all();
  old.close();
  const db = new Database(path);
  try {
    assert.equal(db.get<{ user_version: number }>('PRAGMA user_version')!.user_version, 14);
    assert.deepEqual(db.all<{ day: string }>("SELECT day FROM account_play_days WHERE account_id='a'").map(row => row.day), ['1970-01-01']);
    assert.deepEqual(db.get("SELECT * FROM cultivators WHERE id='c'"), oldCharacter);
    assert.deepEqual(db.all('SELECT * FROM equipment'), oldGear);
    assert.deepEqual(db.all('SELECT * FROM expedition_runs ORDER BY id'), oldRuns);
    assert.deepEqual(db.all('SELECT * FROM expedition_clears ORDER BY stage_id'), oldClears);
    assert.deepEqual(db.all('PRAGMA foreign_key_check'), []);
    const progress = new CharacterProgression(db, () => 5);
    assert.equal(progress.view(db.get<Character>("SELECT * FROM cultivators WHERE id='c'")!).xp, 560);
    for (const stage of campaignConfig.stages) {
      if (['b01', 'b02', 'b03'].includes(stage.stage_id)) continue;
      db.run(`INSERT INTO expedition_runs (id,cultivator_id,stage_id,avatar,stats,lifecycle_version,started_at,expires_at,finished_at)
        VALUES (?,'c',?,'male','{}',0,3,4,4)`, 'run-' + stage.stage_id, stage.stage_id);
    }
    assert.throws(() => db.run(`INSERT INTO expedition_runs (id,cultivator_id,stage_id,avatar,stats,lifecycle_version,started_at,expires_at)
      VALUES ('invalid','c','b20','male','{}',0,3,4)`));
    assert.equal(db.get<{ count: number }>('SELECT COUNT(*) AS count FROM expedition_runs')!.count, 20);
  } finally { db.close(); }
  const reopened = new Database(path);
  try { assert.equal(reopened.get<{ xp: number }>('SELECT SUM(amount) AS xp FROM adventure_awards')!.xp, 560); }
  finally { reopened.close(); }
});

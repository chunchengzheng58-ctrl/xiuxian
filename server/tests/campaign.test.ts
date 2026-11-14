import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { buildApp } from '../src/app.js';
import { repositoryRoot } from '../src/contracts.js';
import { secret } from '../src/core.js';
import { arenaBounds, type ArenaInput } from '../src/game/arena-match.js';
import { campaignConfig } from '../src/game/character-progression.js';
import type { ExpeditionService } from '../src/game/expedition.js';
import { pixelRarities } from '../src/game/rules.js';
import { fixture } from './helpers.js';

type Point = { x: number; y: number };
type VisibleShape = Point & { kind: string; radius?: number; x2?: number; y2?: number; width?: number; polygons?: number[][][]; remaining?: number };
type BattleState = NonNullable<ReturnType<ExpeditionService['state']>>;
type InventoryGear = { equipment_id: string; slot: string; rarity: string; equipped: number; upgrade_level: number };
const clamp = (n: number, low: number, high: number) => Math.max(low, Math.min(high, n));
const distance = (a: Point, b: Point) => Math.hypot(a.x - b.x, a.y - b.y);
const signatures = JSON.parse(readFileSync(join(repositoryRoot, 'data/combat/pr4_boss_signatures.json'), 'utf8')) as Record<string, { move: string }>;

function inPolygon(point: Point, polygon: number[][]) {
  let inside = false;
  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    const a = polygon[i]!, b = polygon[j]!;
    if ((a[1]! > point.y) !== (b[1]! > point.y)
      && point.x < (b[0]! - a[0]!) * (point.y - a[1]!) / (b[1]! - a[1]!) + a[0]!) inside = !inside;
  }
  return inside;
}
function unsafe(shape: VisibleShape, point: Point) {
  if (shape.kind === 'polygon') return shape.polygons?.some(polygon => inPolygon(point, polygon)) ?? false;
  if (shape.kind === 'circle') return distance(shape, point) < (shape.radius ?? 0) + 10;
  const dx = (shape.x2 ?? shape.x) - shape.x, dy = (shape.y2 ?? shape.y) - shape.y;
  const fraction = clamp(((point.x - shape.x) * dx + (point.y - shape.y) * dy) / Math.max(1, dx * dx + dy * dy), 0, 1);
  return Math.hypot(point.x - shape.x - dx * fraction, point.y - shape.y - dy * fraction) < (shape.width ?? 0) / 2 + 10;
}

// This driver sees exactly the public combat state. It walks to a clear place,
// attacks in range and spends normal cooldowns/mana. No health, boss or reward
// writes and no calls to the engine's finish() shortcut are used.
function intention(state: BattleState, sequence: number): ArenaInput {
  const player = state.player, enemy = state.enemy;
  const warnings = state.telegraphs as unknown as VisibleShape[];
  const hazards = state.hazards as unknown as VisibleShape[];
  const projectiles = (state as BattleState & { enemy_projectiles?: (Point & { radius: number })[] }).enemy_projectiles ?? [];
  const threats = [...warnings, ...hazards];
  const candidates: Point[] = [player];
  for (let angle = 0; angle < Math.PI * 2; angle += Math.PI / 8) {
    for (const radius of [96, 190]) candidates.push({ x: clamp(enemy.x + Math.cos(angle) * radius, 235, 1205), y: clamp(enemy.y + Math.sin(angle) * radius, 405, 700) });
  }
  for (let x = 245; x < 1220; x += 120) for (let y = 410; y < 715; y += 70) candidates.push({ x, y });
  const score = (point: Point) => {
    const travel = distance(player, point);
    let risk = threats.filter(shape => unsafe(shape, point)).length * 10000;
    risk += projectiles.filter(shot => distance(shot, point) < shot.radius + 40).length * 5000;
    // The reachable part of a route at a warning's impact also has to be clear.
    for (const warning of warnings) {
      const movement = Math.min(1, Math.max(0, (warning.remaining ?? 0) - 0.12) * 210 / Math.max(1, travel));
      if (unsafe(warning, { x: player.x + (point.x - player.x) * movement, y: player.y + (point.y - player.y) * movement })) risk += 3000;
    }
    return risk + travel * 0.8 + Math.abs(distance(point, enemy) - 96) * 1.6;
  };
  const destination = candidates.reduce((best, point) => score(point) < score(best) ? point : best, candidates[0]!);
  const moving = distance(player, destination) > 5;
  const dx = moving ? destination.x - player.x : enemy.x - player.x;
  const dy = moving ? destination.y - player.y : enemy.y - player.y;
  const length = Math.max(1, Math.hypot(dx, dy));
  // A tiny movement faces the enemy without walking out of melee range.
  const speed = moving ? 1 : distance(player, enemy) > 128 ? 1 : 0.05;
  const danger = warnings.some(shape => (shape.remaining ?? 10) < 0.32 && unsafe(shape, player));
  const safeToHeal = !warnings.some(shape => (shape.remaining ?? 10) < 1.2 && unsafe(shape, player))
    && !hazards.some(shape => unsafe(shape, player)) && projectiles.every(shot => distance(shot, player) > 150);
  const facingEnemy = dx * (enemy.x - player.x) + dy * (enemy.y - player.y) > 0;
  let action = distance(player, enemy) < 126 && facingEnemy ? 1 : 0;
  if (player.hp < player.max_hp * 0.64 && player.cd[5] === 0 && player.mp >= 40 && safeToHeal) action = 5;
  else if (danger && player.cd[3] === 0 && player.stamina >= 24 && moving) action = 3;
  else if (danger && player.cd[4] === 0 && player.mp >= 24) action = 4;
  else if (distance(player, enemy) > 145 && distance(player, enemy) < 520 && facingEnemy && player.cd[2] === 0 && player.mp > 65) action = 2;
  return { seq: sequence, x: dx / length * speed, y: dy / length * speed, action };
}

function actualBattle(service: ExpeditionService, account: string, runId: string) {
  const subscription = service.subscribe(account, runId);
  service.connect(subscription, true);
  let observedWarnings = 0;
  let previousHp = 0, damageTaken = 0, healing = 0, lastPhase = '';
  const moveStarts: { move_id: string; stage: number; seconds: number; executed: boolean }[] = [];
  const attacks = new Set<string>();
  for (let tick = 1; tick < 4600; tick++) {
    const state = service.state(subscription)!;
    assert.ok(Number.isFinite(state.enemy.hp) && state.enemy.max_hp > 0, 'A real configured enemy exists');
    assert.ok(state.player.x >= arenaBounds.left && state.player.x <= arenaBounds.right);
    assert.ok(state.player.y >= arenaBounds.top && state.player.y <= arenaBounds.bottom);
    if (previousHp) {
      damageTaken += Math.max(0, previousHp - state.player.hp);
      healing += Math.max(0, state.player.hp - previousHp);
    }
    previousHp = state.player.hp;
    if (state.result) return { result: state.result, warnings: observedWarnings, bossMaxHp: state.enemy.max_hp, damageTaken, healing,
      moveStarts, attacks: [...attacks] };
    const mechanic = state.mechanic;
    if (mechanic.phase === 'windup' && lastPhase !== 'windup') moveStarts.push({ move_id: mechanic.move_id, stage: mechanic.stage, seconds: state.tick * 0.04, executed: false });
    if (mechanic.phase === 'attack') {
      attacks.add(`${mechanic.move_id}:${mechanic.stage}`);
      const lastMove = moveStarts.at(-1);
      if (lastMove?.move_id === mechanic.move_id) lastMove.executed = true;
    }
    lastPhase = mechanic.phase;
    observedWarnings += state.telegraphs.length;
    service.input(subscription, intention(state, tick));
    service.step(1);
  }
  throw new Error('Real authoritative battle exceeded its 180-second limit');
}

test('完整主线自然养成：新账号仅用所得通关二十个正式Boss，章节结局和装备在重启后保留', { timeout: 180_000 }, async context => {
  const base = join(repositoryRoot, 'work/campaign-natural-tests');
  mkdirSync(base, { recursive: true });
  const work = mkdtempSync(join(base, 'natural-'));
  const path = join(work, 'game.sqlite');
  const app = await fixture(context, { databasePath: path });
  const account = await app.account('campaign_player');
  const actor = await app.command(account.token, 'growth.create_member', { role: 'self', name: '守灯客', profile: { title: '守灯客', avatar: 'female' }, request_id: secret() });
  const cid = actor.cultivator_id as string;
  const command = (name: string, fields: object = {}) => app.command(account.token, name, { cultivator_id: cid, ...fields }, secret());
  const snapshot = () => app.game.characterSnapshot(account.account_id, cid);
  assert.equal(snapshot().resources.spirit_stones, 0);
  assert.equal(snapshot().resources.materials, 0);
  assert.equal(snapshot().equipment.length, 0);
  assert.equal(snapshot().adventure!.level, 1);
  const chapterReceipts: string[] = [];
  const claimAvailable = async () => {
    for (let n = 0; n < 40; n++) {
      const story = await command('story.snapshot');
      const node = story.chapters.flatMap((chapter: any) => chapter.nodes).find((row: any) => row.available && !row.completed);
      if (!node) return;
      await command('story.advance', { node_id: node.id });
      chapterReceipts.push(node.id);
    }
    assert.fail('Story never reached a stable objective');
  };
  const rarityIndex = (rarity: unknown) => (pixelRarities as readonly unknown[]).indexOf(rarity);
  const gear = async (extraLevel = 0) => {
    // Replace lower rarity drops; upgrade only equipped pieces, paying each
    // published cost through the production command and real earned wallet.
    let state = snapshot();
    for (const slot of ['weapon', 'robe', 'boots', 'amulet']) {
      const options = (state.equipment as InventoryGear[]).filter(row => row.slot === slot);
      const best = options.sort((a, b) => rarityIndex(b.rarity) - rarityIndex(a.rarity) || Number(b.upgrade_level) - Number(a.upgrade_level))[0];
      if (best && !best.equipped) await command('growth.equip', { equipment_id: best.equipment_id, slot });
    }
    state = snapshot();
    const targetLevel = Math.min(6, Math.ceil(state.adventure!.level / 3) + extraLevel);
    for (const piece of (state.equipment as InventoryGear[]).filter(row => row.equipped).sort((a, b) => (a.slot === 'weapon' ? -1 : 1) - (b.slot === 'weapon' ? -1 : 1))) {
      let level = Number(piece.upgrade_level);
      while (level < targetLevel) {
        const wallet = snapshot().resources;
        if (wallet.materials < (level + 1) * 2 || wallet.spirit_stones < (level + 1) * 10) break;
        await command('growth.upgrade', { equipment_id: piece.equipment_id, expected_level: level });
        level++;
      }
    }
  };
  const report: Record<string, unknown>[] = [];
  // Core campaign first, then optional tutorial and the two side tales. A new
  // tutorial must not retroactively prevent returning players entering b01.
  const order = Array.from({ length: 19 }, (_, i) => 'b' + String(i + 1).padStart(2, '0'));
  order.push('b00');
  for (const stageId of order) {
    await claimAvailable();
    await gear();
    const before = snapshot();
    const run = await command('combat.expedition_start', { stage_id: stageId });
    assert.equal(run.base_stats.attack, before.adventure!.base_stats.attack);
    assert.equal(run.stats.attack, run.base_stats.attack + before.equipment_bonuses.attack);
    const battle = actualBattle(app.game.expedition, account.account_id, run.run_id);
    const result = battle.result;
    report.push({ stage: stageId, won: result.won, reason: result.reason, level: run.adventure_level, stats: run.stats, boss_max_hp: battle.bossMaxHp,
      hp: result.hp, seconds: result.duration_seconds, warnings: battle.warnings, damage_taken: battle.damageTaken, healing: battle.healing,
      move_starts: battle.moveStarts, attacks: battle.attacks, reward: result.reward,
      wallet: snapshot().resources, equipped: (snapshot().equipment as InventoryGear[]).filter(row => row.equipped) });
    writeFileSync(join(work, 'natural-progression.json'), JSON.stringify({ passed: false, battles: report }, null, 2));
    assert.equal(result.won, true, `${stageId} must be beatable with naturally earned equipment and visible tells; ${JSON.stringify(report.at(-1))}`);
    assert.equal(result.enemy_hp, 0);
    assert.equal(result.reward.first_clear, true);
    assert.ok(result.reward.adventure_xp > 0);
    if (stageId !== 'b00') assert.ok(battle.warnings > 0, `${stageId} includes real telegraphed boss actions`);
    if (Number(stageId.slice(1)) >= 4) {
      assert.equal(new Set(battle.moveStarts.filter(move => move.executed).map(move => move.move_id)).size, 3,
        `${stageId} should live through all three distinct attacks on a natural first-clear route`);
      assert.ok(battle.moveStarts.some(move => move.executed && move.stage === 2 && move.move_id === signatures[stageId]!.move),
        `${stageId} should execute its final-phase identity mechanic, beyond merely starting a warning`);
    }
    const earned = snapshot();
    await command('combat.expedition_leave', { run_id: run.run_id });
    await command('combat.expedition_leave', { run_id: run.run_id });
    assert.deepEqual(snapshot().resources, earned.resources, 'Reopening an already settled result does not grant again');
    assert.equal(snapshot().adventure!.xp, earned.adventure!.xp);
  }
  await claimAvailable();
  const story = await command('story.snapshot');
  const final = snapshot();
  assert.equal(story.cleared_count, 20);
  assert.equal(story.ending.completed, true);
  assert.equal(story.ending.all_twenty_cleared, true);
  assert.ok(story.ending.text.length > 0);
  assert.ok(story.chapters.every((chapter: any) => chapter.status === 'completed'));
  assert.equal(story.seals.length, 5);
  assert.ok(final.adventure!.level > 10);
  assert.equal(final.resources.realm_xp, 0, 'Adventure does not grant health-task cultivation');
  assert.deepEqual(app.db.all('SELECT * FROM baselines WHERE cultivator_id = ?', cid), []);
  assert.equal(app.db.get<{ count: number }>('SELECT COUNT(*) AS count FROM expedition_runs WHERE cultivator_id = ?', cid)!.count, 20, 'No repeated farming, gifted fixtures or debug victories needed');
  assert.ok(app.db.all<{ reason: string }>('SELECT DISTINCT reason FROM ledger WHERE cultivator_id = ?', cid)
    .every(row => ['expedition_clear', 'story_chapter', 'equipment_upgrade'].includes(row.reason)), 'Only combat, chapters and paid upgrades fund this route');
  const ledgerBefore = app.db.all('SELECT * FROM ledger WHERE cultivator_id = ? ORDER BY rowid', cid);
  const xpBefore = app.db.all('SELECT * FROM adventure_awards WHERE cultivator_id = ? ORDER BY rowid', cid);
  for (const chapter of story.chapters) for (const node of chapter.nodes) await command('story.advance', { node_id: node.id });
  assert.deepEqual(snapshot(), final, 'All dialogue replays are free of duplicate XP, items or currency');
  assert.deepEqual(app.db.all('SELECT * FROM ledger WHERE cultivator_id = ? ORDER BY rowid', cid), ledgerBefore);
  assert.deepEqual(app.db.all('SELECT * FROM adventure_awards WHERE cultivator_id = ? ORDER BY rowid', cid), xpBefore);
  await app.app.close();
  const restarted = await buildApp({ worker: false, databasePath: path, now: app.now });
  try {
    assert.deepEqual(restarted.game.characterSnapshot(account.account_id, cid), final);
    assert.deepEqual(JSON.parse(JSON.stringify(restarted.game.execute(account.account_id, 'story.snapshot', { cultivator_id: cid }))), story);
    assert.equal(restarted.auth.authenticate(`Bearer ${account.token}`).account_id, account.account_id);
    assert.deepEqual(restarted.db.all('PRAGMA foreign_key_check'), []);
  } finally { await restarted.app.close(); }
  const inputs = Object.fromEntries(['data/adventure-campaign.v1.json', 'data/combat/pr4_boss_signatures.json', 'server/src/game/expedition-match.ts', 'server/src/game/character-progression.ts']
    .map(name => [name, createHash('sha256').update(readFileSync(join(repositoryRoot, name))).digest('hex')]));
  const output = { passed: true, testedAt: new Date().toISOString(), work, inputs,
    method: 'new authenticated account; real movement/skill inputs and authoritative ticks; no fixture grants, direct victory calls or repeat farming',
    driver: 'public-state position/telegraph-aware bot with no input latency; this is not a human difficulty study',
    battles: report, chapters: chapterReceipts, ending: story.ending, final: final.adventure, wallet: final.resources };
  writeFileSync(join(work, 'natural-progression.json'), JSON.stringify(output, null, 2));
  context.diagnostic(JSON.stringify({ report: join(work, 'natural-progression.json'), clears: 20, level: final.adventure!.level,
    battleSeconds: report.reduce((sum, row) => sum + Number(row.seconds), 0), resources: final.resources }));
});

test('主线权威目标：旧练习声称通关不推进结局，未知节点与越章领取不会产出', async context => {
  const app = await fixture(context);
  const account = await app.account('campaign_boundary');
  const member = await app.command(account.token, 'growth.create_member', { role: 'self', name: '行者', profile: { title: '行者', avatar: 'male' }, request_id: secret() });
  const cid = member.cultivator_id as string;
  const send = (name: string, fields: object = {}) => app.command(account.token, name, { cultivator_id: cid, ...fields }, secret());
  const denied = async (nodeId: string) => app.request('/api/v2/commands', { version: 1, command: 'story.advance', payload: { cultivator_id: cid, node_id: nodeId } }, account.token, 'POST', secret());
  const before = app.game.characterSnapshot(account.account_id, cid);
  assert.equal((await denied('finale.closure')).body.code, 'STORY_LOCKED');
  assert.equal((await denied('wood.closure')).body.code, 'STORY_LOCKED');
  assert.equal((await denied('inexistent.node')).body.code, 'STORY_NODE_UNKNOWN');
  await send('story.advance', { node_id: 'wood.intro' });
  for (const stage of campaignConfig.stages) {
    const practice = await send('combat.start', { encounter_id: stage.stage_id });
    app.advance(10);
    await app.command(account.token, 'combat.finish', { session_id: practice.session_id, won: true, duration_seconds: 10 });
  }
  const story = await send('story.snapshot');
  assert.equal(story.cleared_count, 0);
  assert.equal(story.ending.completed, false);
  assert.equal(story.ending.unlocked, false);
  assert.equal((await denied('wood.closure')).body.code, 'STORY_LOCKED');
  assert.equal((await denied('finale.closure')).body.code, 'STORY_LOCKED');
  const after = app.game.characterSnapshot(account.account_id, cid);
  assert.deepEqual(after.resources, before.resources);
  assert.deepEqual(after.adventure, before.adventure);
  assert.deepEqual(after.equipment, before.equipment);
  assert.deepEqual(app.db.all('SELECT * FROM expedition_clears WHERE cultivator_id = ?', cid), []);
  assert.deepEqual(app.db.all('SELECT * FROM ledger WHERE cultivator_id = ?', cid), []);
});

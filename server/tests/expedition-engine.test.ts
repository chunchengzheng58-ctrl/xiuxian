import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { repositoryRoot } from '../src/contracts.js';
import { arenaBounds, type FighterStats } from '../src/game/arena-match.js';
import { campaignConfig } from '../src/game/character-progression.js';
import { ExpeditionMatch, expeditionShapeContains, type ExpeditionShape, type ExpeditionStageId } from '../src/game/expedition-match.js';

const starter: FighterStats = { life: 100, attack: 12, defense: 0, spirit: 100, stamina: 100 };
const stages = campaignConfig.stages;
const signatures = JSON.parse(readFileSync(join(repositoryRoot, 'data/combat/pr4_boss_signatures.json'), 'utf8')) as Record<string, { move: string; beats: { label: string }[] }>;
const definitions = JSON.parse(readFileSync(join(repositoryRoot, 'data/combat/pr4_boss_moves.json'), 'utf8')) as { bosses: Record<string, { moves: { id: string; kind: string }[] }> };
function step(match: ExpeditionMatch, count: number) { for (let i = 0; i < count; i++) match.step(); }
function ready(id: string, stats = { ...starter, life: 100_000 }) {
  const match = new ExpeditionMatch(id as ExpeditionStageId, stats);
  match.connect(true); step(match, 50);
  assert.equal(match.phase, 'fighting');
  return match;
}
function firstWarning(match: ExpeditionMatch, filter = (_state: ReturnType<ExpeditionMatch['state']>) => true) {
  for (let i = 0; i < 4200; i++) {
    const state = match.state();
    if (state.telegraphs.length && filter(state)) return state;
    match.step();
  }
  throw new Error('Expected a readable warning');
}

test('20关真正执行60招，五域签名、投射物、三阶段和共享战力均进入权威时间线', () => {
  const seenMoves = new Set<string>();
  const signatureIds = new Set<string>();
  const kinds = new Set<string>();
  let sawProjectile = false;
  for (const stage of stages) {
    const bossMoves = new Set<string>(), labels = new Set<string>();
    for (const phase of [0, 1, 2]) {
      const match = ready(stage.stage_id);
      match.enemy.hp = Math.round(match.enemy.maxHp * [1, 0.6, 0.25][phase]!);
      for (let i = 0; i < 2600; i++) {
        const state = match.state();
        if (state.mechanic.phase === 'windup') bossMoves.add(state.mechanic.move_id);
        for (const effect of state.telegraphs) {
          labels.add(effect.label);
          assert.ok(effect.total >= 0.68, `${stage.stage_id}: each follow-up has a readable warning`);
          assert.ok(effect.remaining > 0 && effect.remaining <= effect.total);
          if (effect.kind === 'polygon') assert.ok(effect.polygons!.every(polygon => polygon.length >= 3 && polygon.every(point => point.every(Number.isFinite))));
        }
        sawProjectile ||= state.enemy_projectiles.length > 0;
        match.step();
        assert.ok(match.enemy.x >= arenaBounds.left && match.enemy.x <= arenaBounds.right);
        assert.ok(match.enemy.y >= arenaBounds.top && match.enemy.y <= arenaBounds.bottom);
      }
      assert.equal(match.state().mechanic.stage, phase);
      assert.equal(match.enemy.maxHp, stage.battle.life);
      assert.equal(match.enemy.attack, stage.battle.attack);
      match.finish(false, 'forfeit');
      assert.equal(match.telegraphs.length + match.projectiles.length + match.hazards.length, 0, 'Finished encounters clear damaging objects');
    }
    for (const move of definitions.bosses[stage.stage_id]!.moves) {
      assert.ok(bossMoves.has(move.id), `${stage.stage_id}: authored move ${move.id} must occur, not only a renamed generic attack`);
      seenMoves.add(move.id); kinds.add(move.kind);
    }
    if (signatures[stage.stage_id]) {
      for (const beat of signatures[stage.stage_id]!.beats) assert.ok(labels.has(beat.label), `${stage.stage_id}: signature beat ${beat.label} occurs`);
      signatureIds.add(signatures[stage.stage_id]!.move);
    }
  }
  assert.equal(seenMoves.size, 60);
  assert.equal(kinds.size, 8);
  assert.equal(signatureIds.size, 19, 'Wood heart uses its separate sap-drain mechanic');
  assert.ok(sawProjectile, 'Volleys must create travelling projectiles rather than instantaneous damage');
});

test('预警目标和计时在角色移动/跨阶段后保持锁定，断线冻结整条机制时间线', () => {
  const match = ready('b19');
  const initial = firstWarning(match);
  const shapes = initial.telegraphs.map(({ remaining: _remaining, ...shape }) => shape);
  match.enemy.hp = Math.floor(match.enemy.maxHp * 0.2);
  for (let i = 1; i <= 8; i++) { match.input({ seq: i, x: -1, y: -1, action: 0 }); match.step(); }
  assert.deepEqual(match.state().telegraphs.map(({ remaining: _remaining, ...shape }) => shape), shapes);
  assert.equal(match.state().telegraphs[0]!.remaining, initial.telegraphs[0]!.remaining - 0.32);
  assert.equal(match.state().mechanic.stage, 2);
  match.connect(false);
  const frozen = match.state();
  step(match, 200);
  const disconnected = match.state();
  assert.equal(disconnected.phase, 'reconnecting');
  assert.deepEqual(disconnected.telegraphs, frozen.telegraphs);
  assert.deepEqual(disconnected.enemy_projectiles, frozen.enemy_projectiles);
  assert.deepEqual(disconnected.hazards, frozen.hazards);
  assert.equal(disconnected.player.hp, frozen.player.hp);
  assert.equal(disconnected.player.mp, frozen.player.mp);
  assert.equal(disconnected.enemy.x, frozen.enemy.x);
  match.connect(true); step(match, 1);
  assert.equal(match.phase, 'fighting');
  match.connect(false); step(match, 175);
  assert.deepEqual(match.result, { won: false, reason: 'disconnect' });
  const completed = match.state(); step(match, 100);
  assert.deepEqual(match.state(), completed, 'No ghost damage, lingering movement or extra outcome after completion');
});

test('伤害使用送给客户端的同一几何，环心/风道与预警边外真正安全', () => {
  const ring = ready('b00');
  ring.enemy.hp = Math.floor(ring.enemy.maxHp * 0.2);
  const state = firstWarning(ring, snapshot => snapshot.telegraphs.some(effect => effect.label === '一响 · 避开雷环'));
  const warning = state.telegraphs.find(effect => effect.label === '一响 · 避开雷环')!;
  assert.equal(warning.kind, 'polygon');
  assert.equal(expeditionShapeContains(warning, [warning.x, warning.y]), false, 'Hollow ring center is safe');
  const piece = warning.polygons![0]!;
  const inside: [number, number] = [piece.reduce((sum, p) => sum + p[0], 0) / piece.length, piece.reduce((sum, p) => sum + p[1], 0) / piece.length];
  assert.equal(expeditionShapeContains(warning, inside), true);
  const circle: ExpeditionShape = { kind: 'circle', x: 500, y: 500, radius: 100 };
  assert.equal(expeditionShapeContains(circle, [600, 500]), true);
  assert.equal(expeditionShapeContains(circle, [600.001, 500]), false, 'No invisible 18px hit margin');
  const line: ExpeditionShape = { kind: 'line', x: 300, y: 500, x2: 900, y2: 500, width: 60 };
  assert.equal(expeditionShapeContains(line, [600, 530]), true);
  assert.equal(expeditionShapeContains(line, [600, 530.001]), false);

  const hit = ready('b01', starter), evade = ready('b01', starter);
  firstWarning(hit); firstWarning(evade);
  const locked = hit.state().telegraphs[0]!;
  const beforeHit = hit.player.hp, beforeEvade = evade.player.hp;
  for (let i = 1; i <= Math.ceil(locked.remaining * 25); i++) {
    evade.input({ seq: i, x: -1, y: -1, action: 0 });
    hit.step(); evade.step();
  }
  assert.ok(hit.player.hp < beforeHit, 'Standing in the displayed circle takes actual damage');
  assert.equal(evade.player.hp, beforeEvade, 'Moving clear of the same warning avoids actual damage');
});

test('20关均可用合法输入击败，空站也能真实败北，结束后不会重复伤害', () => {
  for (const stage of stages) {
    // Mechanics fixture, not economy/progression evidence: the separate campaign
    // suite supplies actual earned gear and resources from a fresh account.
    const match = ready(stage.stage_id, { life: 1500, attack: 80, defense: 10, spirit: 180, stamina: 180 });
    for (let i = 1; i < 4450 && !match.result; i++) {
      const state = match.state(), dx = state.enemy.x - state.player.x, dy = state.enemy.y - state.player.y;
      const distance = Math.hypot(dx, dy);
      const action = distance < 120 ? 1 : state.player.cd[2] === 0 ? 2 : 0;
      match.input({ seq: i, x: distance > 95 ? dx / distance : 0, y: distance > 95 ? dy / distance : 0, action });
      match.step();
    }
    assert.equal(match.result?.won, true, `${stage.stage_id} must resolve victory through real attacks`);
    assert.equal(match.enemy.hp, 0);
    const result = match.result;
    match.finish(false, 'forfeit');
    assert.deepEqual(match.result, result);
  }
  const stationary = ready('b01', { ...starter, life: 20 });
  step(stationary, 1000);
  assert.deepEqual(stationary.result, { won: false, reason: 'knockout' });
});

test('冲撞沿锁定路线前进而非瞬移，飞扑在落地时才造成伤害', () => {
  const charge = ready('b02');
  const warning = firstWarning(charge).telegraphs[0]!;
  const start: [number, number] = [charge.enemy.x, charge.enemy.y];
  const end: [number, number] = [warning.x2!, warning.y2!];
  step(charge, Math.ceil(warning.remaining * 25));
  assert.ok(Math.hypot(charge.enemy.x - start[0], charge.enemy.y - start[1]) > 0);
  assert.ok(Math.hypot(charge.enemy.x - end[0], charge.enemy.y - end[1]) > 20, 'First active frame is still travelling');
  const moving = charge.state();
  charge.connect(false); step(charge, 80);
  assert.equal(charge.enemy.x, moving.enemy.x);
  assert.equal(charge.enemy.y, moving.enemy.y);
  charge.connect(true); step(charge, 20);
  assert.ok(Math.hypot(charge.enemy.x - end[0], charge.enemy.y - end[1]) < 0.001);

  const leap = ready('b00');
  const state = firstWarning(leap, snapshot => snapshot.mechanic.move_id === 'b00_1');
  const before = leap.player.hp;
  step(leap, Math.ceil(state.telegraphs[0]!.remaining * 25));
  assert.equal(leap.player.hp, before, 'Releasing the jump does not instantly damage the landing area');
  step(leap, 6);
  assert.equal(leap.player.hp, before, 'The visible airborne approach is harmless');
  step(leap, 12);
  assert.ok(leap.player.hp < before, 'Landing produces real damage inside the locked warning');
});

test('锁轴扣诀真实消耗灵力，及时护体可同时挡住伤害和封诀', () => {
  function locked(guard: boolean) {
    const match = ready('b02');
    match.enemy.hp = Math.floor(match.enemy.maxHp * 0.2);
    const state = firstWarning(match, snapshot => snapshot.telegraphs.some(effect => effect.label === '铁榫扣诀 · 向上或下走'));
    const warning = state.telegraphs.find(effect => effect.label === '铁榫扣诀 · 向上或下走')!;
    // Mechanics fixture: place the target inside the already published polygon.
    // No wallet, progression, rewards, stats or victory are edited here.
    const polygon = warning.polygons![0]!;
    match.player.x = polygon.reduce((sum, p) => sum + p[0], 0) / polygon.length;
    match.player.y = polygon.reduce((sum, p) => sum + p[1], 0) / polygon.length;
    step(match, Math.ceil(warning.remaining * 25) - 3);
    const hp = match.player.hp;
    if (guard) match.input({ seq: 1, x: 0, y: 0, action: 4 });
    step(match, 3);
    return { state: match.state(), hp };
  }
  const struck = locked(false), guarded = locked(true);
  assert.ok(struck.state.player.hp < struck.hp);
  assert.ok(struck.state.player.mp <= 82);
  assert.ok(struck.state.player.statuses.includes('seal'));
  assert.equal(guarded.state.player.hp, guarded.hp);
  assert.ok(guarded.state.player.mp >= 76, 'Only the normal guard cost is paid, not the on-hit seal penalty');
  assert.ok(!guarded.state.player.statuses.includes('seal'));
});

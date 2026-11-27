import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { repositoryRoot } from '../contracts.js';
import { campaignConfig } from './character-progression.js';
import { ArenaMatch, arenaBounds, arenaTickMs, type ArenaInput, type FighterStats } from './arena-match.js';

export const expeditionTickMs = arenaTickMs;
export type ExpeditionStageId = `b0${0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9}` | `b1${0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9}`;
export type ExpeditionResult = { won: boolean; reason: string };
type Point = [number, number];
export type ExpeditionShape = { kind: 'circle' | 'line' | 'polygon'; x: number; y: number; radius?: number;
  x2?: number; y2?: number; width?: number; polygons?: Point[][] };
type Effect = '' | 'slow' | 'fatigue' | 'seal' | 'pull' | 'launch' | 'drain';
type Decoration = { move_id: string; label: string; style: string };
type Telegraph = ExpeditionShape & Decoration & { ticks: number; total: number; damage: number; effect: Effect;
  residue: number; charge?: Point };
type Hazard = ExpeditionShape & Decoration & { ticks: number; damage: number; effect: Effect; pulse: number };
type Projectile = { x: number; y: number; vx: number; vy: number; radius: number; reach: number; damage: number; style: string };
type Motion = { kind: 'charge' | 'leap'; start: Point; end: Point; elapsed: number; duration: number;
  damage: number; width: number; shape: ExpeditionShape; spent: boolean };
type Beat = { at: number; stage?: number; shape: string; anchor: 'boss' | 'player' | 'arena' | 'mirror';
  radius?: Point; width?: number; offset?: Point; from?: Point; scale: number; label: string; effect?: Effect; residue?: number; style?: string };
type Signature = { move: string; name: string; tell: number; beats: Beat[] };
type Move = { id: string; name: string; kind: string; tell: number; active: number; recover: number; power: number; reach: number;
  width: number; radius: Point; style: string; min_stage: number; count?: number; spread?: number; speed?: number; residue?: number; drain_ratio?: number };
type Definition = { name: string; motion: string; speed: number; spacing: number; tempo: number; moves: Move[];
  progression: { speed: number; tell: number; min_tell: number; tempo: number; combo: number[]; waves: number[]; hazards: boolean } };
const definitions = JSON.parse(readFileSync(join(repositoryRoot, 'data/combat/pr4_boss_moves.json'), 'utf8')) as { bosses: Record<ExpeditionStageId, Definition> };
const signatures = JSON.parse(readFileSync(join(repositoryRoot, 'data/combat/pr4_boss_signatures.json'), 'utf8')) as Partial<Record<ExpeditionStageId, Signature>>;
const clamp = (value: number, min: number, max: number) => Math.min(max, Math.max(min, value));
const ticks = (seconds: number) => Math.ceil(seconds * 1000 / arenaTickMs);
const bound = ([x, y]: Point): Point => [clamp(x, arenaBounds.left, arenaBounds.right), clamp(y, arenaBounds.top, arenaBounds.bottom)];
const center: Point = [(arenaBounds.left + arenaBounds.right) / 2, (arenaBounds.top + arenaBounds.bottom) / 2];
// Transform the authored floor once. Rendered polygons and damage use these
// exact same points, including hollow rings, side lanes and cone boundaries.
const sx = (arenaBounds.right - arenaBounds.left) / 1080;
const sy = (arenaBounds.bottom - arenaBounds.top) / 222;
const offset = ([x, y]: Point): Point => [x * sx, y * sy];
const add = (a: Point, b: Point): Point => [a[0] + b[0], a[1] + b[1]];
const direction = (a: Point, b: Point): Point => {
  const length = Math.hypot(b[0] - a[0], b[1] - a[1]);
  return length ? [(b[0] - a[0]) / length, (b[1] - a[1]) / length] : [-1, 0];
};
function segmentDistance(point: Point, a: Point, b: Point) {
  const dx = b[0] - a[0], dy = b[1] - a[1];
  const projection = clamp(((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / (dx * dx + dy * dy || 1), 0, 1);
  return Math.hypot(point[0] - a[0] - projection * dx, point[1] - a[1] - projection * dy);
}
export function expeditionShapeContains(shape: ExpeditionShape, point: Point): boolean {
  if (shape.kind === 'circle') return Math.hypot(point[0] - shape.x, point[1] - shape.y) <= shape.radius!;
  if (shape.kind === 'line') return segmentDistance(point, [shape.x, shape.y], [shape.x2!, shape.y2!]) <= shape.width! / 2;
  return shape.polygons!.some(polygon => {
    let inside = false;
    for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      const a = polygon[j]!, b = polygon[i]!;
      if (segmentDistance(point, a, b) < 0.000001) return true;
      if ((a[1] > point[1]) !== (b[1] > point[1]) && point[0] < (b[0] - a[0]) * (point[1] - a[1]) / (b[1] - a[1]) + a[0]) inside = !inside;
    }
    return inside;
  });
}
function geometry(kind: string, target: Point, radius: Point, width: number, origin: Point, facing: Point): ExpeditionShape {
  const ellipse = (angle: number, scale = 1): Point => [target[0] + Math.cos(angle) * radius[0] * scale,
    target[1] + Math.sin(angle) * radius[1] * scale];
  let polygons: Point[][];
  if (kind === 'ring') {
    polygons = Array.from({ length: 32 }, (_, i) => [ellipse(i * Math.PI / 16), ellipse((i + 1) * Math.PI / 16),
      ellipse((i + 1) * Math.PI / 16, 0.48), ellipse(i * Math.PI / 16, 0.48)]);
  } else if (kind === 'cone') {
    const heading = Math.atan2(facing[1] / sy, facing[0] / sx);
    polygons = [[target, ...Array.from({ length: 25 }, (_, i) => ellipse(heading - width + i * width / 12))]];
  } else if (kind === 'cross') {
    const [x, y] = target, [rx, ry] = radius;
    polygons = [[[x - rx, y - width], [x + rx, y - width], [x + rx, y + width], [x - rx, y + width]],
      [[x - width, y - ry], [x + width, y - ry], [x + width, y + ry], [x - width, y + ry]]];
  } else if (kind === 'line') {
    const [dx, dy] = direction(origin, target), across: Point = [-dy * width, dx * width];
    polygons = [[add(origin, across), add(target, across), add(target, [-across[0], -across[1]]), add(origin, [-across[0], -across[1]])]];
  } else polygons = [Array.from({ length: 40 }, (_, i) => ellipse(i * Math.PI / 20))];
  return { kind: 'polygon', x: target[0], y: target[1], polygons };
}

// Clients send intent only. AI, frozen warning geometry, status and health live
// here. PvP continues to use the unchanged ArenaMatch implementation.
export class ExpeditionMatch {
  readonly arena: ArenaMatch;
  readonly telegraphs: Telegraph[] = [];
  readonly hazards: Hazard[] = [];
  readonly projectiles: Projectile[] = [];
  private definition: Definition;
  private combatTick = 0;
  private nextAttack = 30;
  private attackCount = 0;
  private stage = 0;
  private enemyPose = 0;
  private move: Move | null = null;
  private movePhase: 'seek' | 'windup' | 'attack' | 'recovery' = 'seek';
  private recoveryAt = 0;
  private phaseEndsAt = 0;
  private comboLeft = 0;
  private lastUsed = new Map<string, number>();
  private signatureStages = new Set<number>();
  private motion: Motion | null = null;
  private shots: { at: number; origin: Point; facing: Point; move: Move; stage: number; wave: number; damage: number }[] = [];
  private slowUntil = 0;
  private statusUntil = new Map<string, number>();
  private hurtUntil = 0;
  result: ExpeditionResult | null = null;

  constructor(readonly stageId: ExpeditionStageId, stats: FighterStats & { wearable_move?: number; wearable_regen?: number }, waitingTicks = 1125) {
    const stage = campaignConfig.stages.find(row => row.stage_id === stageId);
    if (!stage || !definitions.bosses[stageId]) throw new Error('Unknown expedition stage');
    this.definition = definitions.bosses[stageId];
    this.arena = new ArenaMatch(waitingTicks, {
      stats: [stats, { life: stage.battle.life, spirit: 100, stamina: 100, attack: stage.battle.attack, defense: 0 }],
      fightSeconds: 180, reconnectSeconds: 15, pveMovement: stats.wearable_move, pveRegeneration: stats.wearable_regen,
    });
    this.arena.connect(1, true);
  }
  get player() { return this.arena.fighters[0]; }
  get enemy() { return this.arena.fighters[1]; }
  get tick() { return this.arena.tick; }
  get phase() { return this.arena.phase; }
  connect(online: boolean) { this.arena.connect(0, online); }
  input(input: ArenaInput) { this.arena.input(0, input); }
  finish(won: boolean, reason: string) {
    this.result ??= { won, reason };
    this.arena.finish(won ? 0 : 1, reason);
    this.telegraphs.length = this.hazards.length = this.projectiles.length = this.shots.length = 0;
    this.motion = null;
    return this.result;
  }

  step() {
    if (this.result) return;
    const fighting = this.player.online && this.arena.phase === 'fighting';
    if (fighting) this.ai();
    const movement: Point = [this.player.moveX, this.player.moveY];
    if (fighting && this.slowUntil > this.combatTick) { this.player.moveX *= 0.58; this.player.moveY *= 0.58; }
    this.arena.step();
    if (this.player.inputUntil >= this.tick) [this.player.moveX, this.player.moveY] = movement;
    if (this.arena.result) { this.finish(this.enemy.hp === 0 && this.player.hp > 0, this.arena.result.reason); return; }
    if (!fighting) return;
    this.combatTick++;
    this.enemyPose = Math.max(0, this.enemyPose - 1);
    this.advanceEffects();
    if (this.player.hp === 0) this.finish(false, 'knockout');
  }

  state() {
    const state = this.arena.state();
    const visible = this.telegraphs.filter(effect => effect.ticks <= effect.total);
    const next = visible.reduce<Telegraph | undefined>((first, effect) => !first || effect.ticks < first.ticks ? effect : first, undefined);
    return {
      tick: state.tick, phase: state.phase, seconds: state.seconds,
      player: { ...state.players[0]!, statuses: [...this.statusUntil].filter(([, end]) => end > this.combatTick).map(([name]) => name) },
      enemy: { ...state.players[1]!, pose: this.motion ? this.motion.kind === 'leap' ? 'dash' : 'attack' : this.enemyPose || this.movePhase === 'attack' ? 'attack'
        : this.movePhase === 'windup' ? 'guard' : state.players[1]!.pose },
      blades: state.blades,
      telegraphs: visible.map(({ ticks: left, total, damage: _damage, effect: _effect, residue: _residue, charge: _charge, ...shape }) =>
        ({ ...shape, remaining: left * arenaTickMs / 1000, total: total * arenaTickMs / 1000 })),
      hazards: this.hazards.map(({ ticks: left, damage: _damage, effect: _effect, pulse: _pulse, ...shape }) => ({ ...shape, life: left * arenaTickMs / 1000 })),
      enemy_projectiles: this.projectiles.map(({ x, y, radius, style }) => ({ x, y, radius, style })),
      mechanic: { move_id: this.move?.id ?? '', name: this.move?.name ?? '', phase: this.movePhase, stage: this.stage,
        label: next?.label ?? (this.movePhase === 'recovery' ? '收招空隙 · 趁机反击' : this.move?.name ?? '观察守关者的动作') },
      result: this.result,
    };
  }

  private ai() {
    this.stage = Math.max(this.stage, this.enemy.hp <= this.enemy.maxHp / 3 ? 2 : this.enemy.hp <= this.enemy.maxHp * 2 / 3 ? 1 : 0);
    if (this.movePhase === 'windup' && this.combatTick >= this.phaseEndsAt) this.movePhase = 'attack';
    if (this.movePhase === 'attack' && this.combatTick >= this.recoveryAt) {
      this.movePhase = 'recovery';
      this.phaseEndsAt = this.combatTick + ticks(Math.max(1.05, this.move?.recover ?? 1.1));
    }
    if (this.movePhase === 'recovery' && this.combatTick >= this.phaseEndsAt) {
      this.movePhase = 'seek';
      this.nextAttack = this.combatTick + ticks(this.comboLeft > 0 ? 0.35 : Math.max(0.45, this.definition.tempo * this.definition.progression.tempo * 0.55));
    }
    const start: Point = [this.enemy.x, this.enemy.y], target: Point = [this.player.x, this.player.y];
    const facing = direction(start, target), distance = Math.hypot(target[0] - start[0], target[1] - start[1]);
    let moveX = 0, moveY = 0;
    if (this.movePhase === 'seek' && !this.motion) {
      const spacing = this.definition.spacing * sx;
      const forward = distance > spacing + 20 ? 1 : distance < spacing - 35 ? (this.definition.motion === 'kite' ? -0.6 : -0.2) : 0;
      const side = this.definition.motion === 'pursue' ? 0 : (this.attackCount % 2 ? 1 : -1) * 0.35;
      const speed = this.definition.speed * this.definition.progression.speed / 260;
      moveX = (facing[0] * forward - facing[1] * side) * speed;
      moveY = (facing[1] * forward + facing[0] * side) * speed;
      if ((this.enemy.y < arenaBounds.top + 20 && moveY < 0) || (this.enemy.y > arenaBounds.bottom - 20 && moveY > 0)) moveY *= -1;
      if ((this.enemy.x < arenaBounds.left + 20 && moveX < 0) || (this.enemy.x > arenaBounds.right - 20 && moveX > 0)) moveX *= -1;
    }
    if (this.movePhase === 'seek' && this.combatTick >= this.nextAttack) {
      this.begin(start, target, facing, distance);
      moveX = moveY = 0;
    }
    this.arena.input(1, { seq: this.tick + 1, x: moveX, y: moveY, action: 0 });
    this.enemy.fx = facing[0]; this.enemy.fy = facing[1];
  }

  private begin(start: Point, target: Point, facing: Point, distance: number) {
    const candidates = this.definition.moves.filter(move => move.min_stage <= this.stage);
    const score = (move: Move) => (this.attackCount - (this.lastUsed.get(move.id) ?? -2)) * 12
      + (move.kind === 'slash' ? distance < 215 ? 22 : -80 : 0);
    const signature = signatures[this.stageId];
    const identity = candidates.find(move => move.id === (signature?.move ?? (this.stageId === 'b03' ? 'b03_2' : '')));
    // The first attack of each newly reached phase introduces the boss's core
    // mechanic. Aging then rotates through the other authored actions.
    const releasedOpening = this.attackCount === 0 && ['b01', 'b02', 'b03'].includes(this.stageId);
    this.move = identity && !releasedOpening && !this.signatureStages.has(this.stage) ? identity : [...candidates].sort((a, b) => score(b) - score(a))[0]!;
    if (identity?.id === this.move.id && !releasedOpening) this.signatureStages.add(this.stage);
    this.lastUsed.set(this.move.id, this.attackCount);
    if (this.comboLeft === 0) this.comboLeft = this.definition.progression.combo[this.stage] ?? 1;
    this.comboLeft--;
    this.attackCount++;
    const decorated = signature?.move === this.move.id ? signature : undefined;
    if (decorated) this.move = { ...this.move, name: decorated.name };
    const warning = ticks(Math.max(0.8, this.definition.progression.min_tell, (decorated?.tell ?? this.move.tell) * this.definition.progression.tell));
    this.movePhase = 'windup';
    this.phaseEndsAt = this.combatTick + warning;
    this.recoveryAt = this.phaseEndsAt + ticks(Math.max(0.4, this.move.active));
    // Preserve the released three-stage introduction. Subsequent attacks use
    // their full move sets and phase signatures just like the other bosses.
    if (this.attackCount === 1 && ['b01', 'b02', 'b03'].includes(this.stageId)) {
      const opening = { move_id: this.move.id, label: this.stageId === 'b01' ? '落木锁定 · 离开原位置' : this.stageId === 'b02' ? '铜节冲撞 · 让开直线' : '根阵夹击 · 寻找空隙', style: this.move.style };
      if (this.stageId === 'b01') this.warn({ kind: 'circle', x: target[0], y: target[1], radius: 104 }, 32, 22, '', 0, opening);
      else if (this.stageId === 'b02') {
        const end = bound(add(target, [facing[0] * 100, facing[1] * 100]));
        this.warn({ kind: 'line', x: start[0], y: start[1], x2: end[0], y2: end[1], width: 64 }, 27, 31, '', 0, opening, 27, end);
      } else for (const y of [-100, 100]) {
        const p = bound(add(target, [0, y]));
        this.warn({ kind: 'circle', x: p[0], y: p[1], radius: 92 }, 28, 25, '', 0, opening);
      }
      this.phaseEndsAt = this.combatTick + (this.stageId === 'b01' ? 32 : this.stageId === 'b02' ? 27 : 28);
      this.recoveryAt = this.phaseEndsAt + 8;
      return;
    }
    if (decorated) this.signature(decorated, start, target, facing, warning);
    else this.ordinary(this.move, start, target, facing, distance, warning);
  }

  private signature(signature: Signature, start: Point, target: Point, facing: Point, warning: number) {
    const anchors = { boss: start, player: target, arena: center, mirror: add(center, [center[0] - target[0], center[1] - target[1]]) };
    const beats = signature.beats.filter(beat => (beat.stage ?? 0) <= this.stage);
    let previous = 0;
    for (let i = 0; i < beats.length; i++) {
      const beat = beats[i]!, anchor = anchors[beat.anchor];
      const shape = geometry(beat.shape, add(anchor, offset(beat.offset ?? [0, 0])), offset(beat.radius ?? [92, 48]),
        beat.shape === 'cone' ? beat.width ?? 0.7 : (beat.width ?? 30) * sx, add(anchor, offset(beat.from ?? [0, 0])), facing);
      const sameBeat = i > 0 && beat.at === beats[i - 1]!.at;
      // Each follow-up gets its own readable warning, frozen at move start.
      const impact = sameBeat ? previous : i === 0 ? warning + ticks(beat.at) : Math.max(warning + ticks(beat.at), previous + ticks(0.72));
      const duration = i === 0 ? impact : sameBeat ? ticks(0.72) : impact - previous;
      this.warn(shape, impact, Math.round(this.damage(this.move!) * beat.scale), beat.effect ?? '', beat.residue ?? 0,
        { move_id: this.move!.id, label: beat.label, style: beat.style ?? this.move!.style }, duration);
      previous = impact;
      this.recoveryAt = Math.max(this.recoveryAt, this.combatTick + impact + ticks(0.3));
    }
  }

  private ordinary(move: Move, start: Point, target: Point, facing: Point, distance: number, warning: number) {
    const decoration = { move_id: move.id, label: move.name, style: move.style }, damage = this.damage(move);
    const shape = (kind: string, end: Point, radius = offset(move.radius), origin = start) => geometry(kind, end, radius,
      kind === 'cone' ? move.width : move.width * sx, origin, facing);
    if (move.kind === 'volley') {
      const waves = this.definition.progression.waves[this.stage] ?? 1;
      for (let wave = 0; wave < waves; wave++) {
        const delay = warning + wave * ticks(0.72);
        this.shots.push({ at: this.combatTick + delay, origin: start, facing, move, stage: this.stage, wave, damage });
        for (const ray of this.rays(move, facing, this.stage, wave)) {
          const end = add(start, [ray[0] * move.reach * sx, ray[1] * move.reach * sx]);
          this.warn({ kind: 'line', x: start[0], y: start[1], x2: end[0], y2: end[1], width: move.width * 2 },
            delay, 0, '', 0, decoration, wave === 0 ? warning : ticks(0.72));
        }
      }
      this.recoveryAt = this.combatTick + warning + (waves - 1) * ticks(0.72) + ticks(move.reach / (move.speed ?? 400));
    } else if (move.kind === 'charge' || move.kind === 'leap') {
      const end = bound(add(start, [facing[0] * Math.min(move.reach * sx, distance + (move.kind === 'charge' ? 100 : 0)),
        facing[1] * Math.min(move.reach * sx, distance + (move.kind === 'charge' ? 100 : 0))]));
      this.warn(move.kind === 'charge' ? { kind: 'line', x: start[0], y: start[1], x2: end[0], y2: end[1], width: move.width * 2 }
        : shape('circle', end), warning, damage, '', 0, decoration, warning, end);
      this.recoveryAt = this.combatTick + warning + ticks(move.active) + 1;
    } else if (move.kind === 'eruption') {
      const count = Math.min(5, (move.count ?? 3) + (this.stage === 2 ? 1 : 0));
      for (let i = 0; i < count; i++) {
        const p = bound(add(target, offset([(i - (count - 1) / 2) * 140, Math.sin(i * 2.4) * 50])));
        this.warn(shape('circle', p), warning + i * ticks(0.16), damage, '',
          this.stage > 0 && this.definition.progression.hazards ? move.residue ?? 1.5 : 0, decoration, warning);
      }
      this.recoveryAt = Math.max(this.recoveryAt, this.combatTick + warning + (count - 1) * ticks(0.16) + 6);
    } else if (move.kind === 'beam') {
      const end = add(start, [facing[0] * move.reach * sx, facing[1] * move.reach * sx]);
      const beam: ExpeditionShape = { kind: 'line', x: start[0], y: start[1], x2: end[0], y2: end[1], width: move.width * 2 };
      const pulses = move.drain_ratio ? this.stage === 2 ? 3 : 2 : 1;
      for (let i = 0; i < pulses; i++) this.warn(beam, warning + i * ticks(0.72), damage, move.drain_ratio ? 'drain' : '', 0, decoration, i ? ticks(0.72) : warning);
      this.recoveryAt = this.combatTick + warning + (pulses - 1) * ticks(0.72) + 7;
    } else this.warn(shape(move.kind === 'slash' ? 'cone' : move.kind === 'nova' ? 'ring' : 'cross', move.kind === 'cross' ? target : start), warning, damage, '', 0, decoration);
  }

  private damage(move: Move) { return Math.max(1, Math.round(this.enemy.attack * move.power * (1 + this.stage * 0.08))); }
  private rays(move: Move, facing: Point, stage: number, wave: number): Point[] {
    const count = Math.min(7, (move.count ?? 3) + (stage === 2 ? 2 : 0));
    return Array.from({ length: count }, (_, i) => {
      const angle = Math.atan2(facing[1], facing[0]) + (i - (count - 1) / 2) * (move.spread ?? 0.22) + wave % 2 * 0.1;
      return [Math.cos(angle), Math.sin(angle)];
    });
  }
  private warn(shape: ExpeditionShape, delay: number, damage: number, effect: Effect, residue: number, decoration: Decoration, total = delay, charge?: Point) {
    this.telegraphs.push({ ...shape, ...decoration, ticks: delay, total, damage, effect, residue, charge });
  }

  private advanceEffects() {
    for (let i = this.hazards.length - 1; i >= 0; i--) {
      const hazard = this.hazards[i]!;
      if (--hazard.ticks <= 0) { this.hazards.splice(i, 1); continue; }
      if (--hazard.pulse <= 0) {
        hazard.pulse = ticks(0.6);
        if (expeditionShapeContains(hazard, [this.player.x, this.player.y])) this.hit(hazard.damage, hazard.effect, [hazard.x, hazard.y]);
      }
    }
    for (let i = this.telegraphs.length - 1; i >= 0; i--) {
      const effect = this.telegraphs[i]!;
      if (--effect.ticks > 0) continue;
      this.telegraphs.splice(i, 1);
      const { kind, x, y, radius, x2, y2, width, polygons, move_id, label, style } = effect;
      this.hazards.push({ kind, x, y, radius, x2, y2, width, polygons, move_id, label, style,
        ticks: effect.residue ? ticks(effect.residue) : effect.charge ? ticks(this.move?.active ?? 0.5) : 8, damage: effect.residue ? Math.max(1, Math.round(effect.damage * 0.4)) : 0,
        effect: effect.residue ? effect.effect : '', pulse: ticks(0.6) });
      this.enemyPose = 9;
      if (effect.charge) this.motion = { kind: this.move?.kind === 'leap' ? 'leap' : 'charge', start: kind === 'line' ? [x, y] : [this.enemy.x, this.enemy.y], end: effect.charge,
        elapsed: 0, duration: ticks(this.move?.active ?? 0.5), damage: effect.damage, width: width ?? this.move?.width ?? 34, shape: effect, spent: false };
      else if (expeditionShapeContains(effect, [this.player.x, this.player.y])) this.hit(effect.damage, effect.effect, [effect.x, effect.y]);
    }
    if (this.motion) {
      const motion = this.motion;
      const oldProgress = Math.min(1, motion.elapsed / motion.duration);
      const before: Point = [motion.start[0] + (motion.end[0] - motion.start[0]) * oldProgress,
        motion.start[1] + (motion.end[1] - motion.start[1]) * oldProgress];
      const progress = Math.min(1, ++motion.elapsed / motion.duration);
      this.enemy.x = motion.start[0] + (motion.end[0] - motion.start[0]) * progress;
      this.enemy.y = motion.start[1] + (motion.end[1] - motion.start[1]) * progress;
      const hit = motion.kind === 'charge'
        ? segmentDistance([this.player.x, this.player.y], before, [this.enemy.x, this.enemy.y]) <= motion.width / 2
        : progress === 1 && expeditionShapeContains(motion.shape, [this.player.x, this.player.y]);
      if (hit && !motion.spent) { this.hit(motion.damage, '', before); motion.spent = true; }
      if (progress === 1) this.motion = null;
    }
    for (let i = this.shots.length - 1; i >= 0; i--) {
      const shot = this.shots[i]!;
      if (shot.at > this.combatTick) continue;
      this.shots.splice(i, 1);
      for (const ray of this.rays(shot.move, shot.facing, shot.stage, shot.wave)) {
        const speed = (shot.move.speed ?? 400) * arenaTickMs / 1000;
        this.projectiles.push({ x: shot.origin[0], y: shot.origin[1], vx: ray[0] * speed, vy: ray[1] * speed,
          radius: shot.move.width, reach: shot.move.reach * sx, damage: shot.damage, style: shot.move.style });
      }
    }
    for (let i = this.projectiles.length - 1; i >= 0; i--) {
      const projectile = this.projectiles[i]!, before: Point = [projectile.x, projectile.y];
      projectile.x += projectile.vx; projectile.y += projectile.vy;
      projectile.reach -= Math.hypot(projectile.vx, projectile.vy);
      const hit = segmentDistance([this.player.x, this.player.y], before, [projectile.x, projectile.y]) <= projectile.radius;
      if (hit) this.hit(projectile.damage, '', before);
      if (hit || projectile.reach <= 0 || projectile.x < arenaBounds.left - 30 || projectile.x > arenaBounds.right + 30
        || projectile.y < arenaBounds.top - 30 || projectile.y > arenaBounds.bottom + 30) this.projectiles.splice(i, 1);
    }
  }

  private hit(raw: number, effect: Effect, origin: Point) {
    if (this.player.dash > 0 || this.combatTick < this.hurtUntil || (raw === 0 && !effect)) return;
    const damage = raw > 0 ? Math.max(1, raw - Math.floor(this.player.defense * 0.4)) : 0;
    const absorbed = Math.min(damage, this.player.shield);
    this.player.shield -= absorbed;
    const actual = damage - absorbed;
    if (actual > 0) {
      this.player.hp = Math.max(0, this.player.hp - actual);
      this.player.hit = 5; this.player.heal = 0; this.hurtUntil = this.combatTick + 5;
    }
    if (damage > 0 && actual === 0) return;
    if (effect) this.statusUntil.set(effect, this.combatTick + ticks(effect === 'slow' ? 1.2 : 0.85));
    if (effect === 'fatigue') this.player.stamina = Math.max(0, this.player.stamina - 18);
    if (effect === 'seal') this.player.mp = Math.max(0, this.player.mp - 18);
    if (effect === 'slow') this.slowUntil = this.combatTick + ticks(1.2);
    if (effect === 'pull' || effect === 'launch') {
      const ray = direction([this.player.x, this.player.y], origin), magnitude = effect === 'pull' ? 55 : -125;
      const p = bound([this.player.x + ray[0] * magnitude, this.player.y + ray[1] * magnitude]);
      this.player.x = p[0]; this.player.y = p[1];
    }
    if (effect === 'drain' && actual > 0) {
      this.player.mp = Math.max(0, this.player.mp - 15);
      this.enemy.hp = Math.min(this.enemy.maxHp, this.enemy.hp + Math.ceil(actual / 2));
    }
  }
}

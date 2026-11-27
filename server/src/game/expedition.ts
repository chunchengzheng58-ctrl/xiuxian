import { wearableEffects } from '../integration/wearables.js';
import { type Clock, id, requireCondition } from '../core.js';
import { Database } from '../database.js';
import { equipmentBonuses, type GrowingEquipment } from './equipment-growth.js';
import { Ledger } from './ledger.js';
import { type Character, pixelRules, pixelRarities } from './rules.js';
import { ExpeditionMatch, expeditionTickMs, type ExpeditionStageId, type ExpeditionResult } from './expedition-match.js';
import type { ArenaInput, FighterStats } from './arena-match.js';
import { campaignConfig, campaignUnlock, CharacterProgression } from './character-progression.js';

export const expeditionStages = campaignConfig.stages;
type Run = { id: string; cultivator_id: string; stage_id: ExpeditionStageId; avatar: string; stats: string; lifecycle_version: number;
  started_at: number; expires_at: number; finished_at: number | null; result: string | null };
type Drop = { equipment_id: string; template: number; rarity: number; school: number; upgrade_level: number };
export type ExpeditionReward = { spirit_stones: number; materials: number; adventure_xp: number; first_clear: boolean; equipment: Drop | null };
type Recorded = ExpeditionResult & { reward: ExpeditionReward; hp: number; enemy_hp: number; duration_seconds: number };
export type ExpeditionSubscription = { id: string };
type Room = { row: Run; match: ExpeditionMatch };
const emptyReward = (): ExpeditionReward => ({ spirit_stones: 0, materials: 0, adventure_xp: 0, first_clear: false, equipment: null });

export class ExpeditionService {
  private rooms = new Map<string, Room>();
  private lastSweep = -1;

  constructor(private db: Database, private now: Clock, private ledger: Ledger, private randomInt: (max: number) => number,
    private progression = new CharacterProgression(db, now)) {
    // A process restart cannot replay in-memory combat or award an unproven victory.
    for (const row of this.db.all<Run>('SELECT * FROM expedition_runs WHERE finished_at IS NULL')) this.record(row, { won: false, reason: 'interrupted' }, 0);
  }

  lobby(actor: Character) {
    this.requireSelf(actor);
    const adventure = this.progression.view(actor);
    const cleared = new Set(this.db.all<{ stage_id: string }>('SELECT stage_id FROM expedition_clears WHERE cultivator_id = ?', actor.id).map(row => row.stage_id));
    const active = this.db.get<Run>('SELECT * FROM expedition_runs WHERE cultivator_id = ? AND finished_at IS NULL', actor.id);
    return {
      version: campaignConfig.version, adventure, loadout: this.loadout(actor, adventure.base_stats),
      stages: expeditionStages.map(stage => ({
        stage_id: stage.stage_id, boss_id: stage.boss_id, name: stage.name, subtitle: stage.subtitle, recommendation: stage.recommendation,
        chapter_id: stage.chapter_id, region: stage.region, optional: stage.optional, story: stage.story, tactics: stage.tactics,
        world_change: stage.world_change, unlock_reason: campaignUnlock(stage, cleared),
        unlocked: !campaignUnlock(stage, cleared), cleared: cleared.has(stage.stage_id),
        first_reward: { ...stage.first_reward, equipment: { template: stage.template, rarity: stage.rarity, school: stage.school, upgrade_level: 0 } },
        repeat_reward: stage.repeat_reward,
      })),
      active: active ? { run_id: active.id, stage_id: active.stage_id } : null,
      recent: this.db.all<Run>('SELECT * FROM expedition_runs WHERE cultivator_id = ? AND finished_at IS NOT NULL ORDER BY started_at DESC, rowid DESC LIMIT 10', actor.id)
        .map(row => ({ run_id: row.id, stage_id: row.stage_id, finished_at: row.finished_at, ...JSON.parse(row.result!) as Recorded })),
    };
  }

  start(actor: Character, stageId: string) {
    this.requireSelf(actor);
    requireCondition(actor.lifecycle === 'cultivating', 'EXPEDITION_UNAVAILABLE', '当前角色不在修行状态', 409);
    const index = expeditionStages.findIndex(stage => stage.stage_id === stageId);
    requireCondition(index >= 0, 'EXPEDITION_STAGE_UNKNOWN', '秘境不存在', 404);
    const cleared = new Set(this.db.all<{ stage_id: string }>('SELECT stage_id FROM expedition_clears WHERE cultivator_id = ?', actor.id).map(row => row.stage_id));
    const locked = campaignUnlock(expeditionStages[index]!, cleared);
    requireCondition(!locked, 'EXPEDITION_LOCKED', locked, 409);
    requireCondition(!this.db.get('SELECT 1 FROM expedition_runs WHERE cultivator_id = ? AND finished_at IS NULL', actor.id), 'EXPEDITION_ACTIVE', '已有一场秘境挑战，请先返回战场或退出', 409);
    requireCondition(!this.db.get(`SELECT 1 FROM arena_duels WHERE (challenger_id = ? OR opponent_id = ?) AND
      (status = 'active' OR (status = 'pending' AND expires_at > ?))`, actor.id, actor.id, this.now()), 'DUEL_ALREADY_PENDING', '请先结束约战再进入秘境', 409);
    requireCondition(this.db.get<{ count: number }>('SELECT COUNT(*) AS count FROM expedition_runs WHERE finished_at IS NULL')!.count < 128,
      'EXPEDITION_BUSY', '秘境已满，请稍后再试', 409);
    const { base_stats: base, equipment_bonuses: bonus, stats } = this.loadout(actor);
    const runId = id('expedition');
    // A self adventurer can use the game without submitting a health baseline. This
    // fixed game support value is not a health assessment and creates no baseline.
    this.db.run("UPDATE cultivators SET initial_score = 50, initial_profile_id = 'adventurer-default-v1' WHERE id = ? AND initial_score IS NULL", actor.id);
    this.db.run(`INSERT INTO expedition_runs (id, cultivator_id, stage_id, avatar, stats, lifecycle_version, started_at, expires_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, runId, actor.id, stageId, JSON.parse(actor.profile).avatar === 'female' ? 'female' : 'male',
    JSON.stringify(stats), actor.lifecycle_version, this.now(), this.now() + 45);
    this.db.touch(actor.account_id);
    return { run_id: runId, stage_id: stageId, adventure_level: this.progression.view(actor).level, base_stats: base, equipment_bonuses: bonus, stats };
  }

  private loadout(actor: Character, base: FighterStats = this.progression.view(actor).base_stats) {
    const bonus = equipmentBonuses(this.db.all<GrowingEquipment>('SELECT * FROM equipment WHERE cultivator_id = ? AND salvaged_at IS NULL AND equipped = 1', actor.id));
    const stats: FighterStats = { life: base.life + bonus.life, attack: base.attack + bonus.attack, defense: base.defense + bonus.defense,
      spirit: base.spirit + bonus.spirit, stamina: base.stamina + bonus.stamina };
    const wearable = wearableEffects(this.db, actor.id, this.now());
    stats.defense *= 1 + wearable.defense;
    return { base_stats: base, equipment_bonuses: bonus, stats: { ...stats, ...(wearable.movement || wearable.regeneration ? { wearable_move: wearable.movement, wearable_regen: wearable.regeneration } : {}) } };
  }

  leave(actor: Character, runId: string) {
    const row = this.owned(actor.account_id, runId);
    requireCondition(row.cultivator_id === actor.id, 'EXPEDITION_NOT_FOUND', '秘境挑战不存在', 404);
    if (row.result === null) {
      const room = this.rooms.get(runId);
      const result = room?.match.result ?? { won: false, reason: 'withdrawn' };
      this.record(row, result, room?.match.tick ?? 0);
      room?.match.finish(result.won, result.reason);
      if (room) Object.assign(room.row, this.find(runId)!);
    }
    return { run_id: runId, ...JSON.parse(this.find(runId)!.result!) as Recorded };
  }

  subscribe(accountId: string, runId: string): ExpeditionSubscription {
    const row = this.owned(accountId, runId);
    if (row.result === null && !this.rooms.has(runId)) {
      const remaining = row.expires_at - this.now();
      if (remaining > 0) this.rooms.set(runId, { row, match: new ExpeditionMatch(row.stage_id, JSON.parse(row.stats) as FighterStats, Math.ceil(remaining * 1000 / expeditionTickMs)) });
      else this.record(row, { won: false, reason: 'absent' }, 0);
    }
    return { id: runId };
  }
  connect(subscription: ExpeditionSubscription, online: boolean) { this.rooms.get(subscription.id)?.match.connect(online); }
  input(subscription: ExpeditionSubscription, input: ArenaInput) { this.rooms.get(subscription.id)?.match.input(input); }

  step(steps: number) {
    let changed = false;
    for (const { row, match } of this.rooms.values()) {
      if (row.result !== null) continue;
      const actor = this.db.get<Character>('SELECT * FROM cultivators WHERE id = ?', row.cultivator_id)!;
      if (actor.lifecycle !== 'cultivating' || actor.lifecycle_version !== row.lifecycle_version) match.finish(false, 'unavailable');
      for (let i = 0; i < steps; i++) match.step();
      if (match.result) {
        this.record(row, match.result, match.tick);
        row.result = this.find(row.id)!.result;
        row.finished_at = this.now();
        changed = true;
      }
    }
    if (this.lastSweep === this.now()) return changed;
    this.lastSweep = this.now();
    for (const row of this.db.all<Run>('SELECT * FROM expedition_runs WHERE finished_at IS NULL AND expires_at <= ?', this.now())) {
      if (!this.rooms.has(row.id)) { this.record(row, { won: false, reason: 'absent' }, 0); changed = true; }
    }
    for (const [runId, room] of this.rooms) if (room.row.finished_at !== null && room.row.finished_at + 15 <= this.now()) this.rooms.delete(runId);
    return changed;
  }

  state(subscription: ExpeditionSubscription) {
    const room = this.rooms.get(subscription.id);
    const row = room?.row ?? this.find(subscription.id);
    if (!row) return null;
    const match = room?.match ?? new ExpeditionMatch(row.stage_id, JSON.parse(row.stats) as FighterStats);
    if (!room && row.result) {
      const result = JSON.parse(row.result) as Recorded;
      match.player.hp = result.hp;
      match.enemy.hp = result.enemy_hp;
      match.finish(result.won, result.reason);
    }
    const stage = expeditionStages.find(item => item.stage_id === row.stage_id)!;
    return { ...match.state(), run_id: row.id, stage_id: row.stage_id, boss_id: row.stage_id, avatar: row.avatar,
      presentation: { entrance: stage.entrance, barks: stage.barks },
      result: row.result ? JSON.parse(row.result) as Recorded : null };
  }

  private record(row: Run, result: ExpeditionResult, ticks: number) {
    return this.db.transaction(() => {
      const latest = this.find(row.id)!;
      if (latest.result !== null) return JSON.parse(latest.result) as Recorded;
      const actor = this.db.get<Character>('SELECT * FROM cultivators WHERE id = ?', row.cultivator_id)!;
      const won = result.won && actor.lifecycle === 'cultivating' && actor.lifecycle_version === row.lifecycle_version;
      const reward = emptyReward();
      if (won) {
        const stage = expeditionStages.find(stage => stage.stage_id === row.stage_id)!;
        reward.first_clear = !this.db.get('SELECT 1 FROM expedition_clears WHERE cultivator_id = ? AND stage_id = ?', actor.id, row.stage_id);
        Object.assign(reward, reward.first_clear ? stage.first_reward : stage.repeat_reward);
        reward.adventure_xp = this.progression.expedition(actor, row.id, stage, reward.first_clear);
        this.ledger.change(actor.account_id, actor.id, 'spirit_stones', reward.spirit_stones, row.id, 'expedition_clear');
        this.ledger.change(actor.account_id, actor.id, 'materials', reward.materials, row.id, 'expedition_clear');
        const drop = reward.first_clear || this.pick(100) < 20;
        if (drop) {
          const template = reward.first_clear ? stage.template : this.pick(pixelRules.templates.length);
          const rarity = reward.first_clear ? stage.rarity : this.pick(100) < (Number(row.stage_id.slice(1)) >= 3 ? 20 : 5) ? 2 : 1;
          const equipmentId = id('equipment');
          this.db.run(`INSERT INTO equipment (id, cultivator_id, catalogue_id, catalogue_version, slot, rarity, school, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, equipmentId, actor.id, `pixel:${template}`, pixelRules.catalogue_version,
          pixelRules.templates[template]!.slot, pixelRarities[rarity]!, stage.school, this.now());
          reward.equipment = { equipment_id: equipmentId, template, rarity, school: stage.school, upgrade_level: 0 };
        }
        this.db.run(`INSERT INTO expedition_clears VALUES (?, ?, ?, ?, ?) ON CONFLICT(cultivator_id, stage_id)
          DO UPDATE SET best_ticks = MIN(best_ticks, excluded.best_ticks)`, actor.id, row.stage_id, row.id, ticks, this.now());
      }
      const match = this.rooms.get(row.id)?.match;
      const stats = JSON.parse(row.stats) as FighterStats;
      const recorded: Recorded = { won, reason: result.won && !won ? 'unavailable' : result.reason, reward,
        hp: match?.player.hp ?? stats.life, enemy_hp: match?.enemy.hp ?? new ExpeditionMatch(row.stage_id, stats).enemy.hp,
        duration_seconds: ticks * expeditionTickMs / 1000 };
      this.db.run('UPDATE expedition_runs SET finished_at = ?, result = ? WHERE id = ?', this.now(), JSON.stringify(recorded), row.id);
      this.db.touch(actor.account_id);
      return recorded;
    });
  }
  private pick(maximum: number) {
    const value = this.randomInt(maximum);
    requireCondition(Number.isInteger(value) && value >= 0 && value < maximum, 'INVALID_RANDOM', '随机提供方越界', 500);
    return value;
  }
  private requireSelf(actor: Character) { requireCondition(actor.role === 'self', 'EXPEDITION_SELF_REQUIRED', '请切换到本人角色挑战秘境', 403); }
  private find(runId: string) { return this.db.get<Run>('SELECT * FROM expedition_runs WHERE id = ?', runId); }
  private owned(accountId: string, runId: string) {
    const row = this.db.get<Run>('SELECT r.* FROM expedition_runs r JOIN cultivators c ON c.id = r.cultivator_id WHERE r.id = ? AND c.account_id = ?', runId, accountId);
    requireCondition(row, 'EXPEDITION_NOT_FOUND', '秘境挑战不存在', 404);
    return row;
  }
}

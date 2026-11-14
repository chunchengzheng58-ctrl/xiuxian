import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { repositoryRoot } from '../contracts.js';
import { type Clock, requireCondition } from '../core.js';
import { Database } from '../database.js';
import type { FighterStats } from './arena-match.js';
import type { Character } from './rules.js';

export type CampaignReward = { spirit_stones: number; materials: number; adventure_xp: number };
export type CampaignNode = { id: string; title: string; kind: 'intro' | 'closure'; dialogue: { speaker: string; text: string }[] };
export type CampaignChapter = { id: string; title: string; region: string; stage_ids: string[]; optional: boolean; reward: CampaignReward; nodes: CampaignNode[] };
export type CampaignStage = {
  stage_id: string; boss_id: string; name: string; subtitle: string; region: string; chapter_id: string; optional: boolean;
  recommendation: string; story: string; tactics: string; world_change: string;
  requires: { all_clears: string[]; any_clears: string[] };
  school: number; template: number; rarity: number; first_reward: CampaignReward; repeat_reward: CampaignReward;
  battle: { life: number; attack: number };
};
type Campaign = { version: string; title: string; core_stages: string[]; chapters: CampaignChapter[]; stages: CampaignStage[];
  progression: { thresholds: number[]; base: FighterStats; per_level: FighterStats; titles: { level: number; title: string }[] } };
export const campaignConfig = JSON.parse(readFileSync(join(repositoryRoot, 'data/adventure-campaign.v1.json'), 'utf8')) as Campaign;
const thresholds = campaignConfig.progression.thresholds;
requireCondition(thresholds[0] === 0 && thresholds.every((value, index) => Number.isSafeInteger(value) && (index === 0 || value > thresholds[index - 1]!))
  && campaignConfig.stages.length === 20 && new Set(campaignConfig.stages.map(stage => stage.stage_id)).size === 20,
'INVALID_CAMPAIGN', '冒险规则配置无效', 500);

export function campaignUnlock(stage: CampaignStage, cleared: Set<string>) {
  // A previously earned clear always remains available, even if a future chapter adds a prerequisite.
  if (cleared.has(stage.stage_id)) return '';
  const label = (stageId: string) => campaignConfig.stages.find(item => item.stage_id === stageId)?.name ?? stageId;
  const missing = stage.requires.all_clears.filter(stageId => !cleared.has(stageId));
  if (missing.length) return `先完成「${missing.map(label).join('」「')}」的正式秘境挑战`;
  if (stage.requires.any_clears.length && !stage.requires.any_clears.some(stageId => cleared.has(stageId))) return '先使任意一域归衡，取得一枚归衡印';
  return '';
}

export class CharacterProgression {
  constructor(private db: Database, private now: Clock) {}

  view(actor: Character) {
    const xp = this.db.get<{ xp: number }>('SELECT COALESCE(SUM(amount), 0) AS xp FROM adventure_awards WHERE cultivator_id = ?', actor.id)!.xp;
    const cleared = this.db.all<{ stage_id: string }>('SELECT stage_id FROM expedition_clears WHERE cultivator_id = ? ORDER BY stage_id', actor.id).map(row => row.stage_id);
    let level = 1;
    while (level < thresholds.length && xp >= thresholds[level]!) level++;
    const atMax = level === thresholds.length;
    const title = [...campaignConfig.progression.titles].reverse().find(row => row.level <= level)!.title;
    return { version: campaignConfig.version, xp, level, title, max_level: thresholds.length,
      cleared_count: cleared.length, seal_count: campaignConfig.core_stages.filter(stageId => cleared.includes(stageId)).length, cleared_stage_ids: cleared,
      xp_into_level: xp - thresholds[level - 1]!, xp_to_next: atMax ? 0 : thresholds[level]! - xp,
      level_floor_xp: thresholds[level - 1]!, next_level_xp: atMax ? null : thresholds[level]!,
      base_stats: this.baseStats(level), next_level_stats: atMax ? null : this.baseStats(level + 1),
      sources: this.db.all<{ kind: string; xp: number; awards: number }>('SELECT kind, SUM(amount) AS xp, COUNT(*) AS awards FROM adventure_awards WHERE cultivator_id = ? GROUP BY kind ORDER BY kind', actor.id),
    };
  }

  expedition(actor: Character, runId: string, stage: CampaignStage, first: boolean) {
    requireCondition(this.db.get('SELECT 1 FROM expedition_runs WHERE id = ? AND cultivator_id = ? AND stage_id = ?', runId, actor.id, stage.stage_id),
      'INVALID_ADVENTURE_SOURCE', '历练来源不是当前角色的正式秘境', 500);
    return this.award(actor, first ? `expedition:first:${stage.stage_id}` : `expedition:repeat:${runId}`,
      first ? 'expedition_first' : 'expedition_repeat', (first ? stage.first_reward : stage.repeat_reward).adventure_xp);
  }

  chapter(actor: Character, chapter: CampaignChapter) {
    requireCondition(chapter.stage_ids.every(stageId => this.db.get('SELECT 1 FROM expedition_clears WHERE cultivator_id = ? AND stage_id = ?', actor.id, stageId)),
      'STORY_OBJECTIVE_INCOMPLETE', '章节的正式秘境目标尚未完成', 409);
    return this.award(actor, `chapter:${chapter.id}`, 'chapter', chapter.reward.adventure_xp);
  }

  private baseStats(level: number): FighterStats {
    const base = campaignConfig.progression.base;
    const increment = campaignConfig.progression.per_level;
    return Object.fromEntries(Object.entries(base).map(([key, value]) => [key, value + Math.floor(increment[key as keyof FighterStats] * (level - 1))])) as FighterStats;
  }

  private award(actor: Character, source: string, kind: string, amount: number) {
    requireCondition(this.db.connection.isTransaction, 'TRANSACTION_REQUIRED', '历练结算必须位于事务中', 500);
    requireCondition(actor.role === 'self' && Number.isSafeInteger(amount) && amount >= 0, 'INVALID_ADVENTURE_AWARD', '历练奖励无效', 500);
    const existing = this.db.get<{ amount: number }>('SELECT amount FROM adventure_awards WHERE cultivator_id = ? AND source_key = ?', actor.id, source);
    if (existing) return 0;
    this.db.run('INSERT INTO adventure_awards (cultivator_id, source_key, kind, amount, created_at) VALUES (?, ?, ?, ?, ?)', actor.id, source, kind, amount, this.now());
    return amount;
  }
}

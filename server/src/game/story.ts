import { type Clock, requireCondition } from '../core.js';
import { Database } from '../database.js';
import { CharacterProgression, campaignConfig, campaignUnlock, type CampaignChapter } from './character-progression.js';
import { Ledger } from './ledger.js';
import type { Character } from './rules.js';

export class StoryService {
  constructor(private db: Database, private now: Clock, private ledger: Ledger, private progression: CharacterProgression) {}

  snapshot(actor: Character) {
    this.requireSelf(actor);
    const cleared = new Set(this.db.all<{ stage_id: string }>('SELECT stage_id FROM expedition_clears WHERE cultivator_id = ?', actor.id).map(row => row.stage_id));
    const completed = new Map(this.db.all<{ node_id: string; completed_at: number }>('SELECT node_id, completed_at FROM story_nodes WHERE cultivator_id = ?', actor.id).map(row => [row.node_id, row.completed_at]));
    const main = campaignConfig.chapters.filter(chapter => !chapter.optional);
    const chapters = campaignConfig.chapters.map(chapter => {
      const closure = completed.has(`${chapter.id}.closure`);
      const previous = main[main.findIndex(item => item.id === chapter.id) - 1];
      let lock = previous && !completed.has(`${previous.id}.closure`) ? `先领取「${previous.title}」的章节奖励` : '';
      if (!lock) lock = campaignUnlock(campaignConfig.stages.find(stage => stage.stage_id === chapter.stage_ids[0])!, cleared);
      if (closure) lock = '';
      const allCleared = chapter.stage_ids.every(stageId => cleared.has(stageId));
      const introDone = completed.has(`${chapter.id}.intro`);
      const nextStage = chapter.stage_ids.find(stageId => !cleared.has(stageId));
      const target = campaignConfig.stages.find(stage => stage.stage_id === nextStage);
      const objective = target ? `前往${target.subtitle}，使「${target.name}」归衡` : closure ? '章节已完成，可回看灯下旧事' : '目标已完成，听取归衡对白并领取章节奖励';
      const nodes = chapter.nodes.map(node => {
        const done = completed.has(node.id);
        const reason = done ? '' : lock || (node.kind === 'closure' ? !introDone ? '先听取本章线索' : !allCleared ? '先完成本章全部正式秘境挑战' : '' : '');
        return { ...node, available: !reason, completed: done, completed_at: completed.get(node.id) ?? null, lock_reason: reason };
      });
      return { id: chapter.id, title: chapter.title, region: chapter.region, stage_ids: chapter.stage_ids, optional: chapter.optional,
        status: closure ? 'completed' : lock ? 'locked' : allCleared && introDone ? 'claimable' : introDone ? 'active' : 'available',
        objective, target_stage_id: nextStage ?? null, lock_reason: lock, cleared_count: chapter.stage_ids.filter(stageId => cleared.has(stageId)).length,
        reward: chapter.reward, nodes };
    });
    const current = chapters.find(chapter => !chapter.optional && chapter.status !== 'completed');
    const nextNode = current?.nodes.find(node => !node.completed && node.available);
    const finalDone = completed.has('finale.closure');
    const seals = campaignConfig.core_stages.filter(stageId => cleared.has(stageId)).map(stageId => {
      const stage = campaignConfig.stages.find(row => row.stage_id === stageId)!;
      return { stage_id: stageId, region: stage.region, name: `${stage.region}行归衡印` };
    });
    return { version: campaignConfig.version, title: campaignConfig.title, cultivator_id: actor.id,
      current_chapter_id: current?.id ?? null, current_objective: current?.objective ?? '五域归衡已完成，可继续旁篇、重访秘境或磨炼装备',
      next_node_id: nextNode?.id ?? null, chapters, seals, cleared_count: cleared.size,
      adventure: this.progression.view(actor),
      ending: { completed: finalDone, unlocked: cleared.has('b19'), title: '万物各时 · 守灯归来',
        text: finalDone ? campaignConfig.chapters.find(chapter => chapter.id === 'finale')!.nodes[1]!.dialogue[0]!.text : '',
        completed_at: completed.get('finale.closure') ?? null, all_twenty_cleared: cleared.size === 20 },
    };
  }

  advance(actor: Character, nodeId: string) {
    this.requireSelf(actor);
    return this.db.transaction(() => {
      const chapter = campaignConfig.chapters.find(row => row.nodes.some(node => node.id === nodeId));
      requireCondition(chapter, 'STORY_NODE_UNKNOWN', '剧情节点不存在', 404);
      const prior = this.db.get('SELECT 1 FROM story_nodes WHERE cultivator_id = ? AND node_id = ?', actor.id, nodeId);
      if (prior) return this.snapshot(actor);
      requireCondition(actor.lifecycle === 'cultivating', 'STORY_UNAVAILABLE', '当前角色仅可回看剧情', 409);
      const node = this.snapshot(actor).chapters.find(row => row.id === chapter.id)!.nodes.find(row => row.id === nodeId)!;
      requireCondition(node.available, 'STORY_LOCKED', node.lock_reason, 409);
      const operation = `story:${actor.id}:${nodeId}`;
      if (node.kind === 'closure') this.reward(actor, chapter, operation);
      this.db.run('INSERT INTO story_nodes (cultivator_id, node_id, completed_at, reward_operation_id) VALUES (?, ?, ?, ?)', actor.id, nodeId, this.now(), node.kind === 'closure' ? operation : null);
      this.db.touch(actor.account_id);
      return this.snapshot(actor);
    });
  }

  private reward(actor: Character, chapter: CampaignChapter, operation: string) {
    // Both the wallet and adventure XP are committed with the closure marker, or none are.
    this.progression.chapter(actor, chapter);
    this.ledger.change(actor.account_id, actor.id, 'spirit_stones', chapter.reward.spirit_stones, operation, 'story_chapter');
    this.ledger.change(actor.account_id, actor.id, 'materials', chapter.reward.materials, operation, 'story_chapter');
  }

  private requireSelf(actor: Character) { requireCondition(actor.role === 'self', 'STORY_SELF_REQUIRED', '请切换到本人角色继续冒险剧情', 403); }
}

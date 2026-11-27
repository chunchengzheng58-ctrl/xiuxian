import { Database } from '../database.js';
import { type Clock, dayKey, dayStart, requireCondition } from '../core.js';
import { GameService } from '../game/service.js';
import { HealthBridge } from './health.js';

export type WearableInput = {
  cultivator_id: string; date: string; rule: 'wearable-v1'; source: string;
  distance_zhang: number | null; movement_tier: number; sleep_tier: number; expected_revision: number;
};
type Daily = { cultivator_id: string; day: string; source: string; distance_zhang: number | null;
  movement_tier: number; sleep_tier: number; revision: number; withdrawn: number };
export function wearableEffects(db: Database, character: string, now: number) {
  const row = db.get<Daily>('SELECT * FROM wearable_days WHERE cultivator_id = ? AND day = ? AND withdrawn = 0', character, dayKey(now));
  return { movement: (row?.movement_tier ?? 0) / 100, regeneration: [0, .01, .025, .04][row?.sleep_tier ?? 0]!,
    defense: [0, .005, .01, .02][row?.sleep_tier ?? 0]! };
}

export class Wearables {
  constructor(private db: Database, private now: Clock, private game: GameService, private health: HealthBridge) {}
  private own(account: string, character: string) {
    const actor = this.game.own(account, character);
    requireCondition(actor.role === 'self', 'SELF_REQUIRED', '请切换到本人角色', 403);
    return actor;
  }
  status(account: string, character: string) {
    this.own(account, character);
    const row = this.db.get<Daily>('SELECT * FROM wearable_days WHERE cultivator_id = ? AND day = ?', character, dayKey(this.now()));
    const visibility = this.db.get<{ visibility: string }>('SELECT visibility FROM wearable_visibility WHERE cultivator_id = ?', character)?.visibility ?? 'private';
    return { rule: 'wearable-v1', date: dayKey(this.now()), revision: row?.revision ?? 0, visibility,
      confirmed: !!row && !row.withdrawn, distance_zhang: row?.withdrawn ? null : row?.distance_zhang ?? null,
      source: row?.source ?? '', effects: wearableEffects(this.db, character, this.now()), verification: 'self_report' };
  }
  confirm(account: string, input: WearableInput) {
    return this.db.transaction(() => {
      this.own(account, input.cultivator_id);
      requireCondition(input.date === dayKey(this.now()), 'INVALID_DATE', '仅可确认北京时间当天的数据');
      const old = this.db.get<Daily>('SELECT * FROM wearable_days WHERE cultivator_id = ? AND day = ?', input.cultivator_id, input.date);
      const same = old && !old.withdrawn && old.source === input.source && old.distance_zhang === input.distance_zhang;
      if (!same) requireCondition(input.expected_revision === (old?.revision ?? 0), 'WEARABLE_CONFLICT', '记录已在另一窗口更新，请重新打开摘要页面核对', 409);
      // Steps alone cannot claim a larger movement tier; no steps permits the local distance/workout fallback.
      if (input.distance_zhang !== null) {
        const tier = input.distance_zhang >= 8000 ? 3 : input.distance_zhang >= 5000 ? 2 : input.distance_zhang >= 2000 ? 1 : 0;
        requireCondition(input.movement_tier === tier, 'INVALID_TIER', '轻身档位与遁行距离不一致');
      }
      if (!same) {
        this.db.run(`INSERT INTO wearable_days (cultivator_id, day, source, distance_zhang, movement_tier, sleep_tier, revision, withdrawn)
          VALUES (?, ?, ?, ?, ?, ?, 1, 0) ON CONFLICT(cultivator_id, day) DO UPDATE SET
          source = excluded.source, distance_zhang = excluded.distance_zhang, revision = wearable_days.revision + 1, withdrawn = 0`,
        input.cultivator_id, input.date, input.source, input.distance_zhang, input.movement_tier, input.sleep_tier);
      }
      // The original daily reward ledger remains the only reward source. All changes commit atomically.
      const settlement = this.health.confirmPtds(account, input.cultivator_id, input.date);
      this.db.touch(account);
      return { ...this.status(account, input.cultivator_id), settlement };
    });
  }
  visibility(account: string, character: string, scope: string) {
    this.own(account, character);
    this.db.run(`INSERT INTO wearable_visibility VALUES (?, ?) ON CONFLICT(cultivator_id) DO UPDATE SET visibility = excluded.visibility`, character, scope);
    return this.status(account, character);
  }
  withdraw(account: string, character: string) {
    this.own(account, character);
    this.db.run('UPDATE wearable_days SET withdrawn = 1, revision = revision + 1 WHERE cultivator_id = ? AND day = ? AND withdrawn = 0', character, dayKey(this.now()));
    return this.status(account, character);
  }
  board(account: string, character: string, scope: 'global' | 'friends', period: 'day' | 'week', offset: number) {
    this.own(account, character);
    const today = dayKey(this.now());
    const weekDay = new Date(dayStart(today) * 1000 + 8 * 3600000).getUTCDay();
    const from = period === 'day' ? today : dayKey(dayStart(today) - ((weekDay + 6) % 7) * 86400);
    const sql = `WITH scores AS (
      SELECT d.cultivator_id, SUM(d.distance_zhang) AS distance_zhang,
        COALESCE(p.alias, c.name) AS alias, json_extract(c.profile, '$.avatar') AS avatar
      FROM wearable_days d JOIN cultivators c ON c.id = d.cultivator_id
      JOIN wearable_visibility v ON v.cultivator_id = d.cultivator_id
      LEFT JOIN social_profiles p ON p.cultivator_id = d.cultivator_id
      WHERE d.day >= ? AND d.day <= ? AND d.withdrawn = 0 AND d.distance_zhang IS NOT NULL
        AND ${scope === 'global' ? "v.visibility = 'public'" : `v.visibility IN ('public','friends') AND (d.cultivator_id = ? OR EXISTS (
          SELECT 1 FROM social_relations r WHERE r.status = 'accepted'
          AND ((r.left_id = ? AND r.right_id = d.cultivator_id) OR (r.right_id = ? AND r.left_id = d.cultivator_id))))`}
        AND NOT EXISTS (SELECT 1 FROM social_blocks b WHERE
          (b.blocker_id = ? AND b.blocked_id = d.cultivator_id) OR (b.blocked_id = ? AND b.blocker_id = d.cultivator_id))
      GROUP BY d.cultivator_id
    ), ranked AS (SELECT *, RANK() OVER (ORDER BY distance_zhang DESC) AS rank FROM scores)
    SELECT * FROM ranked`;
    const params = [from, today, ...(scope === 'friends' ? [character, character, character] : []), character, character];
    type Row = { cultivator_id: string; distance_zhang: number; alias: string; avatar: string; rank: number };
    const publicRow = (row: Row) => ({ rank: row.rank, alias: row.alias, avatar: row.avatar === 'female' ? 'female' : 'male', distance_zhang: row.distance_zhang, is_self: row.cultivator_id === character });
    const mine = this.db.get<Row>(sql + ' WHERE cultivator_id = ?', ...params, character);
    const rows = this.db.all<Row>(sql + ' ORDER BY distance_zhang DESC, cultivator_id LIMIT 51 OFFSET ?', ...params, offset);
    return { title: '神遁榜', scope, period, from, to: today, unit: '丈', ratio: '1步=1丈', verification: 'self_report',
      entries: rows.slice(0, 50).map(publicRow), has_more: rows.length > 50, offset,
      self: mine ? publicRow(mine) : { rank: null, distance_zhang: this.db.get<{ distance: number | null }>(
        'SELECT SUM(distance_zhang) AS distance FROM wearable_days WHERE cultivator_id = ? AND day >= ? AND day <= ? AND withdrawn = 0', character, from, today)?.distance ?? null } };
  }
}

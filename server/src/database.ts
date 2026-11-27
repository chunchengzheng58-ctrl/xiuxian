import { DatabaseSync, type SQLInputValue } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { digest, requireCondition } from './core.js';

// 编号只能追加；已发布迁移的内容不可修改。健康原图和识别内容不进入本数据库。
const migrations = [String.raw`
CREATE TABLE accounts (
  id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL,
  salt TEXT NOT NULL, created_at INTEGER NOT NULL, merit INTEGER NOT NULL DEFAULT 0 CHECK(merit >= 0),
  revision INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0)
);
CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id),
  created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL
);
CREATE INDEX sessions_account ON sessions(account_id);
CREATE TABLE cultivators (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id), name TEXT NOT NULL,
  element TEXT NOT NULL, created_at INTEGER NOT NULL, lifecycle TEXT NOT NULL DEFAULT 'cultivating',
  realm TEXT NOT NULL DEFAULT 'qi_refining', spirit_stones INTEGER NOT NULL DEFAULT 0 CHECK(spirit_stones >= 0),
  realm_xp INTEGER NOT NULL DEFAULT 0 CHECK(realm_xp >= 0), materials INTEGER NOT NULL DEFAULT 0 CHECK(materials >= 0),
  pity INTEGER NOT NULL DEFAULT 0 CHECK(pity >= 0)
);
CREATE TABLE idempotency (
  principal TEXT NOT NULL, operation TEXT NOT NULL, request_key TEXT NOT NULL,
  fingerprint TEXT NOT NULL, response TEXT NOT NULL, created_at INTEGER NOT NULL,
  PRIMARY KEY(principal, operation, request_key)
);
CREATE TABLE invitations (
  token_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id),
  cultivator_id TEXT NOT NULL REFERENCES cultivators(id), expires_at INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0,
  result_binding_id TEXT, confirmation_fingerprint TEXT
);
CREATE TABLE bindings (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id), cultivator_id TEXT NOT NULL REFERENCES cultivators(id),
  channel TEXT NOT NULL, channel_account_id TEXT NOT NULL, sender_id TEXT NOT NULL, elder_ref TEXT NOT NULL,
  status TEXT NOT NULL, connected INTEGER NOT NULL, consent_status TEXT NOT NULL, consent_version INTEGER NOT NULL,
  consent_scope TEXT NOT NULL, consent_proof_id TEXT NOT NULL, created_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX binding_character_active ON bindings(cultivator_id) WHERE status = 'active';
CREATE UNIQUE INDEX binding_sender_active ON bindings(channel, channel_account_id, sender_id) WHERE status = 'active';
CREATE TABLE tasks (
  id TEXT PRIMARY KEY, cultivator_id TEXT NOT NULL REFERENCES cultivators(id), template_id TEXT NOT NULL,
  template_version TEXT NOT NULL, rule_version TEXT NOT NULL, period TEXT NOT NULL,
  window_start INTEGER NOT NULL, window_end INTEGER NOT NULL, template_snapshot TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'assigned', created_at INTEGER NOT NULL,
  UNIQUE(cultivator_id, template_id, period)
);
CREATE TABLE submission_status (
  service_id TEXT NOT NULL, submission_id TEXT NOT NULL, task_id TEXT NOT NULL REFERENCES tasks(id),
  binding_id TEXT NOT NULL REFERENCES bindings(id), consent_version INTEGER NOT NULL,
  sequence INTEGER NOT NULL, status TEXT NOT NULL, updated_at INTEGER NOT NULL,
  PRIMARY KEY(service_id, submission_id)
);
CREATE TABLE verified_results (
  service_id TEXT NOT NULL, event_id TEXT NOT NULL, task_id TEXT NOT NULL REFERENCES tasks(id),
  binding_id TEXT NOT NULL REFERENCES bindings(id), consent_version INTEGER NOT NULL,
  fingerprint TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
  error_code TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(service_id, event_id)
);
CREATE TABLE settlements (
  id TEXT PRIMARY KEY, task_id TEXT NOT NULL UNIQUE REFERENCES tasks(id), cultivator_id TEXT NOT NULL REFERENCES cultivators(id),
  event_type TEXT NOT NULL, rule_version TEXT NOT NULL, verification_level TEXT NOT NULL,
  spirit_stones INTEGER NOT NULL, realm_xp INTEGER NOT NULL, settled_at INTEGER NOT NULL, day TEXT NOT NULL,
  reason TEXT NOT NULL
);
CREATE INDEX settlement_limits ON settlements(cultivator_id, settled_at, event_type);
CREATE TABLE ledger (
  id TEXT PRIMARY KEY, operation_id TEXT NOT NULL, account_id TEXT NOT NULL REFERENCES accounts(id),
  cultivator_id TEXT REFERENCES cultivators(id), resource TEXT NOT NULL, delta INTEGER NOT NULL,
  balance INTEGER NOT NULL CHECK(balance >= 0), reason TEXT NOT NULL, created_at INTEGER NOT NULL,
  UNIQUE(operation_id, resource)
);
CREATE TABLE equipment (
  id TEXT PRIMARY KEY, cultivator_id TEXT NOT NULL REFERENCES cultivators(id), catalogue_id TEXT NOT NULL,
  slot TEXT NOT NULL, rarity TEXT NOT NULL, equipped INTEGER NOT NULL DEFAULT 0,
  UNIQUE(cultivator_id, catalogue_id)
);
CREATE UNIQUE INDEX equipped_slot ON equipment(cultivator_id, slot) WHERE equipped = 1;
CREATE TABLE outbox (
  id TEXT PRIMARY KEY, binding_id TEXT NOT NULL REFERENCES bindings(id), consent_version INTEGER NOT NULL,
  settlement_id TEXT NOT NULL UNIQUE REFERENCES settlements(id), payload TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
  available_at INTEGER NOT NULL, lease_until INTEGER, lease_hash TEXT, lease_owner TEXT, acknowledged_hash TEXT
);
CREATE TABLE realtime_tickets (
  token_hash TEXT PRIMARY KEY, session_hash TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL
);
`, String.raw`
-- 2：B 的像素玩法。家族角色、五档装备独立实例、日奖励组、可信初始投影和旧档认领。
ALTER TABLE cultivators ADD COLUMN role TEXT NOT NULL DEFAULT 'legacy';
ALTER TABLE cultivators ADD COLUMN profile TEXT NOT NULL DEFAULT '{}';
ALTER TABLE cultivators ADD COLUMN seals INTEGER NOT NULL DEFAULT 0 CHECK(seals >= 0);
ALTER TABLE cultivators ADD COLUMN draw_count INTEGER NOT NULL DEFAULT 0 CHECK(draw_count >= 0);
ALTER TABLE cultivators ADD COLUMN initial_score REAL;
ALTER TABLE cultivators ADD COLUMN initial_profile_id TEXT NOT NULL DEFAULT '';
CREATE UNIQUE INDEX cultivator_self ON cultivators(account_id) WHERE role = 'self';
CREATE TABLE equipment_v2 (
  id TEXT PRIMARY KEY, cultivator_id TEXT NOT NULL REFERENCES cultivators(id), catalogue_id TEXT NOT NULL,
  slot TEXT NOT NULL, rarity TEXT NOT NULL, equipped INTEGER NOT NULL DEFAULT 0,
  catalogue_version TEXT NOT NULL DEFAULT 'integration-v1', draw_id TEXT, created_at INTEGER NOT NULL DEFAULT 0
);
INSERT INTO equipment_v2 (id, cultivator_id, catalogue_id, slot, rarity, equipped) SELECT id, cultivator_id, catalogue_id, slot, rarity, equipped FROM equipment;
DROP TABLE equipment;
ALTER TABLE equipment_v2 RENAME TO equipment;
CREATE UNIQUE INDEX equipped_slot ON equipment(cultivator_id, slot) WHERE equipped = 1;
CREATE UNIQUE INDEX equipment_integration_unique ON equipment(cultivator_id, catalogue_id) WHERE catalogue_version = 'integration-v1';
CREATE INDEX equipment_owner ON equipment(cultivator_id, created_at);
CREATE TABLE reward_groups (
  cultivator_id TEXT NOT NULL REFERENCES cultivators(id), reward_group TEXT NOT NULL, day TEXT NOT NULL,
  settlement_id TEXT NOT NULL UNIQUE REFERENCES settlements(id),
  PRIMARY KEY(cultivator_id, reward_group, day)
);
ALTER TABLE settlements ADD COLUMN seals INTEGER NOT NULL DEFAULT 0;
CREATE TABLE baselines (
  id TEXT PRIMARY KEY, cultivator_id TEXT NOT NULL REFERENCES cultivators(id), service_id TEXT NOT NULL,
  baseline_id TEXT NOT NULL, fingerprint TEXT NOT NULL, projection TEXT NOT NULL, created_at INTEGER NOT NULL,
  UNIQUE(service_id, baseline_id)
);
CREATE INDEX baseline_latest ON baselines(cultivator_id, created_at);
CREATE TABLE baseline_tickets (
  token_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id),
  cultivator_id TEXT NOT NULL REFERENCES cultivators(id), expires_at INTEGER NOT NULL, used_by TEXT
);
CREATE TABLE legacy_claims (
  fingerprint TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id), created_at INTEGER NOT NULL
);
`, String.raw`
-- 3：A 的生命周期与战斗会话。生命周期需家属确认令牌；首通按 (角色, Boss) 唯一，战斗不产生资源。
ALTER TABLE cultivators ADD COLUMN lifecycle_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE cultivators ADD COLUMN stage_template TEXT NOT NULL DEFAULT '';
ALTER TABLE cultivators ADD COLUMN stage_index INTEGER NOT NULL DEFAULT -1;
CREATE TABLE lifecycle_tokens (
  token_hash TEXT PRIMARY KEY, cultivator_id TEXT NOT NULL REFERENCES cultivators(id), target_state TEXT NOT NULL,
  from_version INTEGER NOT NULL, confirmations INTEGER NOT NULL DEFAULT 0, expires_at INTEGER NOT NULL
);
CREATE TABLE lifecycle_events (
  id TEXT PRIMARY KEY, cultivator_id TEXT NOT NULL REFERENCES cultivators(id), kind TEXT NOT NULL,
  value TEXT NOT NULL, version INTEGER NOT NULL, created_at INTEGER NOT NULL
);
CREATE TABLE combat_sessions (
  id TEXT PRIMARY KEY, cultivator_id TEXT NOT NULL REFERENCES cultivators(id), encounter_id TEXT NOT NULL,
  started_at INTEGER NOT NULL, finished_at INTEGER, won INTEGER, duration_seconds REAL
);
CREATE TABLE boss_clears (
  cultivator_id TEXT NOT NULL REFERENCES cultivators(id), boss_id TEXT NOT NULL, first_session_id TEXT NOT NULL,
  best_seconds REAL NOT NULL, cleared_at INTEGER NOT NULL, PRIMARY KEY(cultivator_id, boss_id)
);
`, String.raw`
-- 4：市场挂单与成交历史。在售装备仍属于卖方，但不能穿戴或重复上架。
CREATE TABLE market_listings (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  equipment_id TEXT NOT NULL REFERENCES equipment(id),
  seller_id TEXT NOT NULL REFERENCES cultivators(id),
  buyer_id TEXT REFERENCES cultivators(id),
  template INTEGER NOT NULL CHECK(template >= 0),
  rarity_index INTEGER NOT NULL CHECK(rarity_index BETWEEN 0 AND 4),
  slot TEXT NOT NULL,
  price INTEGER NOT NULL CHECK(price BETWEEN 1 AND 1000000),
  status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'sold', 'cancelled')),
  created_at INTEGER NOT NULL,
  closed_at INTEGER,
  CHECK((status = 'sold') = (buyer_id IS NOT NULL)),
  CHECK((status = 'active') = (closed_at IS NULL)),
  CHECK(seller_id <> buyer_id)
);
CREATE UNIQUE INDEX market_equipment_active ON market_listings(equipment_id) WHERE status = 'active';
CREATE INDEX market_browse ON market_listings(sequence) WHERE status = 'active';
CREATE INDEX market_browse_slot ON market_listings(slot, sequence) WHERE status = 'active';
CREATE INDEX market_seller ON market_listings(seller_id, sequence);
CREATE INDEX market_buyer ON market_listings(buyer_id, sequence) WHERE buyer_id IS NOT NULL;
`, String.raw`
-- 5：独立的社交名片、双向好友与私信。关系删除时一并移除该会话。
CREATE TABLE social_profiles (
  cultivator_id TEXT PRIMARY KEY REFERENCES cultivators(id),
  alias TEXT NOT NULL CHECK(length(alias) BETWEEN 1 AND 12),
  invite_code TEXT NOT NULL UNIQUE CHECK(length(invite_code) = 16)
);
CREATE TABLE social_relations (
  id TEXT PRIMARY KEY,
  left_id TEXT NOT NULL REFERENCES social_profiles(cultivator_id),
  right_id TEXT NOT NULL REFERENCES social_profiles(cultivator_id),
  requester_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('pending', 'accepted')),
  left_read INTEGER NOT NULL DEFAULT 0 CHECK(left_read >= 0),
  right_read INTEGER NOT NULL DEFAULT 0 CHECK(right_read >= 0),
  updated_at INTEGER NOT NULL,
  UNIQUE(left_id, right_id),
  CHECK(left_id < right_id AND requester_id IN (left_id, right_id))
);
CREATE INDEX social_right ON social_relations(right_id, status);
CREATE TABLE social_blocks (
  blocker_id TEXT NOT NULL REFERENCES social_profiles(cultivator_id),
  blocked_id TEXT NOT NULL REFERENCES social_profiles(cultivator_id),
  PRIMARY KEY(blocker_id, blocked_id),
  CHECK(blocker_id <> blocked_id)
);
CREATE TABLE social_messages (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  relation_id TEXT NOT NULL REFERENCES social_relations(id) ON DELETE CASCADE,
  sender_id TEXT NOT NULL REFERENCES social_profiles(cultivator_id),
  body TEXT NOT NULL CHECK(length(body) BETWEEN 1 AND 240),
  sent_at INTEGER NOT NULL
);
CREATE INDEX social_chat ON social_messages(relation_id, sequence);
CREATE INDEX social_message_rate ON social_messages(sender_id, sent_at);
`, String.raw`
-- 6：论剑台邀请与战果；运行中的擂台由当前服务进程模拟。
CREATE TABLE arena_duels (
  id TEXT PRIMARY KEY,
  relation_id TEXT NOT NULL,
  challenger_id TEXT NOT NULL REFERENCES cultivators(id),
  opponent_id TEXT NOT NULL REFERENCES cultivators(id),
  challenger_alias TEXT NOT NULL, opponent_alias TEXT NOT NULL,
  challenger_avatar TEXT NOT NULL, opponent_avatar TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('pending', 'active', 'declined', 'cancelled', 'finished')),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  closed_at INTEGER,
  winner INTEGER CHECK(winner IN (0, 1)),
  reason TEXT,
  challenger_hp INTEGER CHECK(challenger_hp BETWEEN 0 AND 100),
  opponent_hp INTEGER CHECK(opponent_hp BETWEEN 0 AND 100),
  CHECK(challenger_id <> opponent_id)
);
CREATE INDEX arena_challenger ON arena_duels(challenger_id, status, created_at);
CREATE INDEX arena_opponent ON arena_duels(opponent_id, status, created_at);
CREATE INDEX arena_active_expiry ON arena_duels(expires_at) WHERE status = 'active';
`, String.raw`
-- 7：装备成长。保留已分解实例，使交易历史可继续引用原始装备。
ALTER TABLE cultivators ADD COLUMN legendary_pity INTEGER NOT NULL DEFAULT 0 CHECK(legendary_pity BETWEEN 0 AND 49);
ALTER TABLE cultivators ADD COLUMN wish_school INTEGER NOT NULL DEFAULT -1 CHECK(wish_school BETWEEN -1 AND 2);
ALTER TABLE equipment ADD COLUMN school INTEGER NOT NULL DEFAULT -1 CHECK(school BETWEEN -1 AND 2);
ALTER TABLE equipment ADD COLUMN upgrade_level INTEGER NOT NULL DEFAULT 0 CHECK(upgrade_level BETWEEN 0 AND 10);
ALTER TABLE equipment ADD COLUMN salvaged_at INTEGER CHECK(salvaged_at IS NULL OR equipped = 0);
ALTER TABLE market_listings ADD COLUMN school INTEGER NOT NULL DEFAULT -1;
ALTER TABLE market_listings ADD COLUMN upgrade_level INTEGER NOT NULL DEFAULT 0;
`, String.raw`
-- 8: Authoritative expedition results and unlocks are separate from client-reported practice clears.
CREATE TABLE expedition_runs (
  id TEXT PRIMARY KEY,
  cultivator_id TEXT NOT NULL REFERENCES cultivators(id),
  stage_id TEXT NOT NULL CHECK(stage_id IN ('b01', 'b02', 'b03')),
  avatar TEXT NOT NULL,
  stats TEXT NOT NULL,
  lifecycle_version INTEGER NOT NULL,
  started_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  finished_at INTEGER,
  result TEXT
);
CREATE UNIQUE INDEX expedition_active ON expedition_runs(cultivator_id) WHERE finished_at IS NULL;
CREATE INDEX expedition_history ON expedition_runs(cultivator_id, started_at);
CREATE TABLE expedition_clears (
  cultivator_id TEXT NOT NULL REFERENCES cultivators(id),
  stage_id TEXT NOT NULL,
  first_run_id TEXT NOT NULL REFERENCES expedition_runs(id),
  best_ticks INTEGER NOT NULL,
  cleared_at INTEGER NOT NULL,
  PRIMARY KEY(cultivator_id, stage_id)
);
`, String.raw`
-- 9: Public equal-stat matchmaking and authoritative, once-only ranked results.
ALTER TABLE arena_duels ADD COLUMN mode TEXT NOT NULL DEFAULT 'friendly' CHECK(mode IN ('friendly', 'ranked'));
ALTER TABLE arena_duels ADD COLUMN challenger_rating_before INTEGER;
ALTER TABLE arena_duels ADD COLUMN challenger_rating_after INTEGER;
ALTER TABLE arena_duels ADD COLUMN opponent_rating_before INTEGER;
ALTER TABLE arena_duels ADD COLUMN opponent_rating_after INTEGER;
CREATE TABLE arena_ratings (
  cultivator_id TEXT PRIMARY KEY REFERENCES cultivators(id),
  rating INTEGER NOT NULL DEFAULT 1000 CHECK(rating >= 0),
  wins INTEGER NOT NULL DEFAULT 0 CHECK(wins >= 0),
  losses INTEGER NOT NULL DEFAULT 0 CHECK(losses >= 0),
  draws INTEGER NOT NULL DEFAULT 0 CHECK(draws >= 0)
);
CREATE TABLE arena_queue (
  cultivator_id TEXT PRIMARY KEY REFERENCES cultivators(id),
  joined_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX arena_queue_order ON arena_queue(joined_at);
CREATE INDEX arena_ranked_history ON arena_duels(challenger_id, opponent_id, mode, created_at);
`, String.raw`
-- 10: Preserve all expedition history while admitting the twenty canonical bosses.
-- Rebuild both sides of the run FK together; foreign_keys stays ON throughout migration.
CREATE TABLE expedition_runs_v10 (
  id TEXT PRIMARY KEY,
  cultivator_id TEXT NOT NULL REFERENCES cultivators(id),
  stage_id TEXT NOT NULL CHECK(stage_id IN ('b00','b01','b02','b03','b04','b05','b06','b07','b08','b09','b10','b11','b12','b13','b14','b15','b16','b17','b18','b19')),
  avatar TEXT NOT NULL, stats TEXT NOT NULL, lifecycle_version INTEGER NOT NULL,
  started_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, finished_at INTEGER, result TEXT
);
INSERT INTO expedition_runs_v10 SELECT * FROM expedition_runs;
CREATE TABLE expedition_clears_v10 (
  cultivator_id TEXT NOT NULL REFERENCES cultivators(id), stage_id TEXT NOT NULL,
  first_run_id TEXT NOT NULL REFERENCES expedition_runs_v10(id),
  best_ticks INTEGER NOT NULL, cleared_at INTEGER NOT NULL,
  PRIMARY KEY(cultivator_id, stage_id)
);
INSERT INTO expedition_clears_v10 SELECT * FROM expedition_clears;
DROP TABLE expedition_clears;
DROP TABLE expedition_runs;
ALTER TABLE expedition_runs_v10 RENAME TO expedition_runs;
ALTER TABLE expedition_clears_v10 RENAME TO expedition_clears;
CREATE UNIQUE INDEX expedition_active ON expedition_runs(cultivator_id) WHERE finished_at IS NULL;
CREATE INDEX expedition_history ON expedition_runs(cultivator_id, started_at);

-- This append-only XP ledger is independent of health realm_xp and PVP ratings.
CREATE TABLE adventure_awards (
  cultivator_id TEXT NOT NULL REFERENCES cultivators(id),
  source_key TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('expedition_first','expedition_repeat','chapter')),
  amount INTEGER NOT NULL CHECK(amount >= 0 AND amount <= 1000000),
  created_at INTEGER NOT NULL,
  PRIMARY KEY(cultivator_id, source_key)
);
INSERT INTO adventure_awards (cultivator_id, source_key, kind, amount, created_at)
  SELECT e.cultivator_id, 'expedition:first:' || e.stage_id, 'expedition_first',
    CASE e.stage_id WHEN 'b01' THEN 120 WHEN 'b02' THEN 180 WHEN 'b03' THEN 260 END, e.cleared_at
  FROM expedition_clears e JOIN cultivators c ON c.id = e.cultivator_id
  WHERE c.role = 'self' AND e.stage_id IN ('b01','b02','b03');
CREATE TABLE story_nodes (
  cultivator_id TEXT NOT NULL REFERENCES cultivators(id), node_id TEXT NOT NULL,
  completed_at INTEGER NOT NULL, reward_operation_id TEXT UNIQUE,
  PRIMARY KEY(cultivator_id, node_id)
);
`, String.raw`
CREATE TABLE communities (
  id TEXT PRIMARY KEY, owner_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL, visibility TEXT NOT NULL CHECK(visibility IN ('public', 'friends', 'private')),
  max_members INTEGER NOT NULL CHECK(max_members BETWEEN 2 AND 200),
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE INDEX communities_visibility ON communities(visibility, updated_at);
CREATE TABLE community_members (
  community_id TEXT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK(role IN ('owner', 'moderator', 'member')),
  joined_at INTEGER NOT NULL,
  PRIMARY KEY(community_id, account_id)
);
CREATE INDEX community_members_account ON community_members(account_id, joined_at);
CREATE TABLE community_posts (
  id TEXT PRIMARY KEY, community_id TEXT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  body TEXT NOT NULL CHECK(length(body) BETWEEN 1 AND 1000), created_at INTEGER NOT NULL
);
CREATE INDEX community_posts_feed ON community_posts(community_id, created_at DESC, id DESC);
CREATE TABLE community_comments (
  id TEXT PRIMARY KEY, post_id TEXT NOT NULL REFERENCES community_posts(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  body TEXT NOT NULL CHECK(length(body) BETWEEN 1 AND 500), created_at INTEGER NOT NULL
);
CREATE INDEX community_comments_feed ON community_comments(post_id, created_at, id);
CREATE TABLE community_reactions (
  post_id TEXT NOT NULL REFERENCES community_posts(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK(kind IN ('like', 'support', 'cheer')),
  created_at INTEGER NOT NULL,
  PRIMARY KEY(post_id, account_id, kind)
);
CREATE TABLE pvp_matches (
  id TEXT PRIMARY KEY, community_id TEXT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  host_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  guest_account_id TEXT REFERENCES accounts(id) ON DELETE SET NULL,
  room_code TEXT NOT NULL UNIQUE, mode TEXT NOT NULL CHECK(mode = 'friendly_duel_v1'),
  status TEXT NOT NULL CHECK(status IN ('waiting', 'active', 'finished', 'cancelled')),
  winner_account_id TEXT REFERENCES accounts(id) ON DELETE SET NULL,
  reason TEXT NOT NULL DEFAULT '', result_summary TEXT, created_at INTEGER NOT NULL,
  started_at INTEGER, finished_at INTEGER
);
CREATE INDEX pvp_matches_community ON pvp_matches(community_id, created_at DESC);
CREATE TABLE world_messages (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  body TEXT NOT NULL CHECK(length(body) BETWEEN 1 AND 500), created_at INTEGER NOT NULL
);
CREATE INDEX world_messages_feed ON world_messages(created_at DESC, id DESC);
CREATE TABLE world_bosses (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('active', 'defeated', 'expired')),
  hp_total INTEGER NOT NULL CHECK(hp_total > 0), hp_remaining INTEGER NOT NULL CHECK(hp_remaining BETWEEN 0 AND hp_total),
  starts_at INTEGER NOT NULL, ends_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE INDEX world_bosses_status ON world_bosses(status, starts_at DESC);
CREATE TABLE world_boss_contributions (
  boss_id TEXT NOT NULL REFERENCES world_bosses(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  damage INTEGER NOT NULL CHECK(damage >= 0), attempts INTEGER NOT NULL CHECK(attempts >= 0), updated_at INTEGER NOT NULL,
  PRIMARY KEY(boss_id, account_id)
);
CREATE INDEX world_boss_rank ON world_boss_contributions(boss_id, damage DESC, account_id);
`, String.raw`
-- 11: An AI opponent needs no account or cultivator row.
CREATE TABLE arena_duels_v11 (
  id TEXT PRIMARY KEY,
  relation_id TEXT NOT NULL,
  challenger_id TEXT NOT NULL REFERENCES cultivators(id),
  opponent_id TEXT REFERENCES cultivators(id),
  challenger_alias TEXT NOT NULL, opponent_alias TEXT NOT NULL,
  challenger_avatar TEXT NOT NULL, opponent_avatar TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('pending', 'active', 'declined', 'cancelled', 'finished')),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  closed_at INTEGER,
  winner INTEGER CHECK(winner IN (0, 1)),
  reason TEXT,
  challenger_hp INTEGER CHECK(challenger_hp BETWEEN 0 AND 100),
  opponent_hp INTEGER CHECK(opponent_hp BETWEEN 0 AND 100),
  mode TEXT NOT NULL DEFAULT 'friendly' CHECK(mode IN ('friendly', 'ranked')),
  challenger_rating_before INTEGER, challenger_rating_after INTEGER,
  opponent_rating_before INTEGER, opponent_rating_after INTEGER,
  CHECK(
    (opponent_id IS NULL AND mode = 'friendly' AND status IN ('active', 'finished'))
    OR (opponent_id IS NOT NULL AND challenger_id <> opponent_id)
  )
);
INSERT INTO arena_duels_v11 SELECT * FROM arena_duels;
DROP TABLE arena_duels;
ALTER TABLE arena_duels_v11 RENAME TO arena_duels;
CREATE INDEX arena_challenger ON arena_duels(challenger_id, status, created_at);
CREATE INDEX arena_opponent ON arena_duels(opponent_id, status, created_at);
CREATE INDEX arena_active_expiry ON arena_duels(expires_at) WHERE status = 'active';
CREATE INDEX arena_ranked_history ON arena_duels(challenger_id, opponent_id, mode, created_at);
`, String.raw`
-- 12: Account play days are independent of character-specific health rewards.
CREATE TABLE account_play_days (
  account_id TEXT NOT NULL REFERENCES accounts(id),
  day TEXT NOT NULL,
  PRIMARY KEY(account_id, day)
);
INSERT OR IGNORE INTO account_play_days (account_id, day)
  SELECT c.account_id, date(play.started_at, 'unixepoch', '+8 hours')
  FROM (
    SELECT cultivator_id, started_at FROM expedition_runs
    UNION ALL SELECT cultivator_id, started_at FROM combat_sessions
    UNION ALL SELECT challenger_id, created_at FROM arena_duels WHERE status = 'finished'
    UNION ALL SELECT opponent_id, created_at FROM arena_duels WHERE status = 'finished' AND opponent_id IS NOT NULL
  ) play JOIN cultivators c ON c.id = play.cultivator_id;
`, String.raw`
-- 14: Confirmed game projections only; no raw physiological readings.
CREATE TABLE wearable_days (
  cultivator_id TEXT NOT NULL REFERENCES cultivators(id), day TEXT NOT NULL,
  source TEXT NOT NULL, distance_zhang INTEGER CHECK(distance_zhang BETWEEN 0 AND 1000000),
  movement_tier INTEGER NOT NULL CHECK(movement_tier BETWEEN 0 AND 3),
  sleep_tier INTEGER NOT NULL CHECK(sleep_tier BETWEEN 0 AND 3),
  revision INTEGER NOT NULL CHECK(revision > 0), withdrawn INTEGER NOT NULL CHECK(withdrawn IN (0,1)),
  PRIMARY KEY(cultivator_id, day)
);
CREATE INDEX wearable_period ON wearable_days(day, withdrawn);
CREATE TABLE wearable_visibility (
  cultivator_id TEXT PRIMARY KEY REFERENCES cultivators(id),
  visibility TEXT NOT NULL CHECK(visibility IN ('private','friends','public'))
);
`];

export class Database {
  readonly connection: DatabaseSync;
  private depth = 0;

  constructor(path: string) {
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
    this.connection = new DatabaseSync(path);
    this.connection.exec('PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL;');
    try { this.migrate(); } catch (error) { this.connection.close(); throw error; }
  }

  run(sql: string, ...parameters: SQLInputValue[]) { return this.connection.prepare(sql).run(...parameters); }
  get<T>(sql: string, ...parameters: SQLInputValue[]): T | undefined { return this.connection.prepare(sql).get(...parameters) as T | undefined; }
  all<T>(sql: string, ...parameters: SQLInputValue[]): T[] { return this.connection.prepare(sql).all(...parameters) as T[]; }

  // SQLite 的同步事务不跨 await；嵌套服务使用 SAVEPOINT，确保失败不会留下部分扣款。
  transaction<T>(work: () => T): T {
    const level = this.depth++;
    const savepoint = `service_${level}`;
    try {
      this.connection.exec(level === 0 ? 'BEGIN IMMEDIATE' : `SAVEPOINT ${savepoint}`);
      const result = work();
      requireCondition(!(result instanceof Promise), 'ASYNC_TRANSACTION', '事务内禁止异步操作', 500);
      this.connection.exec(level === 0 ? 'COMMIT' : `RELEASE ${savepoint}`);
      return result;
    } catch (error) {
      if (this.connection.isTransaction) this.connection.exec(level === 0 ? 'ROLLBACK' : `ROLLBACK TO ${savepoint}; RELEASE ${savepoint}`);
      throw error;
    } finally { this.depth--; }
  }

  touch(accountId: string) { this.run('UPDATE accounts SET revision = revision + 1 WHERE id = ?', accountId); }
  close() { this.connection.close(); }

  private migrate() {
    const version = this.get<{ user_version: number }>('PRAGMA user_version')!.user_version;
    requireCondition(version <= migrations.length, 'DATABASE_VERSION', '数据库版本高于当前程序，停止启动', 500);
    this.transaction(() => {
      this.connection.exec('CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, checksum TEXT NOT NULL)');
      for (let index = 0; index < migrations.length; index++) {
        const sql = migrations[index]!;
        const recorded = this.get<{ checksum: string }>('SELECT checksum FROM schema_migrations WHERE version = ?', index + 1);
        if (index < version) {
          requireCondition(recorded?.checksum === digest(sql), 'MIGRATION_CHANGED', '已应用迁移被修改或记录缺失', 500);
        } else {
          this.connection.exec(sql);
          this.run('INSERT INTO schema_migrations VALUES (?, ?)', index + 1, digest(sql));
          this.connection.exec(`PRAGMA user_version = ${index + 1}`);
        }
      }
    });
  }
}

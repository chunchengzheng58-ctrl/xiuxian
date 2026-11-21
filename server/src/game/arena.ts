import { type Clock, id, requireCondition } from '../core.js';
import { Database } from '../database.js';
import { ArenaMatch, arenaTickMs, type ArenaInput, type ArenaResult, type Seat } from './arena-match.js';
import type { Character } from './rules.js';
import { SocialService } from './social.js';

const inviteSeconds = 90;
const entrySeconds = 45;
const roomLimit = 128;
const queueSeconds = 15;
const unnamedOpponent = '对手';
const queueLimit = 512;
type Duel = {
  id: string; relation_id: string; challenger_id: string; opponent_id: string | null;
  challenger_alias: string; opponent_alias: string; challenger_avatar: string; opponent_avatar: string;
  status: 'pending' | 'active' | 'declined' | 'cancelled' | 'finished';
  created_at: number; expires_at: number; closed_at: number | null; winner: Seat | null;
  reason: string | null; challenger_hp: number | null; opponent_hp: number | null;
  mode: 'friendly' | 'ranked';
  challenger_rating_before: number | null; challenger_rating_after: number | null;
  opponent_rating_before: number | null; opponent_rating_after: number | null;
};
type Rating = { cultivator_id: string; rating: number; wins: number; losses: number; draws: number };
type Queued = { cultivator_id: string; joined_at: number; expires_at: number; rating: number; alias: string };
type Room = { row: Duel; match: ArenaMatch };
export type ArenaSubscription = { id: string; seat: Seat };
const counterpart = (seat: Seat): Seat => seat === 0 ? 1 : 0;
const avatar = (actor: Pick<Character, 'profile'>) => JSON.parse(actor.profile).avatar === 'female' ? 'female' : 'male';
const practiceStyle = (matchId: string) => Number.parseInt(matchId.slice(-2), 16) & 3;
const opponentAlias = (row: Duel) => row.opponent_id === null ? unnamedOpponent : row.opponent_alias;
const arenaOptions = (row: Duel) => row.opponent_id === null ? { practiceStyle: practiceStyle(row.id) } : {};

export class ArenaService {
  private rooms = new Map<string, Room>();
  private lastSweep = -1;

  constructor(private db: Database, private now: Clock, private social: SocialService) {
    // The game server runs one arena process per SQLite database.
    this.db.transaction(() => {
      this.db.run('DELETE FROM arena_queue');
      for (const row of this.db.all<Duel>("SELECT * FROM arena_duels WHERE status = 'active'")) {
        this.recordResult(row, { winner: null, reason: 'interrupted', hp: [100, 100] });
      }
    });
  }

  lobby(actor: Character) {
    this.requireSelf(actor);
    const rows = this.db.all<Duel>(`SELECT * FROM arena_duels
      WHERE (challenger_id = ? OR opponent_id = ?) AND (
        status IN ('active', 'finished') OR (status = 'pending' AND expires_at > ?)
      ) ORDER BY created_at DESC, id DESC LIMIT 20`, actor.id, actor.id, this.now());
    return {
      friends: this.social.home(actor).friends.map(({ relation_id, alias }) => ({ relation_id, alias })),
      matches: rows.map(row => this.lobbyView(row, row.challenger_id === actor.id ? 0 : 1)),
    };
  }

  summary(cultivatorId: string | undefined) {
    if (!cultivatorId) return { invitations: 0, active: false, queued: false, active_mode: null };
    const invitations = this.db.get<{ count: number }>(
      "SELECT COUNT(*) AS count FROM arena_duels WHERE opponent_id = ? AND status = 'pending' AND expires_at > ?",
      cultivatorId, this.now())!.count;
    const active = this.db.get<Duel>("SELECT * FROM arena_duels WHERE status = 'active' AND (challenger_id = ? OR opponent_id = ?) LIMIT 1",
      cultivatorId, cultivatorId);
    const queued = this.db.get('SELECT 1 FROM arena_queue WHERE cultivator_id = ? AND expires_at > ?', cultivatorId, this.now()) !== undefined;
    return { invitations, active: !!active, queued, active_mode: active ? (active.opponent_id === null ? 'ranked' : active.mode) : null };
  }

  matchmakingLobby(actor: Character) {
    this.requireSelf(actor);
    this.db.transaction(() => this.sweepQueue());
    const profile = this.db.get<{ alias: string }>('SELECT alias FROM social_profiles WHERE cultivator_id = ?', actor.id) ?? null;
    const rating = this.rating(actor.id);
    const played = rating.wins + rating.losses + rating.draws;
    const rank = played ? this.db.get<{ count: number }>(`SELECT COUNT(*) AS count FROM arena_ratings
      WHERE wins + losses + draws > 0 AND (rating > ? OR (rating = ? AND cultivator_id < ?))`, rating.rating, rating.rating, actor.id)!.count + 1 : null;
    const queue = this.db.get<{ joined_at: number; expires_at: number }>('SELECT joined_at, expires_at FROM arena_queue WHERE cultivator_id = ?', actor.id) ?? null;
    const active = this.db.get<Duel>(`SELECT * FROM arena_duels WHERE (mode = 'ranked' OR opponent_id IS NULL) AND status = 'active'
      AND (challenger_id = ? OR opponent_id = ?) LIMIT 1`, actor.id, actor.id);
    const leaderboard = this.db.all<Rating & { alias: string }>(`SELECT r.*, p.alias FROM arena_ratings r
      JOIN social_profiles p ON p.cultivator_id = r.cultivator_id WHERE wins + losses + draws > 0
      ORDER BY rating DESC, r.cultivator_id LIMIT 30`).map(({ alias, rating, wins, losses, draws }, index) =>
      ({ rank: index + 1, alias, rating, wins, losses, draws }));
    const recent = this.db.all<Duel>(`SELECT * FROM arena_duels WHERE mode = 'ranked' AND status = 'finished'
      AND (challenger_id = ? OR opponent_id = ?) ORDER BY created_at DESC, rowid DESC LIMIT 10`, actor.id, actor.id)
      .map(row => this.lobbyView(row, row.challenger_id === actor.id ? 0 : 1));
    return { profile, rating: { rating: rating.rating, wins: rating.wins, losses: rating.losses, draws: rating.draws, rank },
      queue, active: active ? { match_id: active.id, opponent: active.challenger_id === actor.id ? opponentAlias(active) : active.challenger_alias, mode: 'ranked' } : null,
      leaderboard, recent, server_now: this.now() };
  }

  matchmakingJoin(actor: Character) {
    this.requirePlayable(actor);
    this.sweepQueue();
    requireCondition(this.db.get('SELECT 1 FROM social_profiles WHERE cultivator_id = ?', actor.id), 'SOCIAL_PROFILE_REQUIRED', '请先设置公开论剑昵称，再开始匹配', 409);
    if (this.db.get('SELECT 1 FROM arena_queue WHERE cultivator_id = ?', actor.id)) return this.matchmakingLobby(actor);
    this.requireFree(actor.id, actor.id);
    requireCondition(this.db.get<{ count: number }>('SELECT COUNT(*) AS count FROM arena_queue')!.count < queueLimit,
      'MATCHMAKING_BUSY', '匹配队列已满，请稍后重试', 409);
    this.db.run('INSERT OR IGNORE INTO arena_ratings (cultivator_id) VALUES (?)', actor.id);
    this.db.run('INSERT INTO arena_queue VALUES (?, ?, ?)', actor.id, this.now(), this.now() + queueSeconds);
    this.db.touch(actor.account_id);
    this.pairQueue();
    return this.matchmakingLobby(actor);
  }

  matchmakingCancel(actor: Character) {
    this.requireSelf(actor);
    if (this.db.run('DELETE FROM arena_queue WHERE cultivator_id = ?', actor.id).changes) this.db.touch(actor.account_id);
    // A match already created by the server is never cancelled by a late queue request.
    return this.matchmakingLobby(actor);
  }

  assertNotQueued(...cultivatorIds: string[]) {
    this.sweepQueue();
    for (const actorId of cultivatorIds) requireCondition(!this.db.get('SELECT 1 FROM arena_queue WHERE cultivator_id = ?', actorId),
      'MATCHMAKING_QUEUED', '请先取消公开匹配，再进行其他战斗', 409);
  }

  invite(actor: Character, relationId: string) {
    this.requirePlayable(actor);
    const contact = this.social.duelContact(actor, relationId);
    const opponent = this.db.get<Character>('SELECT * FROM cultivators WHERE id = ?', contact.peerId)!;
    this.requirePlayable(opponent);
    this.requireFree(actor.id, opponent.id);
    const matchId = id('duel');
    const now = this.now();
    this.db.run(`INSERT INTO arena_duels (
      id, relation_id, challenger_id, opponent_id, challenger_alias, opponent_alias, challenger_avatar, opponent_avatar,
      status, created_at, expires_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)`, matchId, relationId, actor.id, opponent.id,
    contact.ownAlias, contact.peerAlias, avatar(actor), avatar(opponent), now, now + inviteSeconds);
    this.touch(actor.id, opponent.id);
    return { match_id: matchId };
  }

  reply(actor: Character, matchId: string, action: string) {
    const row = this.owned(actor, matchId);
    requireCondition(row.opponent_id !== null && row.status === 'pending' && row.expires_at > this.now(), 'DUEL_INVITE_CLOSED', '约战邀请已结束', 409);
    const received = actor.id === row.opponent_id;
    requireCondition((received && ['accept', 'decline'].includes(action)) || (!received && action === 'cancel'),
      'DUEL_ACTION_UNAVAILABLE', '当前角色无法执行此操作', 409);
    if (action === 'accept') {
      this.requirePlayable(actor);
      this.social.duelContact(actor, row.relation_id);
      this.requirePlayable(this.db.get<Character>('SELECT * FROM cultivators WHERE id = ?', row.challenger_id)!);
      this.requireFree(row.challenger_id, row.opponent_id, matchId);
      const count = this.db.get<{ count: number }>("SELECT COUNT(*) AS count FROM arena_duels WHERE status = 'active'")!.count;
      requireCondition(count < roomLimit, 'DUEL_BUSY', '擂台已满，请稍后再试', 409);
      this.db.run("UPDATE arena_duels SET status = 'active', expires_at = ? WHERE id = ?", this.now() + entrySeconds, matchId);
    } else {
      this.db.run('UPDATE arena_duels SET status = ?, closed_at = ? WHERE id = ?', received ? 'declined' : 'cancelled', this.now(), matchId);
    }
    this.touch(row.challenger_id, row.opponent_id);
    return { match_id: matchId };
  }

  leave(actor: Character, matchId: string) {
    const row = this.owned(actor, matchId);
    const seat = row.challenger_id === actor.id ? 0 : 1;
    if (row.status === 'finished') return this.lobbyView(row, seat);
    requireCondition(row.status === 'active', 'DUEL_CLOSED', '当前对战已经关闭', 409);
    const room = this.rooms.get(matchId);
    const forfeit = room?.match.phase === 'fighting' || room?.match.phase === 'reconnecting';
    const hp: [number, number] = room ? [room.match.fighters[0].hp, room.match.fighters[1].hp] : [100, 100];
    const result = room?.match.result ?? { winner: forfeit ? counterpart(seat) : null, reason: forfeit ? 'forfeit' : 'withdrawn', hp };
    const closed = this.db.transaction(() => this.recordResult(row, result));
    if (room) {
      room.row.closed_at = closed;
      room.match.finish(result.winner, result.reason);
    }
    return this.lobbyView(this.find(matchId)!, seat);
  }

  subscribe(accountId: string, matchId: string): ArenaSubscription {
    const row = this.db.get<Duel>(`SELECT d.* FROM arena_duels d
      JOIN cultivators c ON (c.id = d.challenger_id OR c.id = d.opponent_id)
      WHERE d.id = ? AND c.account_id = ?`, matchId, accountId);
    requireCondition(row, 'DUEL_NOT_FOUND', '对战不存在', 404);
    requireCondition(row.status === 'active' || row.status === 'finished', 'DUEL_NOT_ACTIVE', '请先完成约战确认', 409);
    const own = this.db.get<{ id: string }>("SELECT id FROM cultivators WHERE account_id = ? AND role = 'self'", accountId);
    const seat = own?.id === row.challenger_id ? 0 : 1;
    if (row.status === 'active' && !this.rooms.has(matchId)) {
      const remaining = row.expires_at - this.now();
      if (remaining > 0) this.rooms.set(matchId, { row, match: new ArenaMatch(Math.ceil(remaining * 1000 / arenaTickMs), arenaOptions(row)) });
      else this.db.transaction(() => this.recordResult(row, { winner: null, reason: 'absent', hp: [100, 100] }));
    }
    return { id: matchId, seat };
  }

  connect(subscription: ArenaSubscription, online: boolean) {
    this.rooms.get(subscription.id)?.match.connect(subscription.seat, online);
  }

  input(subscription: ArenaSubscription, input: ArenaInput) {
    this.rooms.get(subscription.id)?.match.input(subscription.seat, input);
  }

  step(steps: number) {
    let changed = false;
    for (const { row, match } of this.rooms.values()) {
      if (!match.result) {
        const unavailable = this.db.get(`SELECT 1 FROM cultivators WHERE id IN (?, ?) AND (role <> 'self' OR lifecycle <> 'cultivating') LIMIT 1`, row.challenger_id, row.opponent_id);
        if (unavailable) match.finish(null, 'unavailable');
      }
      for (let i = 0; i < steps; i++) match.step();
      if (row.closed_at === null && match.result) {
        row.closed_at = this.db.transaction(() => this.recordResult(row, match.result!));
        changed = true;
      }
    }
    const now = this.now();
    if (now === this.lastSweep) return changed;
    this.lastSweep = now;
    changed = this.db.transaction(() => {
      const swept = this.sweepQueue();
      const paired = this.pairQueue();
      const filled = this.fillExpiredWithBots(now);
      return swept || paired || filled;
    }) || changed;
    for (const row of this.db.all<Duel>("SELECT * FROM arena_duels WHERE status = 'active' AND expires_at <= ?", now)) {
      if (!this.rooms.has(row.id)) {
        this.db.transaction(() => this.recordResult(row, { winner: null, reason: 'absent', hp: [100, 100] }));
        changed = true;
      }
    }
    for (const [matchId, room] of this.rooms) {
      if (room.match.result && room.row.closed_at !== null && room.row.closed_at + 15 <= now) this.rooms.delete(matchId);
    }
    return changed;
  }

  state(subscription: ArenaSubscription) {
    const room = this.rooms.get(subscription.id);
    const row = room?.match.result ? this.find(subscription.id) : room?.row ?? this.find(subscription.id);
    if (!row || !room && row.status !== 'finished') return null;
    let match = room?.match;
    if (!match) {
      match = new ArenaMatch(0, arenaOptions(row));
      match.fighters[0].hp = row.challenger_hp!;
      match.fighters[1].hp = row.opponent_hp!;
      match.finish(row.winner, row.reason!);
    }
    return {
      match_id: row.id, seat: subscription.seat, ...match.state(),
      names: [row.challenger_alias, opponentAlias(row)], avatars: [row.challenger_avatar, row.opponent_avatar],
      mode: row.opponent_id === null ? 'ranked' : row.mode,
      rating_change: this.ratingChange(row, subscription.seat),
    };
  }

  private recordResult(row: Duel, result: ArenaResult) {
    const now = this.now();
    const applied = this.db.run(`UPDATE arena_duels SET status = 'finished', closed_at = ?, winner = ?, reason = ?,
      challenger_hp = ?, opponent_hp = ? WHERE id = ? AND status = 'active'`,
    now, result.winner, result.reason, ...result.hp, row.id);
    if (applied.changes) {
      const unavailable = this.db.get(`SELECT 1 FROM cultivators WHERE id IN (?, ?) AND (role <> 'self' OR lifecycle <> 'cultivating') LIMIT 1`, row.challenger_id, row.opponent_id);
      if (row.mode === 'ranked' && !unavailable && ['knockout', 'time', 'forfeit', 'disconnect'].includes(result.reason)) this.rateResult(row, result);
      this.touch(row.challenger_id, row.opponent_id);
    }
    return now;
  }

  private lobbyView(row: Duel, seat: Seat) {
    const change = this.ratingChange(row, seat);
    return {
      match_id: row.id, seat, opponent: seat === 0 ? opponentAlias(row) : row.challenger_alias,
      status: row.status, winner: row.winner, reason: row.reason, expires_at: row.expires_at, closed_at: row.closed_at,
      mode: row.mode, rating_before: change?.before ?? null, rating_after: change?.after ?? null, rating_delta: change?.delta ?? null,
    };
  }

  private ratingChange(row: Duel, seat: Seat) {
    const before = seat === 0 ? row.challenger_rating_before : row.opponent_rating_before;
    const after = seat === 0 ? row.challenger_rating_after : row.opponent_rating_after;
    return before === null || after === null ? null : { before, after, delta: after - before };
  }

  private rating(actorId: string): Rating {
    return this.db.get<Rating>('SELECT * FROM arena_ratings WHERE cultivator_id = ?', actorId)
      ?? { cultivator_id: actorId, rating: 1000, wins: 0, losses: 0, draws: 0 };
  }

  private rateResult(row: Duel, result: ArenaResult) {
    if (row.opponent_id === null) return;
    const left = this.rating(row.challenger_id), right = this.rating(row.opponent_id);
    const expected = 1 / (1 + 10 ** ((right.rating - left.rating) / 400));
    const score = result.winner === null ? 0.5 : result.winner === 0 ? 1 : 0;
    const change = Math.max(-left.rating, Math.min(right.rating, Math.round(24 * (score - expected))));
    for (const [seat, player, delta] of [[0, left, change], [1, right, -change]] as const) {
      this.db.run(`INSERT INTO arena_ratings (cultivator_id, rating, wins, losses, draws) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(cultivator_id) DO UPDATE SET rating = excluded.rating, wins = excluded.wins, losses = excluded.losses, draws = excluded.draws`,
      player.cultivator_id, player.rating + delta, player.wins + Number(result.winner === seat),
      player.losses + Number(result.winner !== null && result.winner !== seat), player.draws + Number(result.winner === null));
    }
    this.db.run(`UPDATE arena_duels SET challenger_rating_before = ?, challenger_rating_after = ?,
      opponent_rating_before = ?, opponent_rating_after = ? WHERE id = ?`, left.rating, left.rating + change, right.rating, right.rating - change, row.id);
  }

  private sweepQueue() {
    const invalid = this.db.all<{ cultivator_id: string }>(`SELECT q.cultivator_id FROM arena_queue q
      JOIN cultivators c ON c.id = q.cultivator_id WHERE c.role <> 'self' OR c.lifecycle <> 'cultivating'
      OR NOT EXISTS(SELECT 1 FROM sessions s WHERE s.account_id = c.account_id AND s.expires_at > ?)
      OR NOT EXISTS(SELECT 1 FROM social_profiles p WHERE p.cultivator_id = c.id)
      OR EXISTS(SELECT 1 FROM expedition_runs e WHERE e.cultivator_id = c.id AND e.finished_at IS NULL)
      OR EXISTS(SELECT 1 FROM arena_duels d WHERE (d.challenger_id = c.id OR d.opponent_id = c.id)
        AND (d.status = 'active' OR (d.status = 'pending' AND d.expires_at > ?)))`, this.now(), this.now());
    for (const row of invalid) {
      this.db.run('DELETE FROM arena_queue WHERE cultivator_id = ?', row.cultivator_id);
      this.db.run('UPDATE accounts SET revision = revision + 1 WHERE id = (SELECT account_id FROM cultivators WHERE id = ?)', row.cultivator_id);
    }
    return invalid.length > 0;
  }

  private pairQueue() {
    const queued = this.db.all<Queued>(`SELECT q.*, r.rating, p.alias FROM arena_queue q
      JOIN arena_ratings r ON r.cultivator_id = q.cultivator_id JOIN social_profiles p ON p.cultivator_id = q.cultivator_id
      ORDER BY q.joined_at, q.rowid`);
    const blocked = new Set(this.db.all<{ blocker_id: string; blocked_id: string }>(`SELECT b.* FROM social_blocks b
      JOIN arena_queue q ON q.cultivator_id = b.blocker_id`).map(row => [row.blocker_id, row.blocked_id].sort().join(':')));
    let capacity = roomLimit - this.db.get<{ count: number }>("SELECT COUNT(*) AS count FROM arena_duels WHERE status = 'active'")!.count;
    const paired = new Set<string>();
    for (const left of queued) {
      if (capacity <= 0) break;
      if (paired.has(left.cultivator_id)) continue;
      const candidates = queued.filter(right => right.cultivator_id !== left.cultivator_id && !paired.has(right.cultivator_id)
        && !blocked.has([left.cultivator_id, right.cultivator_id].sort().join(':'))
        && (this.now() - Math.min(left.joined_at, right.joined_at) >= queueSeconds
          || Math.abs(left.rating - right.rating) <= 200 + (this.now() - Math.min(left.joined_at, right.joined_at)) * 40));
      candidates.sort((a, b) => Math.abs(left.rating - a.rating) - Math.abs(left.rating - b.rating) || a.joined_at - b.joined_at);
      const right = candidates[0];
      if (!right) continue;
      const actors = [left, right].map(player => this.db.get<Character>('SELECT * FROM cultivators WHERE id = ?', player.cultivator_id)!) as [Character, Character];
      this.db.run('DELETE FROM arena_queue WHERE cultivator_id IN (?, ?)', left.cultivator_id, right.cultivator_id);
      this.requireFree(left.cultivator_id, right.cultivator_id);
      const matchId = id('duel');
      this.db.run(`INSERT INTO arena_duels (id, relation_id, challenger_id, opponent_id, challenger_alias, opponent_alias,
        challenger_avatar, opponent_avatar, status, created_at, expires_at, mode) VALUES (?, '', ?, ?, ?, ?, ?, ?, 'active', ?, ?, 'ranked')`,
      matchId, left.cultivator_id, right.cultivator_id, left.alias, right.alias, avatar(actors[0]), avatar(actors[1]), this.now(), this.now() + entrySeconds);
      paired.add(left.cultivator_id);
      paired.add(right.cultivator_id);
      this.touch(left.cultivator_id, right.cultivator_id);
      capacity--;
    }
    return paired.size > 0;
  }

  private fillExpiredWithBots(now: number) {
    let capacity = roomLimit - this.db.get<{ count: number }>("SELECT COUNT(*) AS count FROM arena_duels WHERE status = 'active'")!.count;
    const expired = this.db.all<{ cultivator_id: string; alias: string; profile: string }>(`SELECT q.cultivator_id, p.alias, c.profile
      FROM arena_queue q JOIN social_profiles p ON p.cultivator_id = q.cultivator_id
      JOIN cultivators c ON c.id = q.cultivator_id WHERE q.expires_at <= ? ORDER BY q.joined_at, q.rowid`, now);
    for (const player of expired) {
      this.db.run('DELETE FROM arena_queue WHERE cultivator_id = ?', player.cultivator_id);
      if (capacity > 0) {
        // A practice opponent has no account. Store it separately from rated duels,
        // while the client can still use the matchmaking lobby and arena screens.
        const matchId = id('duel');
        const opponentAvatar = practiceStyle(matchId) % 2 === 0 ? 'male' : 'female';
        this.db.run(`INSERT INTO arena_duels (id, relation_id, challenger_id, opponent_id,
          challenger_alias, opponent_alias, challenger_avatar, opponent_avatar, status, created_at, expires_at, mode)
          VALUES (?, '', ?, NULL, ?, ?, ?, ?, 'active', ?, ?, 'friendly')`,
        matchId, player.cultivator_id, player.alias, unnamedOpponent, avatar(player), opponentAvatar, now, now + entrySeconds);
        capacity--;
      }
      this.touch(player.cultivator_id, null);
    }
    return expired.length > 0;
  }

  private find(id: string) { return this.db.get<Duel>('SELECT * FROM arena_duels WHERE id = ?', id); }

  private owned(actor: Character, id: string) {
    this.requireSelf(actor);
    const row = this.find(id);
    requireCondition(row && (row.challenger_id === actor.id || row.opponent_id === actor.id), 'DUEL_NOT_FOUND', '对战不存在', 404);
    return row;
  }

  private requireSelf(actor: Character) {
    requireCondition(actor.role === 'self', 'DUEL_SELF_REQUIRED', '请切换到本人角色使用论剑台', 403);
  }

  private requirePlayable(actor: Character) {
    this.requireSelf(actor);
    requireCondition(actor.lifecycle === 'cultivating', 'DUEL_UNAVAILABLE', '双方都处于修行状态时才能约战', 409);
  }

  private requireFree(left: string, right: string, ignore = '') {
    this.assertNotQueued(left, right);
    requireCondition(!this.db.get('SELECT 1 FROM expedition_runs WHERE cultivator_id IN (?, ?) AND finished_at IS NULL LIMIT 1', left, right),
      'EXPEDITION_ACTIVE', '一方正在挑战秘境，请待挑战结束后约战', 409);
    requireCondition(!this.db.get(`SELECT 1 FROM arena_duels WHERE id <> ? AND
      (challenger_id IN (?, ?) OR opponent_id IN (?, ?)) AND
      (status = 'active' OR (status = 'pending' AND expires_at > ?)) LIMIT 1`, ignore, left, right, left, right, this.now()),
    'DUEL_ALREADY_PENDING', '一方已有约战或正在擂台上', 409);
  }

  private touch(left: string, right: string | null) {
    this.db.run('UPDATE accounts SET revision = revision + 1 WHERE id IN (SELECT account_id FROM cultivators WHERE id IN (?, ?))', left, right);
  }
}

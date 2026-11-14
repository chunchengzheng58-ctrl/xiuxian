import { randomBytes } from 'node:crypto';
import { type Clock, id, requireCondition } from '../core.js';
import { Database } from '../database.js';
import type { Character } from './rules.js';

const friendLimit = 100;
const pendingLimit = 24;
const messagePage = 25;
const messageLimit = 100;
const controlCharacters = /[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]/u;

type Profile = { alias: string; invite_code: string };
type Relation = {
  id: string; left_id: string; right_id: string; requester_id: string;
  status: 'pending' | 'accepted'; left_read: number; right_read: number; updated_at: number;
};
type Message = { sequence: number; sender_id: string; body: string; sent_at: number };
type Contact = Relation & { alias: string; unread: number };

export class SocialService {
  constructor(private db: Database, private now: Clock) {}

  home(actor: Character) {
    this.requireSelf(actor);
    const profile = this.profile(actor.id) ?? null;
    const relations = this.contacts(actor.id);
    const friends = relations.filter(row => row.status === 'accepted').map(row => ({
      relation_id: row.id, alias: row.alias, unread: row.unread,
    }));
    const requests = relations.filter(row => row.status === 'pending').map(row => ({
      relation_id: row.id, alias: row.alias, incoming: row.requester_id !== actor.id,
    }));
    const blocked = this.db.all<{ peer_id: string; alias: string }>(`
      SELECT p.cultivator_id AS peer_id, p.alias FROM social_blocks b
      JOIN social_profiles p ON p.cultivator_id = b.blocked_id
      WHERE b.blocker_id = ? ORDER BY p.alias, p.cultivator_id`, actor.id);
    return { profile, friends, requests, blocked };
  }

  summary(cultivatorId: string | undefined) {
    const contacts = cultivatorId ? this.contacts(cultivatorId) : [];
    return {
      pending_requests: contacts.filter(row => row.status === 'pending' && row.requester_id !== cultivatorId).length,
      unread_messages: contacts.reduce((total, row) => total + row.unread, 0),
    };
  }

  duelContact(actor: Character, relationId: string) {
    const relation = this.accepted(actor, relationId);
    const peerId = this.peer(actor, relation);
    return { peerId, ownAlias: this.profile(actor.id)!.alias, peerAlias: this.profile(peerId)!.alias };
  }

  saveProfile(actor: Character, rawAlias: string, rotate: boolean) {
    this.requireSelf(actor);
    const alias = rawAlias.trim();
    requireCondition(alias.length > 0 && [...alias].length <= 12 && !controlCharacters.test(alias), 'INVALID_ALIAS', '社交昵称需为 1–12 个字符');
    const current = this.profile(actor.id);
    if (!current || rotate || current.alias !== alias) {
      const code = !current || rotate ? randomBytes(8).toString('hex').toUpperCase() : current.invite_code;
      this.db.run(`INSERT INTO social_profiles (cultivator_id, alias, invite_code) VALUES (?, ?, ?)
        ON CONFLICT(cultivator_id) DO UPDATE SET alias = excluded.alias, invite_code = excluded.invite_code`, actor.id, alias, code);
      this.db.touch(actor.account_id);
      if (current && current.alias !== alias) {
        this.db.run(`UPDATE accounts SET revision = revision + 1 WHERE id IN (
          SELECT c.account_id FROM social_relations r JOIN cultivators c
          ON c.id = CASE WHEN r.left_id = ? THEN r.right_id ELSE r.left_id END
          WHERE r.left_id = ? OR r.right_id = ?
          UNION SELECT c.account_id FROM social_blocks b JOIN cultivators c ON c.id = b.blocker_id WHERE b.blocked_id = ?
        )`, actor.id, actor.id, actor.id, actor.id);
      }
    }
    return {};
  }

  invite(actor: Character, rawCode: string) {
    this.requireSelf(actor);
    requireCondition(this.profile(actor.id), 'SOCIAL_PROFILE_REQUIRED', '请先创建社交名片', 409);
    const code = rawCode.replace(/[\s-]/gu, '').toUpperCase();
    const peer = /^[A-F0-9]{16}$/.test(code) ? this.db.get<{ cultivator_id: string }>(
      'SELECT cultivator_id FROM social_profiles WHERE invite_code = ?', code) : undefined;
    requireCondition(peer, 'INVITE_UNAVAILABLE', '邀请码无效或当前无法添加', 404);
    requireCondition(peer.cultivator_id !== actor.id, 'SOCIAL_SELF_REQUEST', '不能给自己发送好友申请', 409);
    const [left, right] = [actor.id, peer.cultivator_id].sort() as [string, string];
    requireCondition(!this.db.get(`SELECT 1 FROM social_blocks
      WHERE (blocker_id = ? AND blocked_id = ?) OR (blocker_id = ? AND blocked_id = ?)`, left, right, right, left),
    'INVITE_UNAVAILABLE', '邀请码无效或当前无法添加', 404);
    const existing = this.db.get<Relation>('SELECT * FROM social_relations WHERE left_id = ? AND right_id = ?', left, right);
    requireCondition(!existing, 'SOCIAL_RELATION_EXISTS', existing?.status === 'accepted' ? '你们已是好友' : '你们之间已有一条好友申请', 409);
    requireCondition(this.countRelations(actor.id, 'pending') < pendingLimit, 'SOCIAL_PENDING_LIMIT', '待处理好友申请已满', 409);
    requireCondition(this.countRelations(peer.cultivator_id, 'pending') < pendingLimit, 'INVITE_UNAVAILABLE', '邀请码无效或当前无法添加', 404);
    this.db.run(`INSERT INTO social_relations (id, left_id, right_id, requester_id, status, updated_at)
      VALUES (?, ?, ?, ?, 'pending', ?)`, id('friend'), left, right, actor.id, this.now());
    this.touchPair(actor, peer.cultivator_id);
    return {};
  }

  respond(actor: Character, relationId: string, action: string) {
    const relation = this.relation(actor, relationId);
    const peer = this.peer(actor, relation);
    const incoming = relation.status === 'pending' && relation.requester_id !== actor.id;
    switch (action) {
      case 'accept':
        requireCondition(incoming, 'SOCIAL_ACTION_UNAVAILABLE', '只有接收方可以接受待处理申请', 409);
        requireCondition(this.countRelations(actor.id, 'accepted') < friendLimit && this.countRelations(peer, 'accepted') < friendLimit,
          'SOCIAL_FRIEND_LIMIT', '一方的好友数量已达上限', 409);
        this.db.run("UPDATE social_relations SET status = 'accepted', updated_at = ? WHERE id = ?", this.now(), relationId);
        break;
      case 'decline':
      case 'cancel':
        requireCondition(relation.status === 'pending' && incoming === (action === 'decline'),
          'SOCIAL_ACTION_UNAVAILABLE', '当前申请无法执行此操作', 409);
        this.db.run('DELETE FROM social_relations WHERE id = ?', relationId);
        break;
      case 'remove':
        requireCondition(relation.status === 'accepted', 'SOCIAL_ACTION_UNAVAILABLE', '当前关系无法移除', 409);
        this.db.run('DELETE FROM social_relations WHERE id = ?', relationId);
        break;
      case 'block': {
        const blocked = this.db.get<{ count: number }>('SELECT COUNT(*) AS count FROM social_blocks WHERE blocker_id = ?', actor.id)!.count;
        requireCondition(blocked < friendLimit, 'SOCIAL_BLOCK_LIMIT', '屏蔽列表已满', 409);
        this.db.run('INSERT INTO social_blocks VALUES (?, ?)', actor.id, peer);
        this.db.run('DELETE FROM social_relations WHERE id = ?', relationId);
        break;
      }
      default: requireCondition(false, 'SOCIAL_ACTION_UNAVAILABLE', '未知的好友操作');
    }
    this.touchPair(actor, peer);
    return {};
  }

  unblock(actor: Character, peerId: string) {
    this.requireSelf(actor);
    const removed = this.db.run('DELETE FROM social_blocks WHERE blocker_id = ? AND blocked_id = ?', actor.id, peerId);
    if (removed.changes) this.db.touch(actor.account_id);
    return {};
  }

  chat(actor: Character, relationId: string, before: number) {
    this.accepted(actor, relationId);
    requireCondition(Number.isSafeInteger(before) && before >= 0, 'INVALID_CURSOR', '消息翻页位置无效');
    const rows = this.db.all<Message>(`SELECT sequence, sender_id, body, sent_at FROM social_messages
      WHERE relation_id = ? ${before ? 'AND sequence < ?' : ''} ORDER BY sequence DESC LIMIT ?`,
    relationId, ...(before ? [before] : []), messagePage + 1);
    const page = rows.slice(0, messagePage);
    return {
      messages: page.toReversed().map(row => ({ sequence: row.sequence, mine: row.sender_id === actor.id, body: row.body, sent_at: row.sent_at })),
      next_before: rows.length > messagePage ? page.at(-1)!.sequence : 0,
    };
  }

  send(actor: Character, relationId: string, rawBody: string) {
    const relation = this.accepted(actor, relationId);
    const body = rawBody.trim();
    requireCondition(body.length > 0 && [...body].length <= 240 && !controlCharacters.test(body), 'INVALID_MESSAGE', '请输入 1–240 个字符的单行消息');
    const now = this.now();
    const recent = this.db.get<{ count: number }>('SELECT COUNT(*) AS count FROM social_messages WHERE sender_id = ? AND sent_at > ?', actor.id, now - 60)!.count;
    requireCondition(recent < 12, 'SOCIAL_RATE_LIMITED', '发送太频繁，请稍后再试', 429);
    const inserted = this.db.run('INSERT INTO social_messages (relation_id, sender_id, body, sent_at) VALUES (?, ?, ?, ?)', relationId, actor.id, body, now);
    this.db.run(`DELETE FROM social_messages WHERE relation_id = ? AND sequence < (
      SELECT sequence FROM social_messages WHERE relation_id = ? ORDER BY sequence DESC LIMIT 1 OFFSET ?
    )`, relationId, relationId, messageLimit - 1);
    this.db.run('UPDATE social_relations SET updated_at = ? WHERE id = ?', now, relationId);
    this.touchPair(actor, this.peer(actor, relation));
    return { sequence: Number(inserted.lastInsertRowid) };
  }

  read(actor: Character, relationId: string, through: number) {
    const relation = this.accepted(actor, relationId);
    requireCondition(Number.isSafeInteger(through) && through >= 1, 'INVALID_CURSOR', '已读位置无效');
    const column = relation.left_id === actor.id ? 'left_read' : 'right_read';
    if (through > relation[column] && this.db.get('SELECT 1 FROM social_messages WHERE relation_id = ? AND sequence = ?', relationId, through)) {
      this.db.run(`UPDATE social_relations SET ${column} = ? WHERE id = ?`, through, relationId);
      this.db.touch(actor.account_id);
    }
    return {};
  }

  private requireSelf(actor: Character) {
    requireCondition(actor.role === 'self', 'SOCIAL_SELF_REQUIRED', '请切换到本人角色使用同道录', 403);
  }

  private profile(id: string) {
    return this.db.get<Profile>('SELECT alias, invite_code FROM social_profiles WHERE cultivator_id = ?', id);
  }

  private countRelations(id: string, status: string) {
    return this.db.get<{ count: number }>('SELECT COUNT(*) AS count FROM social_relations WHERE status = ? AND (left_id = ? OR right_id = ?)', status, id, id)!.count;
  }

  private contacts(id: string) {
    return this.db.all<Contact>(`
      SELECT r.*, p.alias,
        (SELECT COUNT(*) FROM social_messages m WHERE m.relation_id = r.id
         AND m.sequence > CASE WHEN r.left_id = ? THEN r.left_read ELSE r.right_read END
         AND m.sender_id = p.cultivator_id) AS unread
      FROM social_relations r
      JOIN social_profiles p ON p.cultivator_id = CASE WHEN r.left_id = ? THEN r.right_id ELSE r.left_id END
      WHERE r.left_id = ? OR r.right_id = ?
      ORDER BY r.updated_at DESC, r.id DESC`, id, id, id, id);
  }

  private relation(actor: Character, id: string) {
    this.requireSelf(actor);
    const row = this.db.get<Relation>('SELECT * FROM social_relations WHERE id = ? AND (left_id = ? OR right_id = ?)', id, actor.id, actor.id);
    requireCondition(row, 'SOCIAL_RELATION_NOT_FOUND', '找不到这条好友关系', 404);
    return row;
  }

  private accepted(actor: Character, id: string) {
    const row = this.relation(actor, id);
    requireCondition(row.status === 'accepted', 'SOCIAL_FRIEND_REQUIRED', '添加为好友后才能私聊', 409);
    return row;
  }

  private peer(actor: Character, row: Relation) {
    return row.left_id === actor.id ? row.right_id : row.left_id;
  }

  private touchPair(actor: Character, peer: string) {
    this.db.run('UPDATE accounts SET revision = revision + 1 WHERE id IN (?, (SELECT account_id FROM cultivators WHERE id = ?))',
      actor.account_id, peer);
  }
}

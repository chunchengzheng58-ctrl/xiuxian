import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { WebSocket } from 'ws';
import { type Clock, DomainError, digest, requireCondition, secret } from '../core.js';
import { Database } from '../database.js';
import { AuthService, type Session } from '../auth.js';
import { GameService } from '../game/service.js';
import { objectSchema, stringField } from '../contracts.js';
import { type ArenaSubscription } from '../game/arena.js';
import { arenaTickMs } from '../game/arena-match.js';
import type { ExpeditionSubscription } from '../game/expedition.js';

type ConnectedClient = { session: Session; revision: number; alive: boolean; duel?: ArenaSubscription; expedition?: ExpeditionSubscription; inputAt: number };

export class RealtimeHub {
  private clients = new Map<WebSocket, ConnectedClient>();
  private authorized = new WeakMap<FastifyRequest, Session>();
  private timer?: NodeJS.Timeout;
  private arenaTimer?: NodeJS.Timeout;
  constructor(private db: Database, private now: Clock, private auth: AuthService, private game: GameService) {}

  ticket(session: Session) {
    const ticket = secret();
    const expiresAt = this.now() + 60;
    this.db.transaction(() => {
      this.db.run('DELETE FROM realtime_tickets WHERE expires_at <= ?', this.now());
      this.db.run('INSERT INTO realtime_tickets VALUES (?, ?, ?)', digest(ticket), session.token_hash, expiresAt);
    });
    return { ticket, expires_at: expiresAt };
  }

  register(app: FastifyInstance, allowedOrigins: string[]) {
    app.get('/api/v2/realtime', {
      websocket: true,
      schema: { tags: ['realtime'], summary: '一次性票据建立 WebSocket；消息协议见团队接入指南', querystring: objectSchema({ ticket: stringField }) },
      preValidation: async request => {
        requireCondition(request.headers.upgrade?.toLowerCase() === 'websocket', 'UPGRADE_REQUIRED', '需要 WebSocket 升级', 426);
        requireCondition(!request.headers.origin || allowedOrigins.includes(request.headers.origin), 'ORIGIN_REJECTED', '来源未允许', 403);
        const ticket = (request.query as { ticket: string }).ticket;
        const session = this.db.transaction(() => {
          const stored = this.db.get<{ session_hash: string; expires_at: number }>('SELECT * FROM realtime_tickets WHERE token_hash = ?', digest(ticket));
          requireCondition(stored && stored.expires_at > this.now(), 'UNAUTHORIZED', '连接票据无效或过期', 401);
          const authenticated = this.auth.fromHash(stored.session_hash);
          this.db.run('DELETE FROM realtime_tickets WHERE token_hash = ?', digest(ticket));
          return authenticated;
        });
        this.authorized.set(request, session);
      },
    }, (socket, request) => {
      const session = this.authorized.get(request)!;
      this.clients.set(socket, { session, revision: -1, alive: true, inputAt: -Infinity });
      this.sendSnapshot(socket);
      socket.on('pong', () => { const client = this.clients.get(socket); if (client) client.alive = true; });
      socket.on('close', () => this.remove(socket));
      socket.on('error', () => this.remove(socket));
      socket.on('message', raw => {
        try {
          this.auth.fromHash(session.token_hash);
          const message = JSON.parse(raw.toString()) as Record<string, unknown>;
          requireCondition(message && !Array.isArray(message), 'INVALID_MESSAGE', '消息字段无效');
          if (typeof message.type === 'string' && message.type.startsWith('duel_')) {
            this.arenaMessage(socket, message);
          } else if (typeof message.type === 'string' && message.type.startsWith('expedition_')) {
            this.expeditionMessage(socket, message);
          } else if (Object.keys(message).length !== 1) socket.close(1008, 'Invalid message');
          else if (message.type === 'resync') this.sendSnapshot(socket);
          else if (message.type === 'ping') socket.send(JSON.stringify({ type: 'pong', version: 1 }));
          else socket.close(1008, 'Unknown message');
        } catch { socket.close(1008, 'Invalid message or session'); }
      });
    });
    this.timer = setInterval(() => {
      this.flush();
      for (const [socket, client] of this.clients) {
        if (!client.alive) { socket.terminate(); this.remove(socket); continue; }
        client.alive = false;
        socket.ping();
      }
    }, 15000);
    this.timer.unref();
    let last = performance.now();
    let publish = 0;
    this.arenaTimer = setInterval(() => {
      const now = performance.now();
      const steps = Math.min(5, Math.floor((now - last) / arenaTickMs));
      if (!steps) return;
      last = Math.max(last + steps * arenaTickMs, now - arenaTickMs);
      try {
        const duelChanged = this.game.arena.step(steps);
        const expeditionChanged = this.game.expedition.step(steps);
        const changed = duelChanged || expeditionChanged;
        publish += steps;
        if (publish >= 2 || changed) {
          publish = 0;
          for (const [socket, client] of this.clients) if (client.duel) this.sendArena(socket, client);
          for (const [socket, client] of this.clients) if (client.expedition) this.sendExpedition(socket, client);
        }
        if (changed) this.flush();
      } catch (error) {
        app.log.error(error, 'Failed to advance arena');
      }
    }, arenaTickMs);
    this.arenaTimer.unref();
  }

  private arenaMessage(socket: WebSocket, message: Record<string, unknown>) {
    const client = this.clients.get(socket);
    const matchId = message.match_id;
    requireCondition(client && typeof matchId === 'string' && matchId.length <= 80, 'INVALID_MESSAGE', '论剑消息字段无效');
    if (message.type === 'duel_join' && Object.keys(message).length === 2) {
      try {
        const duel = this.game.arena.subscribe(client.session.account_id, matchId);
        if (client.duel?.id === duel.id) { this.sendArena(socket, client); return; }
        this.detach(client);
        for (const [other, current] of this.clients) {
          if (current.duel?.id !== duel.id || current.duel.seat !== duel.seat) continue;
          this.detach(current);
          other.send(JSON.stringify({ type: 'duel_error', version: 1, match_id: matchId, code: 'DUEL_REPLACED', message: '此角色已在另一台设备进入擂台' }));
        }
        client.duel = duel;
        client.inputAt = -Infinity;
        this.game.arena.connect(duel, true);
        this.sendArena(socket, client);
      } catch (error) {
        if (!(error instanceof DomainError)) throw error;
        socket.send(JSON.stringify({ type: 'duel_error', version: 1, match_id: matchId, code: error.code, message: error.message }));
      }
      return;
    }
    if (message.type === 'duel_exit' && Object.keys(message).length === 2) {
      if (client.duel?.id === matchId) this.detach(client);
      return;
    }
    const { seq, x, y, action } = message;
    requireCondition(message.type === 'duel_input' && Object.keys(message).length === 6 &&
      typeof seq === 'number' && Number.isSafeInteger(seq) && seq > 0 &&
      typeof x === 'number' && Number.isFinite(x) && Math.abs(x) <= 1 &&
      typeof y === 'number' && Number.isFinite(y) && Math.abs(y) <= 1 &&
      typeof action === 'number' && Number.isInteger(action) && action >= 0 && action <= 5,
    'INVALID_MESSAGE', '论剑操作字段无效');
    if (client.duel?.id === matchId) {
      const now = performance.now();
      if (now - client.inputAt < 12) return;
      client.inputAt = now;
      this.game.arena.input(client.duel, { seq, x, y, action });
    }
  }

  private sendArena(socket: WebSocket, client: ConnectedClient) {
    if (!client.duel || socket.readyState !== 1) return;
    if (socket.bufferedAmount > 1048576) { socket.terminate(); this.remove(socket); return; }
    const data = this.game.arena.state(client.duel);
    if (!data) { this.detach(client); return; }
    socket.send(JSON.stringify({ type: 'duel_state', version: 1, data }));
    if (data.result) this.detach(client);
  }

  private detach(client: ConnectedClient) {
    if (client.duel) this.game.arena.connect(client.duel, false);
    client.duel = undefined;
    if (client.expedition) this.game.expedition.connect(client.expedition, false);
    client.expedition = undefined;
  }

  private expeditionMessage(socket: WebSocket, message: Record<string, unknown>) {
    const client = this.clients.get(socket);
    const runId = message.run_id;
    requireCondition(client && typeof runId === 'string' && runId.length <= 80, 'INVALID_MESSAGE', '秘境消息字段无效');
    if (message.type === 'expedition_join' && Object.keys(message).length === 2) {
      try {
        const expedition = this.game.expedition.subscribe(client.session.account_id, runId);
        if (client.expedition?.id === runId) { this.sendExpedition(socket, client); return; }
        this.detach(client);
        for (const [other, current] of this.clients) {
          if (current.expedition?.id !== runId) continue;
          this.detach(current);
          other.send(JSON.stringify({ type: 'expedition_error', version: 1, run_id: runId, code: 'EXPEDITION_REPLACED', message: '此角色已在另一台设备进入秘境' }));
        }
        client.expedition = expedition;
        client.inputAt = -Infinity;
        this.game.expedition.connect(expedition, true);
        this.sendExpedition(socket, client);
      } catch (error) {
        if (!(error instanceof DomainError)) throw error;
        socket.send(JSON.stringify({ type: 'expedition_error', version: 1, run_id: runId, code: error.code, message: error.message }));
      }
      return;
    }
    if (message.type === 'expedition_exit' && Object.keys(message).length === 2) {
      if (client.expedition?.id === runId) this.detach(client);
      return;
    }
    const { seq, x, y, action } = message;
    requireCondition(message.type === 'expedition_input' && Object.keys(message).length === 6 &&
      typeof seq === 'number' && Number.isSafeInteger(seq) && seq > 0 &&
      typeof x === 'number' && Number.isFinite(x) && Math.abs(x) <= 1 &&
      typeof y === 'number' && Number.isFinite(y) && Math.abs(y) <= 1 &&
      typeof action === 'number' && Number.isInteger(action) && action >= 0 && action <= 5,
    'INVALID_MESSAGE', '秘境操作字段无效');
    if (client.expedition?.id === runId) {
      const now = performance.now();
      if (now - client.inputAt < 12) return;
      client.inputAt = now;
      this.game.expedition.input(client.expedition, { seq, x, y, action });
    }
  }

  private sendExpedition(socket: WebSocket, client: ConnectedClient) {
    if (!client.expedition || socket.readyState !== 1) return;
    if (socket.bufferedAmount > 1048576) { socket.terminate(); this.remove(socket); return; }
    const data = this.game.expedition.state(client.expedition);
    if (!data) { this.detach(client); return; }
    socket.send(JSON.stringify({ type: 'expedition_state', version: 1, data }));
    if (data.result) this.detach(client);
  }

  private remove(socket: WebSocket) {
    const client = this.clients.get(socket);
    if (client) this.detach(client);
    this.clients.delete(socket);
  }

  flush() {
    for (const [socket, client] of this.clients) {
      if (socket.readyState !== 1) continue;
      if (socket.bufferedAmount > 1048576) { socket.terminate(); this.remove(socket); continue; }
      try { this.auth.fromHash(client.session.token_hash); }
      catch { socket.close(4001, 'Session revoked'); this.remove(socket); continue; }
      const revision = this.db.get<{ revision: number }>('SELECT revision FROM accounts WHERE id = ?', client.session.account_id)!.revision;
      if (revision !== client.revision) {
        socket.send(JSON.stringify({ type: 'state_changed', version: 1, revision }));
        client.revision = revision;
      }
    }
  }

  private sendSnapshot(socket: WebSocket) {
    const client = this.clients.get(socket)!;
    const snapshot = this.game.snapshot(client.session.account_id);
    socket.send(JSON.stringify({ type: 'snapshot', version: 1, revision: snapshot.revision, data: snapshot }));
    client.revision = snapshot.revision;
  }

  close() {
    if (this.timer) clearInterval(this.timer);
    if (this.arenaTimer) clearInterval(this.arenaTimer);
    for (const socket of this.clients.keys()) socket.terminate();
    this.clients.clear();
  }
}

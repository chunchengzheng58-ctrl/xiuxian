export const arenaTickMs = 40;
export const arenaBounds = { left: 220, right: 1220, top: 390, bottom: 715 };
const fightTicks = 90_000 / arenaTickMs;
const readyTicks = 2_000 / arenaTickMs;
const reconnectTicks = 10_000 / arenaTickMs;
const speeds = { walk: 10.4, dash: 32, sword: 35 };
const cooldowns = [0, 11, 32, 20, 39, 125];
const mana = [0, 0, 18, 0, 24, 40];

export type Seat = 0 | 1;
export type ArenaInput = { seq: number; x: number; y: number; action: number };
export type ArenaResult = { winner: Seat | null; reason: string; hp: [number, number] };
type Fighter = {
  x: number; y: number; fx: number; fy: number; hp: number; mp: number; stamina: number;
  maxHp: number; maxMp: number; maxStamina: number; attack: number; defense: number;
  online: boolean; seq: number; moveX: number; moveY: number; inputUntil: number; pending: number;
  cd: number[]; shield: number; shieldTime: number; dash: number; windup: number; strike: number; heal: number;
  pose: string; poseTime: number; hit: number;
};
type Blade = { owner: Seat; x: number; y: number; fx: number; fy: number; life: number };
const seats = [0, 1] as const;
const opposite = (seat: Seat): Seat => seat === 0 ? 1 : 0;
const clamp = (value: number, low: number, high: number) => Math.min(high, Math.max(low, value));

export type FighterStats = { life: number; spirit: number; stamina: number; attack: number; defense: number };
type ArenaOptions = { stats?: [FighterStats, FighterStats]; fightSeconds?: number; reconnectSeconds?: number; bot?: boolean };
function fighter(x: number, facing: number, stats: FighterStats = { life: 100, spirit: 100, stamina: 100, attack: 12, defense: 0 }): Fighter {
  return {
    x, y: 570, fx: facing, fy: 0, hp: stats.life, mp: stats.spirit, stamina: stats.stamina,
    maxHp: stats.life, maxMp: stats.spirit, maxStamina: stats.stamina, attack: stats.attack, defense: stats.defense,
    online: false, seq: 0, moveX: 0, moveY: 0, inputUntil: 0, pending: 0,
    cd: [0, 0, 0, 0, 0, 0], shield: 0, shieldTime: 0, dash: 0, windup: 0, strike: 0, heal: 0,
    pose: 'idle', poseTime: 0, hit: 0,
  };
}

export class ArenaMatch {
  readonly fighters: [Fighter, Fighter];
  readonly blades: Blade[] = [];
  tick = 0;
  phase: 'waiting' | 'countdown' | 'fighting' | 'reconnecting' | 'finished' = 'waiting';
  result: ArenaResult | null = null;
  private countdown = readyTicks;
  private remaining = fightTicks;
  private reconnect = reconnectTicks;
  private readonly bot: boolean;
  private botNextMove = 0;
  private botNextAttack = 0;

  constructor(private waiting: number, options: ArenaOptions = {}) {
    this.fighters = [fighter(520, 1, options.stats?.[0]), fighter(920, -1, options.stats?.[1])];
    this.bot = options.bot ?? false;
    if (this.bot) {
      this.fighters[1] = fighter(920, -1, { life: 86, spirit: 100, stamina: 100, attack: 8, defense: 0 });
      this.fighters[1].online = true;
    }
    this.remaining = (options.fightSeconds ?? 90) * 1000 / arenaTickMs;
    this.reconnect = (options.reconnectSeconds ?? 10) * 1000 / arenaTickMs;
  }

  connect(seat: Seat, online: boolean) {
    if (this.result) return;
    const player = this.fighters[seat];
    player.online = online;
    player.seq = 0;
    player.pending = 0;
    player.moveX = player.moveY = 0;
  }

  input(seat: Seat, input: ArenaInput) {
    const player = this.fighters[seat];
    if (this.phase !== 'fighting' || !player.online || input.seq <= player.seq) return;
    const scale = Math.max(1, Math.hypot(input.x, input.y));
    player.seq = input.seq;
    player.moveX = input.x / scale;
    player.moveY = input.y / scale;
    player.inputUntil = this.tick + 8;
    // Retain one action between ticks; movement packets cannot erase it.
    if (player.pending === 0) player.pending = input.action;
  }

  step() {
    if (this.result) return;
    this.tick++;
    const both = this.fighters.every(player => player.online);
    if (this.phase === 'waiting' || this.phase === 'countdown') {
      this.phase = both ? 'countdown' : 'waiting';
      if (--this.waiting <= 0) { this.finish(null, 'absent'); return; }
      if (!both) this.countdown = readyTicks;
      else if (--this.countdown === 0) {
        this.phase = 'fighting';
        this.botNextMove = this.tick + 20;
        this.botNextAttack = this.tick + 32;
      }
      return;
    }
    if (!both) {
      this.phase = 'reconnecting';
      if (--this.reconnect <= 0) {
        const winner = this.fighters[0].online ? 0 : this.fighters[1].online ? 1 : null;
        this.finish(winner, 'disconnect');
      }
      return;
    }
    this.phase = 'fighting';
    if (this.bot) this.driveBot();
    for (const player of this.fighters) this.move(player);
    this.separate();
    const damage: [number, number] = [0, 0];
    for (const seat of seats) this.resolveStrike(seat, damage);
    this.moveBlades(damage);
    for (const seat of seats) this.applyDamage(this.fighters[seat], damage[seat]);
    if (this.fighters.some(player => player.hp === 0)) this.finish(this.leading(), 'knockout');
    else if (--this.remaining === 0) this.finish(this.leading(), 'time');
  }

  private driveBot() {
    if (this.tick < this.botNextMove) return;
    this.botNextMove = this.tick + 6;
    const [player, bot] = this.fighters;
    const dx = player.x - bot.x;
    const dy = player.y - bot.y;
    const distance = Math.hypot(dx, dy);
    const speed = distance > 104 ? 0.57 : 0.12;
    let action = 0;
    if (this.tick >= this.botNextAttack && distance <= 112 && bot.cd[1] === 0) {
      action = 1;
      this.botNextAttack = this.tick + 34;
    }
    this.input(1, {
      seq: bot.seq + 1, x: dx / Math.max(distance, 1) * speed,
      y: dy / Math.max(distance, 1) * speed, action,
    });
  }

  finish(winner: Seat | null, reason: string): ArenaResult {
    this.result ??= { winner, reason, hp: [this.fighters[0].hp, this.fighters[1].hp] };
    this.phase = 'finished';
    return this.result;
  }

  state() {
    return {
      tick: this.tick, phase: this.phase,
      seconds: Math.ceil((this.phase === 'waiting' ? this.waiting : this.phase === 'countdown' ? this.countdown
        : this.phase === 'reconnecting' ? this.reconnect : this.remaining) * arenaTickMs / 1000),
      players: this.fighters.map(player => ({
        x: player.x, y: player.y, fx: player.fx, hp: player.hp, mp: Math.floor(player.mp), stamina: Math.floor(player.stamina), ack: player.seq,
        max_hp: player.maxHp, max_mp: player.maxMp, max_stamina: player.maxStamina,
        online: player.online, shield: player.shield, dash: player.dash > 0, hit: player.hit > 0,
        pose: player.poseTime > 0 ? player.pose : Math.hypot(player.moveX, player.moveY) > 0.02 && player.inputUntil >= this.tick ? 'walk' : 'idle',
        cd: player.cd,
      })),
      blades: this.blades.map(({ x, y, fx, fy }) => ({ x, y, fx, fy })),
      result: this.result,
    };
  }

  private move(player: Fighter) {
    player.mp = Math.min(player.maxMp, player.mp + 0.28);
    player.stamina = Math.min(player.maxStamina, player.stamina + 0.6);
    player.poseTime = Math.max(0, player.poseTime - 1);
    player.hit = Math.max(0, player.hit - 1);
    if (player.shieldTime > 0 && --player.shieldTime === 0) player.shield = 0;
    for (let i = 1; i < player.cd.length; i++) player.cd[i] = Math.max(0, player.cd[i]! - 1);
    if (player.inputUntil < this.tick) player.moveX = player.moveY = player.pending = 0;
    if (player.dash > 0) player.dash--;
    if (player.dash === 0 && player.windup === 0 && Math.hypot(player.moveX, player.moveY) > 0.02) {
      const length = Math.hypot(player.moveX, player.moveY);
      player.fx = player.moveX / length;
      player.fy = player.moveY / length;
    }
    const action = player.pending;
    player.pending = 0;
    if (action > 0 && player.cd[action] === 0 && player.mp >= mana[action]! && !player.windup && !player.dash && !player.heal) {
      this.activate(player, action);
    }
    const speed = player.heal > 0 ? speeds.walk * 0.3 : player.windup > 0 ? speeds.walk * 0.65 : speeds.walk;
    player.x += player.dash > 0 ? player.fx * speeds.dash : player.moveX * speed;
    player.y += player.dash > 0 ? player.fy * speeds.dash : player.moveY * speed;
    this.clampPlayer(player);
  }

  private activate(player: Fighter, action: number) {
    if (action === 3 && player.stamina < 24) return;
    player.cd[action] = cooldowns[action]!;
    player.mp -= mana[action]!;
    if (action <= 2) {
      player.strike = action;
      player.windup = action === 1 ? 3 : 6;
      player.pose = action === 1 ? 'attack' : 'sword';
      player.poseTime = action === 1 ? 8 : 12;
    } else if (action === 3) {
      player.stamina -= 24;
      player.dash = 5;
      player.pose = 'dash';
      player.poseTime = 5;
    } else if (action === 4) {
      player.shield = 28;
      player.shieldTime = 20;
      player.pose = 'guard';
      player.poseTime = 12;
    } else {
      player.heal = 21;
      player.pose = 'heal';
      player.poseTime = 21;
    }
  }

  private resolveStrike(seat: Seat, damage: [number, number]) {
    const player = this.fighters[seat];
    if (player.windup <= 0 || --player.windup > 0) return;
    const other = opposite(seat);
    const target = this.fighters[other];
    if (player.strike === 2) {
      this.blades.push({ owner: seat, x: player.x, y: player.y, fx: player.fx, fy: player.fy, life: 18 });
    } else {
      const dx = target.x - player.x;
      const dy = target.y - player.y;
      const distance = Math.hypot(dx, dy);
      if (distance <= 128 && dx * player.fx + dy * player.fy >= distance * 0.15 && target.dash === 0) {
        damage[other] += player.attack;
        player.mp = Math.min(player.maxMp, player.mp + 5);
      }
    }
  }

  private moveBlades(damage: [number, number]) {
    for (let index = this.blades.length - 1; index >= 0; index--) {
      const blade = this.blades[index]!;
      const other = opposite(blade.owner);
      const target = this.fighters[other];
      const offsetX = target.x - blade.x;
      const offsetY = target.y - blade.y;
      const forward = clamp(offsetX * blade.fx + offsetY * blade.fy, 0, speeds.sword);
      const hit = Math.hypot(offsetX - blade.fx * forward, offsetY - blade.fy * forward) <= 42 && target.dash === 0;
      if (hit) damage[other] += Math.round(this.fighters[blade.owner].attack * 23 / 12);
      blade.x += blade.fx * speeds.sword;
      blade.y += blade.fy * speeds.sword;
      if (hit || --blade.life === 0) this.blades.splice(index, 1);
    }
  }

  private applyDamage(player: Fighter, raw: number) {
    raw = raw > 0 ? Math.max(1, raw - Math.floor(player.defense * 0.4)) : 0;
    const absorbed = Math.min(player.shield, raw);
    player.shield -= absorbed;
    const damage = raw - absorbed;
    if (damage > 0) {
      player.hp = Math.max(0, player.hp - damage);
      player.hit = 5;
      if (player.heal) {
        player.heal = 0;
        player.poseTime = 0;
      }
    }
    if (player.heal > 0 && --player.heal === 0) player.hp = Math.min(player.maxHp, player.hp + Math.round(player.maxHp * 0.24));
  }

  private clampPlayer(player: Fighter) {
    player.x = clamp(player.x, arenaBounds.left, arenaBounds.right);
    player.y = clamp(player.y, arenaBounds.top, arenaBounds.bottom);
  }

  private separate() {
    const [left, right] = this.fighters;
    const dx = right.x - left.x;
    const dy = right.y - left.y;
    const distance = Math.hypot(dx, dy);
    if (distance >= 45) return;
    const push = (45 - distance) * 0.5;
    const x = distance > 0 ? dx / distance * push : push;
    const y = distance > 0 ? dy / distance * push : 0;
    left.x -= x; left.y -= y;
    right.x += x; right.y += y;
    this.clampPlayer(left); this.clampPlayer(right);
  }

  private leading(): Seat | null {
    const [left, right] = this.fighters;
    return left.hp === right.hp ? null : left.hp > right.hp ? 0 : 1;
  }
}

import assert from 'node:assert/strict';
import test from 'node:test';
import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { backupDatabase, restoreDatabase, verifyBackup } from '../src/backup.js';
import { Database } from '../src/database.js';
import { repositoryRoot } from '../src/contracts.js';
import { buildApp } from '../src/app.js';
import { digest, secret } from '../src/core.js';
import { fixture } from './helpers.js';

function workspace() {
  const root = join(repositoryRoot, 'work', 'backup-tests');
  mkdirSync(root, { recursive: true });
  return mkdtempSync(join(root, 'recovery-'));
}
function content(db: Database) {
  return Object.fromEntries(db.all<{ name: string }>("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT GLOB 'sqlite_*' ORDER BY name")
    .map(({ name }) => [name, db.all(`SELECT * FROM "${name.replace(/"/g, '""')}" ORDER BY rowid`)]));
}
function win(server: Pick<Awaited<ReturnType<typeof fixture>>, 'game'>, accountId: string, runId: string) {
  const subscription = server.game.expedition.subscribe(accountId, runId);
  server.game.expedition.connect(subscription, true);
  for (let sequence = 1; sequence <= 5000; sequence++) {
    const state = server.game.expedition.state(subscription)!;
    if (state.result) { assert.equal(state.result.won, true); return state.result; }
    const player = state.player, enemy = state.enemy;
    const dx = enemy.x - player.x, dy = enemy.y - player.y;
    const distance = Math.hypot(dx, dy);
    let action = distance < 120 ? 1 : 0;
    if (player.hp < player.max_hp * 0.6 && player.cd[5] === 0 && player.mp >= 40) action = 5;
    else if (player.cd[4] === 0 && player.mp >= 24 && state.telegraphs.some(zone => zone.remaining < 0.24)) action = 4;
    server.game.expedition.input(subscription, { seq: sequence, x: distance > 95 ? dx / Math.max(1, distance) : 0,
      y: distance > 95 ? dy / Math.max(1, distance) : 0, action });
    server.game.expedition.step(1);
  }
  throw new Error('Recovery fixture did not finish its actual boss fight');
}

test('WAL在线快照与恢复：真实账号、成长装备、交易、社交、秘境和幂等回执完整恢复并继续交易', async context => {
  const directory = workspace();
  const sourcePath = join(directory, 'live.sqlite');
  const app = await fixture(context, { databasePath: sourcePath });
  const a = await app.account('recovery_seller'), b = await app.account('recovery_buyer');
  const member = async (account: typeof a, name: string) => (await app.command(account.token, 'growth.create_member', {
    role: 'self', name, profile: { title: name, avatar: 'male' }, request_id: secret(),
  })).cultivator_id as string;
  const left = await member(a, '松风'), right = await member(b, '青云');
  const send = (account: typeof a, id: string, command: string, fields: object = {}, key = secret()) =>
    app.command(account.token, command, { cultivator_id: id, ...fields }, key);
  await send(a, left, 'social.profile', { alias: '松风', rotate_code: false });
  await send(b, right, 'social.profile', { alias: '青云', rotate_code: false });
  const code = (await send(b, right, 'social.home')).profile.invite_code;
  await send(a, left, 'social.invite', { invite_code: code });
  const relation = (await send(b, right, 'social.home')).requests[0].relation_id;
  await send(b, right, 'social.respond', { relation_id: relation, action: 'accept' });
  await send(a, left, 'social.send', { relation_id: relation, body: '备份之前的好友消息' }, 'recover-message');
  const run = await send(a, left, 'combat.expedition_start', { stage_id: 'b01' }, 'recover-start');
  const result = win(app, a.account_id, run.run_id);
  const itemId = result.reward.equipment!.equipment_id;
  await send(a, left, 'growth.upgrade', { equipment_id: itemId, expected_level: 0 });
  await send(a, left, 'growth.attune', { equipment_id: itemId, school: 1, expected_school: 0 });
  win(app, b.account_id, (await send(b, right, 'combat.expedition_start', { stage_id: 'b01' })).run_id);
  const listing = await send(a, left, 'growth.market_post', { equipment_id: itemId, price: 40 });
  const buyPayload = { cultivator_id: right, listing_id: listing.listing_id };
  const purchased = await app.command(b.token, 'growth.market_buy', buyPayload, 'recover-buy');
  await send(a, left, 'growth.draw', { count: 1, request_id: 'recover-draw' }, 'recover-draw');
  assert(statSync(sourcePath + '-wal').size > 0, 'The live source really has committed WAL pages');
  const expected = content(app.db);
  const backupPath = join(directory, 'snapshots', 'verified.sqlite');
  const artifact = await (async () => {
    app.db.connection.exec('BEGIN IMMEDIATE');
    app.db.run('UPDATE cultivators SET spirit_stones=888 WHERE id=?', left);
    try { return await backupDatabase(sourcePath, backupPath); }
    finally { app.db.connection.exec('ROLLBACK'); }
  })();
  assert.equal(artifact.manifest.schema_version, app.db.get<{ user_version: number }>('PRAGMA user_version')!.user_version);
  assert.deepEqual(verifyBackup(backupPath), artifact.manifest);
  assert.deepEqual(content(app.db), expected, 'Backup did not mutate live game state');
  assert.equal(statSync(backupPath + '-wal', { throwIfNoEntry: false })?.size ?? 0, 0, 'No WAL file is required to recover the snapshot');
  const restoredPath = join(directory, 'restored', 'game.sqlite');
  const restoration = await restoreDatabase(backupPath, restoredPath);
  assert.equal(restoration.manifest.kind, 'restore');
  const recovered = await buildApp({ databasePath: restoredPath, now: app.now, worker: false, randomInt: () => 0 });
  context.after(() => recovered.app.close());
  assert.deepEqual(content(recovered.db), expected, 'Every persisted domain row, session and idempotency response survived');
  const command = async (token: string, name: string, payload: object, key = secret()) => {
    const response = await recovered.app.inject({ method: 'POST', url: '/api/v2/commands', headers: {
      authorization: `Bearer ${token}`, 'idempotency-key': key,
    }, payload: { version: 1, command: name, payload } });
    assert.equal(response.statusCode, 200, response.body);
    return response.json().data;
  };
  const balances = recovered.db.all('SELECT id, spirit_stones, materials FROM cultivators ORDER BY id');
  assert.deepEqual(await command(b.token, 'growth.market_buy', buyPayload, 'recover-buy'), purchased);
  assert.deepEqual(recovered.db.all('SELECT id, spirit_stones, materials FROM cultivators ORDER BY id'), balances, 'Restored receipts prevent charging the same purchase again');
  const chat = await command(b.token, 'social.chat', { cultivator_id: right, relation_id: relation, before: 0 });
  assert.equal(chat.messages[0].body, '备份之前的好友消息');
  const replay = await command(a.token, 'combat.expedition_leave', { cultivator_id: left, run_id: run.run_id });
  assert.equal(replay.reward.first_clear, true);
  assert.deepEqual(recovered.db.all('SELECT id, spirit_stones, materials FROM cultivators ORDER BY id'), balances, 'Reopening a backed-up result cannot duplicate its reward');
  const repost = await command(b.token, 'growth.market_post', { cultivator_id: right, equipment_id: itemId, price: 20 });
  await command(a.token, 'growth.market_buy', { cultivator_id: left, listing_id: repost.listing_id });
  assert.deepEqual({ ...recovered.db.get<{ cultivator_id: string; school: number; upgrade_level: number }>('SELECT cultivator_id, school, upgrade_level FROM equipment WHERE id = ?', itemId) }, {
    cultivator_id: left, school: 1, upgrade_level: 1,
  });
  assert.equal(recovered.db.get<{ spirit_stones: number }>('SELECT spirit_stones FROM cultivators WHERE id = ?', left)!.spirit_stones, 10);
  assert.equal(recovered.db.get<{ spirit_stones: number }>('SELECT spirit_stones FROM cultivators WHERE id = ?', right)!.spirit_stones, 80);
  writeFileSync(join(directory, 'recovery-summary.json'), JSON.stringify({
    source: sourcePath, backup: artifact, restored: restoration, preserved_tables: Object.keys(expected),
    original_ledger_entries: expected.ledger!.length, continued_trade: true, repeated_purchase_recharged: false,
    final_wallets: recovered.db.all('SELECT name, spirit_stones, materials FROM cultivators ORDER BY name'),
  }, null, 2));
});

test('备份恢复拒绝覆盖、附属文件冲突、篡改和损坏，失败不改变源或已有目标', async () => {
  const directory = workspace();
  const sourcePath = join(directory, 'live.sqlite');
  const source = new Database(sourcePath);
  try {
    const backupPath = join(directory, 'snapshot.sqlite');
    await backupDatabase(sourcePath, backupPath);
    const original = readFileSync(backupPath);
    await assert.rejects(backupDatabase(sourcePath, backupPath), { code: 'BACKUP_DESTINATION_EXISTS' });
    await assert.rejects(restoreDatabase(backupPath, sourcePath), { code: 'BACKUP_DESTINATION_EXISTS' });
    assert.deepEqual(readFileSync(backupPath), original);
    const blocked = join(directory, 'blocked.sqlite');
    writeFileSync(blocked + '-wal', 'existing-user-journal');
    await assert.rejects(restoreDatabase(backupPath, blocked), { code: 'BACKUP_DESTINATION_EXISTS' });
    assert.equal(readFileSync(blocked + '-wal', 'utf8'), 'existing-user-journal');
    assert.equal(existsSync(blocked), false);
    const bytes = Buffer.from(original);
    bytes[bytes.length - 5] = bytes[bytes.length - 5]! ^ 1;
    writeFileSync(backupPath, bytes);
    const target = join(directory, 'tampered-restore.sqlite');
    await assert.rejects(restoreDatabase(backupPath, target), { code: 'BACKUP_HASH_MISMATCH' });
    assert.equal(existsSync(target), false);
    const damaged = join(directory, 'damaged.sqlite');
    writeFileSync(damaged, 'this is not a sqlite database');
    const before = readFileSync(damaged);
    await assert.rejects(backupDatabase(damaged, join(directory, 'damaged-backup.sqlite')));
    assert.deepEqual(readFileSync(damaged), before);
    writeFileSync(backupPath, original);
    writeFileSync(backupPath + '.manifest.json', 'null');
    await assert.rejects(restoreDatabase(backupPath, target), { code: 'BACKUP_MANIFEST_INVALID' });
  } finally { source.close(); }
});

test('未来数据库版本与迁移记录篡改安全拒绝，校验不会迁移源文件', async () => {
  const directory = workspace();
  const sourcePath = join(directory, 'future.sqlite');
  const current = new Database(sourcePath);
  const version = current.get<{ user_version: number }>('PRAGMA user_version')!.user_version;
  current.connection.exec(`PRAGMA user_version = ${version + 1}`);
  current.close();
  const bytes = readFileSync(sourcePath);
  await assert.rejects(backupDatabase(sourcePath, join(directory, 'rejected.sqlite')), { code: 'BACKUP_VERSION' });
  assert.deepEqual(readFileSync(sourcePath), bytes);
  const raw = new DatabaseSync(sourcePath);
  raw.exec(`PRAGMA user_version = ${version}`);
  raw.prepare("UPDATE schema_migrations SET checksum = 'changed' WHERE version = 1").run();
  raw.close();
  const changed = readFileSync(sourcePath);
  await assert.rejects(backupDatabase(sourcePath, join(directory, 'changed.sqlite')), { code: 'BACKUP_SCHEMA' });
  assert.deepEqual(readFileSync(sourcePath), changed);
});

test('备份文件被重新用作运行库时拒绝恢复，防止只验证主文件而漏掉WAL中的变化', async () => {
  const directory = workspace();
  const sourcePath = join(directory, 'source.sqlite');
  const source = new Database(sourcePath);
  source.close();
  const backupPath = join(directory, 'snapshot.sqlite');
  await backupDatabase(sourcePath, backupPath);
  const changed = new Database(backupPath);
  try {
    changed.run('INSERT INTO accounts (id, username, password_hash, salt, created_at) VALUES (?, ?, ?, ?, ?)', 'wal-account', 'wal-test', 'not-a-login-secret', 'test', 1);
    assert(statSync(backupPath + '-wal').size > 0);
    await assert.rejects(restoreDatabase(backupPath, join(directory, 'rejected.sqlite')), { code: 'BACKUP_IN_USE' });
  } finally { changed.close(); }
});

test('上一版本数据库可备份并恢复，新程序迁移只发生在恢复副本而非原库或备份', async () => {
  const directory = workspace();
  const sourcePath = join(directory, 'previous-version.sqlite');
  const sql = Array.from(readFileSync(join(repositoryRoot, 'server/src/database.ts'), 'utf8').matchAll(/String\.raw`([\s\S]*?)`/g), match => match[1]!);
  assert(sql.length >= 2);
  const previousVersion = sql.length - 1;
  const old = new DatabaseSync(sourcePath);
  old.exec('PRAGMA foreign_keys=ON; CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, checksum TEXT NOT NULL)');
  for (let index = 0; index < previousVersion; index++) {
    old.exec(sql[index]!);
    old.prepare('INSERT INTO schema_migrations VALUES (?, ?)').run(index + 1, digest(sql[index]!));
  }
  old.exec(`PRAGMA user_version=${previousVersion}`);
  old.prepare('INSERT INTO accounts (id,username,password_hash,salt,created_at) VALUES (?,?,?,?,?)').run('previous-account', 'previous_player', 'test-only', 'salt', 1);
  old.close();
  const original = readFileSync(sourcePath);
  const backupPath = join(directory, 'previous-backup.sqlite');
  const artifact = await backupDatabase(sourcePath, backupPath);
  assert.equal(artifact.manifest.schema_version, previousVersion);
  const restoredPath = join(directory, 'migrated-copy.sqlite');
  await restoreDatabase(backupPath, restoredPath);
  assert.deepEqual(readFileSync(sourcePath), original);
  assert.equal(verifyBackup(backupPath).schema_version, previousVersion);
  const restored = new Database(restoredPath);
  try {
    assert.equal(restored.get<{ user_version: number }>('PRAGMA user_version')!.user_version, sql.length);
    assert.equal(restored.get<{ username: string }>('SELECT username FROM accounts WHERE id=?', 'previous-account')!.username, 'previous_player');
  } finally { restored.close(); }
  assert.deepEqual(readFileSync(sourcePath), original);
  assert.equal(verifyBackup(backupPath).schema_version, previousVersion);
});

test('战斗中备份恢复按服务中断结算，不伪造胜利或影响仍在原库运行的战斗', async context => {
  const directory = workspace();
  const sourcePath = join(directory, 'fighting.sqlite');
  const app = await fixture(context, { databasePath: sourcePath });
  const account = await app.account('recover_fighter');
  const member = await app.command(account.token, 'growth.create_member', { role: 'self', name: '行者', profile: { title: '行者', avatar: 'male' }, request_id: secret() });
  const run = await app.command(account.token, 'combat.expedition_start', { cultivator_id: member.cultivator_id, stage_id: 'b01' }, secret());
  const subscription = app.game.expedition.subscribe(account.account_id, run.run_id);
  app.game.expedition.connect(subscription, true);
  app.game.expedition.step(80);
  assert.equal(app.game.expedition.state(subscription)!.phase, 'fighting');
  const backupPath = join(directory, 'in-combat-backup.sqlite');
  await backupDatabase(sourcePath, backupPath);
  const restoredPath = join(directory, 'safe-restart.sqlite');
  await restoreDatabase(backupPath, restoredPath);
  const restarted = await buildApp({ databasePath: restoredPath, now: app.now, worker: false });
  context.after(() => restarted.app.close());
  const final = restarted.game.expedition.state({ id: run.run_id })!;
  assert.equal(final.result!.won, false);
  assert.equal(final.result!.reason, 'interrupted');
  assert.equal(final.result!.reward.spirit_stones, 0);
  assert.equal(restarted.game.characterSnapshot(account.account_id, member.cultivator_id).resources.spirit_stones, 0);
  assert.equal(app.game.expedition.state(subscription)!.result, null, 'Recovery checks never touch the original active room');
  assert.equal(app.db.get<{ result: string | null }>('SELECT result FROM expedition_runs WHERE id=?', run.run_id)!.result, null);
});

test('未迁移的触发器、视图、表和索引全部拒绝，上一版本也不能夹带未知对象通过恢复检查', async () => {
  const objects = [
    "CREATE TRIGGER unexpected_wallet AFTER UPDATE OF spirit_stones ON cultivators BEGIN UPDATE cultivators SET spirit_stones=999999 WHERE id=NEW.id; END",
    'CREATE VIEW unexpected_accounts AS SELECT id, username FROM accounts',
    'CREATE TABLE unexpected_wallet (account_id TEXT, balance INTEGER)',
    'CREATE INDEX unexpected_accounts_index ON accounts(created_at)',
    // LIKE 'sqlite_%' would wrongly hide this name because '_' is a wildcard.
    'CREATE VIEW sqlitewallet AS SELECT id, spirit_stones FROM cultivators',
  ];
  const migrations = Array.from(readFileSync(join(repositoryRoot, 'server/src/database.ts'), 'utf8').matchAll(/String\.raw`([\s\S]*?)`/g), match => match[1]!);
  for (const previous of [false, true]) {
    for (const sql of objects) {
      const directory = workspace();
      const sourcePath = join(directory, 'modified-schema.sqlite');
      if (previous) {
        const old = new DatabaseSync(sourcePath);
        old.exec('PRAGMA foreign_keys=ON; CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, checksum TEXT NOT NULL)');
        for (let index = 0; index < migrations.length - 1; index++) {
          old.exec(migrations[index]!);
          old.prepare('INSERT INTO schema_migrations VALUES (?, ?)').run(index + 1, digest(migrations[index]!));
        }
        old.exec(`PRAGMA user_version=${migrations.length - 1}`);
        old.exec(sql);
        old.close();
      } else {
        const current = new Database(sourcePath);
        current.connection.exec(sql);
        current.close();
      }
      const bytes = readFileSync(sourcePath);
      const target = join(directory, 'rejected.sqlite');
      await assert.rejects(backupDatabase(sourcePath, target), { code: 'BACKUP_SCHEMA' }, `${previous ? 'previous' : 'current'} schema: ${sql}`);
      assert.equal(existsSync(target), false);
      assert.equal(existsSync(target + '.manifest.json'), false);
      assert.deepEqual(readFileSync(sourcePath), bytes, 'Rejected schema verification leaves its source unchanged');
    }
  }
});

test('公开排位恢复：真实KO积分与战绩保留，运行中排位恢复为中断且不计分', async context => {
  const directory = workspace();
  const sourcePath = join(directory, 'ranked.sqlite');
  const app = await fixture(context, { databasePath: sourcePath });
  const create = async (username: string, alias: string) => {
    const account = await app.account(username);
    const member = await app.command(account.token, 'growth.create_member', {
      role: 'self', name: alias, profile: { title: alias, avatar: 'male' }, request_id: secret(),
    });
    const id = member.cultivator_id as string;
    await app.command(account.token, 'social.profile', { cultivator_id: id, alias, rotate_code: false }, secret());
    const send = (command: string, fields: object = {}) => app.command(account.token, command, { cultivator_id: id, ...fields }, secret());
    return { ...account, id, send };
  };
  const left = await create('recover_rank_left', '松风'), right = await create('recover_rank_right', '云栖');
  const pair = async () => {
    await left.send('combat.matchmaking_join');
    const joined = await right.send('combat.matchmaking_join');
    const matchId = joined.active.match_id as string;
    const first = app.game.arena.subscribe(left.account_id, matchId), second = app.game.arena.subscribe(right.account_id, matchId);
    app.game.arena.connect(first, true);
    app.game.arena.connect(second, true);
    app.game.arena.step(50);
    assert.equal(app.game.arena.state(first)!.phase, 'fighting');
    return { matchId, first, second };
  };
  const completed = await pair();
  for (let sequence = 1; sequence <= 1500 && !app.game.arena.state(completed.first)!.result; sequence++) {
    const state = app.game.arena.state(completed.first)!;
    const player = state.players[completed.first.seat]!, enemy = state.players[completed.second.seat]!;
    const dx = enemy.x - player.x, dy = enemy.y - player.y, distance = Math.hypot(dx, dy);
    app.game.arena.input(completed.first, { seq: sequence, x: distance > 85 ? dx / Math.max(1, distance) : 0,
      y: distance > 85 ? dy / Math.max(1, distance) : 0, action: distance < 120 ? 1 : 2 });
    app.game.arena.step(1);
  }
  const result = app.game.arena.state(completed.first)!;
  assert.equal(result.result!.reason, 'knockout');
  assert.equal(result.result!.winner, completed.first.seat);
  assert.deepEqual(result.rating_change, { before: 1000, after: 1012, delta: 12 });
  const lobby = await left.send('combat.matchmaking_lobby');
  const ratings = app.db.all('SELECT * FROM arena_ratings ORDER BY cultivator_id');
  const persistedWin = app.db.get('SELECT * FROM arena_duels WHERE id=?', completed.matchId);
  app.advance(1);
  const active = await pair();
  const backupPath = join(directory, 'ranked-backup.sqlite');
  await backupDatabase(sourcePath, backupPath);
  const restoredPath = join(directory, 'ranked-restored.sqlite');
  await restoreDatabase(backupPath, restoredPath);
  const restored = await buildApp({ databasePath: restoredPath, now: app.now, worker: false });
  context.after(() => restored.app.close());
  assert.deepEqual(restored.db.all('SELECT * FROM arena_ratings ORDER BY cultivator_id'), ratings);
  assert.deepEqual(restored.db.get('SELECT * FROM arena_duels WHERE id=?', completed.matchId), persistedWin);
  const restoredLobby = restored.game.arena.matchmakingLobby(restored.game.own(left.account_id, left.id));
  assert.deepEqual(restoredLobby.leaderboard, lobby.leaderboard);
  assert.deepEqual(restoredLobby.rating, lobby.rating);
  const interrupted = restored.game.arena.state({ id: active.matchId, seat: active.first.seat })!;
  assert.equal(interrupted.result!.reason, 'interrupted');
  assert.equal(interrupted.rating_change, null);
  for (const matchId of [completed.matchId, active.matchId]) {
    restored.game.arena.leave(restored.game.own(left.account_id, left.id), matchId);
  }
  restored.game.arena.step(3000);
  assert.deepEqual(restored.db.all('SELECT * FROM arena_ratings ORDER BY cultivator_id'), ratings, 'Reopening restored results and advancing time cannot count either match again');
  assert.equal(app.game.arena.state(active.first)!.result, null, 'Original ranked room remains running');
  assert.equal(app.db.get<{ status: string }>('SELECT status FROM arena_duels WHERE id=?', active.matchId)!.status, 'active');
});

test('即使清单散列被重新计算，恢复仍拒绝当前或上一版本中夹带的钱包触发器', async () => {
  const migrations = Array.from(readFileSync(join(repositoryRoot, 'server/src/database.ts'), 'utf8').matchAll(/String\.raw`([\s\S]*?)`/g), match => match[1]!);
  for (const previous of [false, true]) {
    const directory = workspace();
    const sourcePath = join(directory, 'clean-source.sqlite');
    if (previous) {
      const old = new DatabaseSync(sourcePath);
      old.exec('PRAGMA foreign_keys=ON; CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, checksum TEXT NOT NULL)');
      for (let index = 0; index < migrations.length - 1; index++) {
        old.exec(migrations[index]!);
        old.prepare('INSERT INTO schema_migrations VALUES (?, ?)').run(index + 1, digest(migrations[index]!));
      }
      old.exec(`PRAGMA user_version=${migrations.length - 1}`);
      old.close();
    } else new Database(sourcePath).close();
    const original = readFileSync(sourcePath);
    const backupPath = join(directory, 'modified-backup.sqlite');
    const artifact = await backupDatabase(sourcePath, backupPath);
    const modified = new DatabaseSync(backupPath);
    modified.exec('CREATE TRIGGER unexpected_wallet AFTER UPDATE OF spirit_stones ON cultivators BEGIN UPDATE cultivators SET spirit_stones=999999 WHERE id=NEW.id; END');
    modified.close();
    const modifiedBytes = readFileSync(backupPath);
    artifact.manifest.sha256 = createHash('sha256').update(modifiedBytes).digest('hex');
    artifact.manifest.bytes = modifiedBytes.length;
    writeFileSync(artifact.manifest_path, JSON.stringify(artifact.manifest));
    const restored = join(directory, 'must-not-restore.sqlite');
    await assert.rejects(restoreDatabase(backupPath, restored), { code: 'BACKUP_SCHEMA' });
    assert.equal(existsSync(restored), false);
    assert.deepEqual(readFileSync(backupPath), modifiedBytes, 'Rejected backup is retained for inspection');
    assert.deepEqual(readFileSync(sourcePath), original, 'The clean source is untouched');
  }
});

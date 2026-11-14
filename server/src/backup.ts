import { backup, DatabaseSync } from 'node:sqlite';
import { chmodSync, closeSync, existsSync, linkSync, lstatSync, mkdirSync, mkdtempSync, openSync, readFileSync, readSync, realpathSync, rmdirSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { Database } from './database.js';
import { requireCondition } from './core.js';

type Migration = { version: number; checksum: string };
type SchemaEntry = { type: string; name: string; sql: string | null };
export type BackupManifest = {
  format: 'xiuxian-sqlite-backup-v1'; kind: 'backup' | 'restore'; created_at: string;
  file: string; bytes: number; sha256: string; schema_version: number;
  migrations: Migration[]; tables: Record<string, number>;
};
export type BackupArtifact = { database_path: string; manifest_path: string; manifest: BackupManifest };
const sidecars = ['-wal', '-shm', '-journal'];
const normalize = (sql: string | null) => sql?.replace(/\s+/g, ' ').trim();
function fileHash(path: string) {
  const input = openSync(path, 'r');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  const hash = createHash('sha256');
  try {
    let bytes: number;
    while ((bytes = readSync(input, buffer)) > 0) hash.update(buffer.subarray(0, bytes));
    return hash.digest('hex');
  } finally { closeSync(input); }
}
const present = (path: string) => { try { lstatSync(path); return true; } catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false; throw error; } };

function openSource(path: string) {
  requireCondition(path !== ':memory:' && existsSync(path) && statSync(path).isFile(), 'BACKUP_SOURCE_MISSING', '需要一个已存在的数据库文件');
  // Inspection and SQLite online backup never migrate or write the source.
  return new DatabaseSync(path, { readOnly: true, timeout: 5000, allowExtension: false });
}

function currentSchema() {
  const reference = new Database(':memory:');
  try {
    return {
      version: reference.get<{ user_version: number }>('PRAGMA user_version')!.user_version,
      migrations: reference.all<Migration>('SELECT version, checksum FROM schema_migrations ORDER BY version'),
      entries: reference.all<SchemaEntry>("SELECT type, name, sql FROM sqlite_schema WHERE name NOT GLOB 'sqlite_*' ORDER BY type, name"),
    };
  } finally { reference.close(); }
}

function inspect(connection: DatabaseSync) {
  const integrity = connection.prepare('PRAGMA integrity_check').all() as { integrity_check: string }[];
  requireCondition(integrity.length === 1 && integrity[0]?.integrity_check === 'ok', 'BACKUP_CORRUPT', '数据库完整性检查失败');
  requireCondition(connection.prepare('PRAGMA foreign_key_check').all().length === 0, 'BACKUP_CORRUPT', '数据库外键检查失败');
  const version = (connection.prepare('PRAGMA user_version').get() as { user_version: number }).user_version;
  const current = currentSchema();
  requireCondition(Number.isSafeInteger(version) && version > 0 && version <= current.version,
    'BACKUP_VERSION', '数据库版本不受当前程序支持，请使用匹配版本的程序');
  const migrations = (connection.prepare('SELECT version, checksum FROM schema_migrations ORDER BY version').all() as Migration[])
    .map(({ version, checksum }) => ({ version, checksum }));
  requireCondition(migrations.length === version && migrations.every((migration, index) =>
    migration.version === index + 1 && migration.checksum === current.migrations[index]?.checksum),
  'BACKUP_SCHEMA', '数据库迁移记录缺失或与当前程序不一致');
  const tables: Record<string, number> = {};
  const entries = connection.prepare("SELECT type, name, sql FROM sqlite_schema WHERE name NOT GLOB 'sqlite_*' ORDER BY type, name").all() as SchemaEntry[];
  if (version === current.version) {
    requireCondition(entries.length === current.entries.length && current.entries.every(expected => entries.some(actual => actual.type === expected.type && actual.name === expected.name && normalize(actual.sql) === normalize(expected.sql))),
      'BACKUP_SCHEMA', '数据库结构与已记录迁移不一致');
  }
  for (const entry of entries.filter(entry => entry.type === 'table')) {
    const identifier = '"' + entry.name.replace(/"/g, '""') + '"';
    tables[entry.name] = (connection.prepare(`SELECT COUNT(*) AS count FROM ${identifier}`).get() as { count: number }).count;
  }
  return { schema_version: version, migrations, tables };
}

function ensureNewDestination(path: string) {
  requireCondition(!present(path) && !sidecars.some(suffix => present(path + suffix)) && !present(path + '.manifest.json'),
    'BACKUP_DESTINATION_EXISTS', '目标路径或其数据库附属文件已存在，请指定全新的文件名');
}

function removeStage(directory: string) {
  // Only exact files created inside our fresh private directory are removed.
  for (const file of ['snapshot.sqlite', 'compatible.sqlite', 'manifest.json']) {
    for (const suffix of ['', ...sidecars]) {
      const path = join(directory, file + suffix);
      if (present(path)) unlinkSync(path);
    }
  }
  rmdirSync(directory);
}

async function snapshot(sourcePath: string, destinationPath: string, kind: 'backup' | 'restore'): Promise<BackupArtifact> {
  const source = resolve(sourcePath);
  const destination = resolve(destinationPath);
  ensureNewDestination(destination);
  requireCondition(source !== destination, 'BACKUP_DESTINATION_EXISTS', '源数据库和目标数据库必须分开');
  const input = openSource(source);
  let stage: string | undefined;
  try {
    // This also rejects unrelated/future databases before generating a backup.
    inspect(input);
    mkdirSync(dirname(destination), { recursive: true });
    const parent = realpathSync(dirname(destination));
    stage = mkdtempSync(join(parent, '.xiuxian-snapshot-'));
    const stagedDatabase = join(stage, 'snapshot.sqlite');
    await backup(input, stagedDatabase, { rate: 100 });
    chmodSync(stagedDatabase, 0o600);
    const readback = openSource(stagedDatabase);
    let info: ReturnType<typeof inspect>;
    try { info = inspect(readback); } finally { readback.close(); }
    // Check old-version upgrade compatibility on a second disposable copy. The
    // delivered snapshot retains the original schema and the source stays read-only.
    if (info.schema_version < currentSchema().version) {
      const validationSource = openSource(stagedDatabase);
      const compatiblePath = join(stage, 'compatible.sqlite');
      try { await backup(validationSource, compatiblePath); } finally { validationSource.close(); }
      const compatible = new Database(compatiblePath);
      try { inspect(compatible.connection); } finally { compatible.close(); }
    }
    const manifest: BackupManifest = {
      format: 'xiuxian-sqlite-backup-v1', kind, created_at: new Date().toISOString(), file: basename(destination),
      bytes: statSync(stagedDatabase).size, sha256: fileHash(stagedDatabase), ...info,
    };
    const stagedManifest = join(stage, 'manifest.json');
    writeFileSync(stagedManifest, JSON.stringify(manifest, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    if (kind === 'restore') verifyBackup(source);
    // Atomic exclusive publication on the same filesystem. SQLite's backup API
    // overwrites its destination, so it only ever receives a private staging path.
    ensureNewDestination(destination);
    linkSync(stagedDatabase, destination);
    try { linkSync(stagedManifest, destination + '.manifest.json'); }
    catch (error) {
      // Roll back our own hard link, never a pre-existing or replaced user file.
      const published = lstatSync(destination);
      const owned = statSync(stagedDatabase);
      if (published.dev === owned.dev && published.ino === owned.ino) unlinkSync(destination);
      throw error;
    }
    return { database_path: destination, manifest_path: destination + '.manifest.json', manifest };
  } finally {
    input.close();
    if (stage) removeStage(stage);
  }
}

/** Create a consistent online SQLite snapshot, including committed WAL data. */
export function backupDatabase(source: string, destination: string) { return snapshot(source, destination, 'backup'); }

/** Verify a previously published database and its adjacent hash manifest without migrating it. */
export function verifyBackup(path: string): BackupManifest {
  const source = resolve(path);
  requireCondition(present(source + '.manifest.json'), 'BACKUP_MANIFEST_MISSING', '缺少备份清单，请保留数据库和对应的 manifest.json');
  let parsed: unknown;
  try { parsed = JSON.parse(readFileSync(source + '.manifest.json', 'utf8')); }
  catch { requireCondition(false, 'BACKUP_MANIFEST_INVALID', '备份清单无法读取'); }
  requireCondition(parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed), 'BACKUP_MANIFEST_INVALID', '备份清单格式无效');
  const manifest = parsed as BackupManifest;
  requireCondition(manifest.format === 'xiuxian-sqlite-backup-v1' && ['backup', 'restore'].includes(manifest.kind)
    && typeof manifest.sha256 === 'string' && /^[0-9a-f]{64}$/.test(manifest.sha256) && Number.isSafeInteger(manifest.bytes), 'BACKUP_MANIFEST_INVALID', '备份清单格式无效');
  requireCondition(!present(source + '-wal') || statSync(source + '-wal').size === 0,
    'BACKUP_IN_USE', '备份文件存在写入日志，请勿将正在使用的数据库作为待恢复备份');
  const input = openSource(source);
  try {
    requireCondition(statSync(source).size === manifest.bytes && fileHash(source) === manifest.sha256,
      'BACKUP_HASH_MISMATCH', '备份文件与清单校验不一致，请保留原文件并检查备份来源');
    const info = inspect(input);
    requireCondition(info.schema_version === manifest.schema_version && JSON.stringify(info.migrations) === JSON.stringify(manifest.migrations)
      && JSON.stringify(info.tables) === JSON.stringify(manifest.tables), 'BACKUP_MANIFEST_INVALID', '备份清单和实际数据库不一致');
    return manifest;
  } finally { input.close(); }
}

/** Restore only to a fresh path. Selecting it as DATABASE_PATH is a separate operator action. */
export async function restoreDatabase(source: string, destination: string) {
  ensureNewDestination(resolve(destination));
  verifyBackup(source);
  return snapshot(source, destination, 'restore');
}

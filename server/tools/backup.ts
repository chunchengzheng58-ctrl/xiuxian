import { join, resolve } from 'node:path';
import { repositoryRoot } from '../src/contracts.js';
import { backupDatabase } from '../src/backup.js';

const [source, target, ...extra] = process.argv.slice(2);
if (!source || extra.length) {
  console.error('用法：npm run backup -- <源数据库> [全新备份路径]');
  process.exitCode = 1;
} else {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  try {
    const result = await backupDatabase(resolve(source), target ? resolve(target) : join(repositoryRoot, 'outputs', 'backups', `game-${timestamp}.sqlite`));
    console.log(JSON.stringify(result, null, 2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : '备份失败');
    process.exitCode = 1;
  }
}

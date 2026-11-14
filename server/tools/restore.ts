import { resolve } from 'node:path';
import { restoreDatabase } from '../src/backup.js';

const [source, target, ...extra] = process.argv.slice(2);
if (!source || !target || extra.length) {
  console.error('用法：npm run restore -- <备份数据库> <全新恢复路径>');
  process.exitCode = 1;
} else {
  try {
    console.log(JSON.stringify(await restoreDatabase(resolve(source), resolve(target)), null, 2));
    console.log('已恢复至全新文件；原数据库未改动。验证后再将 DATABASE_PATH 指向新文件。');
  } catch (error) {
    console.error(error instanceof Error ? error.message : '恢复失败');
    process.exitCode = 1;
  }
}

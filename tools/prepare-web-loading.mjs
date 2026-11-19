// Run after each Godot Web export: node tools/prepare-web-loading.mjs <export directory>
import {mkdirSync, copyFileSync} from 'node:fs';
import {resolve, dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
if (!process.argv[2]) throw Error('Provide the Godot Web export directory');
const target = resolve(process.argv[2], 'loading');
mkdirSync(target, {recursive: true});
for (const [source, name] of [
  ['cinematics/op-opening-cg.mp4', 'opening.mp4'],
  ['cinematics/op-title-card-ui.png', 'title.png'],
  ['assets/pixel/cultivator-walk.png', 'runner.png'],
]) copyFileSync(join(repo, source), join(target, name));
console.log('Web opening and loading assets prepared:', target);

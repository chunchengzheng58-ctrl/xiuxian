// Run after each Godot Web export: node tools/prepare-web-loading.mjs <export directory>
import {mkdirSync, copyFileSync, readFileSync, writeFileSync} from 'node:fs';
import {resolve, dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
if (!process.argv[2]) throw Error('Provide the Godot Web export directory');
const target = resolve(process.argv[2], 'loading');
mkdirSync(target, {recursive: true});
for (const [source, name] of [
  ['cinematics/op-title-card-ui.png', 'title.png'],
]) copyFileSync(join(repo, source), join(target, name));
console.log('Web opening and loading assets prepared:', target);
copyFileSync(join(repo, 'web/game-cache-sw.js'), resolve(process.argv[2], 'game-cache-sw.js'));
// Propagate stream failures into Godot's retry/error handling, avoiding a permanently pending load.
const engineFile = resolve(process.argv[2], 'index.js');
let engine = readFileSync(engineFile, 'utf8');
const before = 'controller.close();\n\t\t\t\t});';
const after = 'controller.close();\n\t\t\t\t}).catch(function (error) { controller.error(error); });';
if (!engine.includes(after)) {
  if (!engine.includes(before)) throw Error('Godot stream loader changed; verify error propagation before publishing');
  engine = engine.replace(before, after);
  writeFileSync(engineFile, engine);
}

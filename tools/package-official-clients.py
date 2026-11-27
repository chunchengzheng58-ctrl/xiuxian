"""Package matching official Web/Windows exports; generated artifacts stay under build/."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import zipfile

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-commit', required=True)
parser.add_argument('--godot-notices', required=True, type=Path)
args = parser.parse_args()
if not re.fullmatch(r'[0-9a-f]{40}', args.source_commit):
    parser.error('A full GitHub source commit is required')
version = json.loads((root / 'data/client-release.json').read_text(encoding='utf-8'))
web = root / 'build/web'
windows = root / 'build/windows-official'
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
if digest(windows / 'Xiuxian.exe') != 'd34d36f3be1a6c49c56525ae86469b92e4f417ddf0b43cf00dd80c385c4b0562':
    raise SystemExit('Unexpected Windows engine identity')
for path in [web / 'index.pck', web / 'index.wasm', windows / 'Xiuxian.pck']:
    if path.stat().st_size < 1024:
        raise SystemExit('Missing/empty export: ' + str(path))
manifest = {**version, 'source_commit': args.source_commit, 'artifacts': {
    'web_pck_sha256': digest(web / 'index.pck'),
    'web_wasm_sha256': digest(web / 'index.wasm'),
    'windows_pck_sha256': digest(windows / 'Xiuxian.pck'),
    'windows_exe_sha256': digest(windows / 'Xiuxian.exe'),
}}
raw = json.dumps(manifest, ensure_ascii=False, indent=2) + '\n'
for folder in [web, windows]:
    (folder / 'release.json').write_text(raw, encoding='utf-8', newline='\n')
licenses = windows / 'licenses'
licenses.mkdir(exist_ok=True)
for name in ['GODOT-LICENSE.txt', 'GODOT-COPYRIGHT.txt']:
    shutil.copyfile(args.godot_notices / name, licenses / name)
shutil.copyfile(root / 'assets/fonts/OFL.txt', licenses / 'FONT-OFL.txt')
(windows / '使用说明.txt').write_text(
    '疯狂修仙，中 · ' + version['version'] + '\n\n'
    '完整解压后运行 Xiuxian.exe，保持同目录的 Xiuxian.pck。无需安装 Node.js 或配置 API 密钥。\n'
    '正式客户端与 https://madxiuxian.com 共用同一账号、服务器、角色、好友和游戏规则。\n'
    '设置页显示版本号。神遁榜入口：同道录 → 神遁榜。\n'
    '导入本人今日穿戴摘要并确认后，可选择不公开、仅好友或全服及好友。1 步＝1 丈，可反推步数。\n'
    'PTDS 导出工具见 tools/export_ptds_summary.py（仅此可选工具需要 Python 3）。\n'
    '本地设备授权、导出文件和登录会话不自动跨端传输。\n'
    '开发源码：https://github.com/chunchengzheng58-ctrl/xiuxian/tree/' + args.source_commit + '\n',
    encoding='utf-8', newline='\n')
tools = windows / 'tools'
tools.mkdir(exist_ok=True)
shutil.copyfile(root / 'tools/export_ptds_summary.py', tools / 'export_ptds_summary.py')
archive = root / 'build' / Path(version['windows_download']).name
# Explicit allowlist: no .env, account data, local test overrides, scripts or server credentials.
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as package:
    for name in ['Xiuxian.exe', 'Xiuxian.pck', 'release.json', '使用说明.txt',
                 'licenses/GODOT-LICENSE.txt', 'licenses/GODOT-COPYRIGHT.txt', 'licenses/FONT-OFL.txt',
                 'tools/export_ptds_summary.py']:
        package.write(windows / name, name)
(archive.parent / (archive.name + '.sha256')).write_text(digest(archive) + '  ' + archive.name + '\n', encoding='ascii')
print(json.dumps({'version': version['version'], 'source_commit': args.source_commit,
                  'zip': str(archive), 'bytes': archive.stat().st_size, 'sha256': digest(archive)}, ensure_ascii=False))

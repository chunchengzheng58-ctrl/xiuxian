import {mkdirSync,writeFileSync,readFileSync,existsSync,cpSync,statSync,mkdtempSync,readdirSync,openSync,closeSync} from 'node:fs';
import {resolve,join,dirname,basename} from 'node:path';
import {fileURLToPath} from 'node:url';
import {inflateRawSync,crc32} from 'node:zlib';
import {createHash} from 'node:crypto';
import {spawnSync,execFileSync} from 'node:child_process';

const project=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const work=join(project,'work/windows-build');
const output=resolve(process.env.XIUXIAN_WINDOWS_OUTPUT??join(project,'../../outputs/commercial-preview/windows'));
const asset='https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz';
const downloadSource='https://downloads.godotengine.org/?version=4.7.2&flavor=stable&slug=export_templates.tpz&platform=templates';
const templates=join(work,'templates');
mkdirSync(templates,{recursive:true});
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
async function range(start,end){
 const requested=start<0?`bytes=${start}`:`bytes=${start}-${end??''}`;
 const response=await fetch(downloadSource,{headers:{Range:requested},signal:AbortSignal.timeout(120000)});
 if(response.status!==206){await response.body?.cancel();throw new Error(`Official asset did not honor HTTP Range (${response.status}); use a complete verified TPZ instead.`);}
 const contentRange=response.headers.get('content-range');
 if(!contentRange)throw new Error('Missing Content-Range');
 const bytes=Buffer.from(await response.arrayBuffer());
 return {bytes,contentRange};
}
async function fetchTemplates(){
 const tail=await range(-65536);
 const eocd=tail.bytes.lastIndexOf(Buffer.from([0x50,0x4b,0x05,0x06]));
 if(eocd<0)throw new Error('ZIP directory footer missing');
 const directorySize=tail.bytes.readUInt32LE(eocd+12),directoryOffset=tail.bytes.readUInt32LE(eocd+16);
 const {bytes:directory}=await range(directoryOffset,directoryOffset+directorySize-1);
 const selected=[];
 for(let offset=0;offset<directory.length;){
  if(directory.readUInt32LE(offset)!==0x02014b50)throw new Error('Invalid ZIP directory');
  const method=directory.readUInt16LE(offset+10),crc=directory.readUInt32LE(offset+16),compressed=directory.readUInt32LE(offset+20),uncompressed=directory.readUInt32LE(offset+24);
  const nameLength=directory.readUInt16LE(offset+28),extraLength=directory.readUInt16LE(offset+30),commentLength=directory.readUInt16LE(offset+32),position=directory.readUInt32LE(offset+42);
  const name=directory.subarray(offset+46,offset+46+nameLength).toString('utf8');
  if(/(^|\/)(windows_release_x86_64(?:_console)?\.exe|version\.txt)$/.test(name)){
   const local=(await range(position,position+29)).bytes;
   if(local.readUInt32LE(0)!==0x04034b50)throw new Error('Invalid local ZIP header');
   const dataOffset=position+30+local.readUInt16LE(26)+local.readUInt16LE(28);
   const packed=(await range(dataOffset,dataOffset+compressed-1)).bytes;
   const data=method===8?inflateRawSync(packed):method===0?packed:null;
   if(!data||data.length!==uncompressed||(crc32(data)>>>0)!==crc)throw new Error(`ZIP CRC/size failed: ${name}`);
   const destination=join(templates,basename(name));
   writeFileSync(destination,data);
   selected.push({name,bytes:data.length,crc32:crc.toString(16),sha256:hash(data)});
   console.log(`OFFICIAL_TEMPLATE ${name} ${data.length} bytes CRC verified`);
  }
  offset+=46+nameLength+extraLength+commentLength;
 }
 if(!existsSync(join(templates,'windows_release_x86_64.exe')))throw new Error('Official Windows x64 release template missing');
 writeFileSync(join(templates,'provenance.json'),JSON.stringify({source:asset,officialDownload:downloadSource,method:'official HTTPS ZIP range extraction; each selected entry size and CRC32 verified; full TPZ SHA256 not verified',entries:selected},null,2));
}
async function prepareLicenses(){
 const entries=[['GODOT-LICENSE.txt','https://raw.githubusercontent.com/godotengine/godot/4.7.2-stable/LICENSE.txt'],
  ['NODE-LICENSE.txt',`https://raw.githubusercontent.com/nodejs/node/${process.version}/LICENSE`]];
 for(const[name,url]of entries)if(!existsSync(join(templates,name))){
  const response=await fetch(url,{signal:AbortSignal.timeout(30000)});
  if(!response.ok)throw new Error('Official license download failed: '+url);
  writeFileSync(join(templates,name),Buffer.from(await response.arrayBuffer()));
 }
}
if(process.argv.includes('--templates-only')){await fetchTemplates();await prepareLicenses();process.exit(0);}
const sourceTemplate=resolve(process.env.GODOT_WINDOWS_RELEASE??join(templates,'windows_release_x86_64.exe'));
if(!existsSync(sourceTemplate))throw new Error('Official Windows x64 release template missing. Run --templates-only or set GODOT_WINDOWS_RELEASE to a verified 4.7.2 release template.');
if(hash(readFileSync(sourceTemplate))!=='d34d36f3be1a6c49c56525ae86469b92e4f417ddf0b43cf00dd80c385c4b0562')throw new Error('Windows release template differs from the verified official 4.7.2 template.');
const engine=process.env.GODOT4_CONSOLE??'D:/Projects/Codex/tools/godot-4.7.2/Godot_v4.7.2-stable_win64_console.exe';
const env={...process.env,APPDATA:join(work,'appdata'),TEMP:join(work,'tmp'),TMP:join(work,'tmp')};
mkdirSync(env.TEMP,{recursive:true});
mkdirSync(output,{recursive:true});
function run(command,args,label,cwd=project){
 const logPath=join(work,label+'.log'),fd=openSync(logPath,'w');
 const result=spawnSync(command,args,{cwd,env,stdio:['ignore',fd,fd],windowsHide:true,timeout:240000});closeSync(fd);
 if(result.error||result.status!==0)throw new Error(`${label} failed; see ${logPath}: ${result.error??result.status}`);
 console.log(`${label}: passed`);
}
const filter=path=>!['.git','.godot','node_modules','work','output','outputs','.env'].includes(basename(path));
function files(directory,prefix=''){
 return readdirSync(directory,{withFileTypes:true}).flatMap(entry=>{
  if(!prefix&&entry.name==='data-save')return [];
  const name=prefix?prefix+'/'+entry.name:entry.name;
  return entry.isDirectory()?files(join(directory,entry.name),name):[{name,bytes:statSync(join(directory,entry.name)).size,sha256:hash(readFileSync(join(directory,entry.name)))}];
 });
}
const sourcePaths=execFileSync('git',['ls-files','-c','-o','--exclude-standard','-z'],{cwd:project,encoding:'utf8'}).split('\0').filter(name=>
 /^(scripts\/|scenes\/|assets\/|data\/)/.test(name)||['project.godot','icon.svg'].includes(name)).sort();
const sourceHashes=sourcePaths.map(name=>({name,sha256:hash(readFileSync(join(project,name)))}));
const fingerprint=hash(JSON.stringify(sourceHashes));
if(!existsSync(join(templates,'GODOT-COPYRIGHT.txt'))){
 env.XIUXIAN_GODOT_LICENSE_OUTPUT=join(templates,'GODOT-COPYRIGHT.txt');
 run(engine,['--headless','--path',project,'--script',join(project,'tools/pack-windows.licenses.gd'),'--quit'],'windows-licenses');
}
if(!process.argv.includes('--runtime-only')&&!process.argv.includes('--finalize')){
 const snapshot=mkdtempSync(join(work,'project-'));
 for(const name of ['assets','data','scripts','scenes','addons','project.godot','icon.svg'])cpSync(join(project,name),join(snapshot,name),{recursive:true,filter});
 const preset=`[preset.0]\nname="Windows"\nplatform="Windows Desktop"\nrunnable=true\nadvanced_options=false\ndedicated_server=false\ncustom_features=""\nexport_filter="all_resources"\ninclude_filter=""\nexclude_filter="addons/godot_ai/*,assets/combat_animations/*_actions_*"\nexport_path="Xiuxian.exe"\nscript_export_mode=2\n\n[preset.0.options]\ncustom_template/debug="${sourceTemplate.replaceAll('\\','/')}"\ncustom_template/release="${sourceTemplate.replaceAll('\\','/')}"\ndebug/export_console_wrapper=0\nbinary_format/embed_pck=false\nbinary_format/architecture="x86_64"\napplication/modify_resources=false\ntexture_format/bptc=false\ntexture_format/s3tc=true\ntexture_format/etc=false\ntexture_format/etc2=false\n`;
 writeFileSync(join(snapshot,'export_presets.cfg'),preset);
 run(engine,['--headless','--editor','--path',snapshot,'--import','--quit'],'windows-import');
 run(engine,['--headless','--path',snapshot,'--export-release','Windows',join(output,'Xiuxian.exe')],'windows-export');
 if(/SCRIPT ERROR|ERROR:/.test(readFileSync(join(work,'windows-export.log'),'utf8')))throw new Error('Windows export reported an error; see log.');
 writeFileSync(join(work,'client-source.json'),JSON.stringify({fingerprint,files:sourceHashes,snapshot},null,2));
}
if(!process.argv.includes('--client-only')){
 if(!existsSync(join(project,'server/dist/src/app.js')))throw new Error('Build server first.');
 const previous=JSON.parse(readFileSync(join(work,'client-source.json'),'utf8'));
 if(previous.fingerprint!==fingerprint)throw new Error('Runtime source changed after client export; re-export before publishing.');
 if(!process.argv.includes('--finalize')){
 mkdirSync(join(output,'server/dist'),{recursive:true});
 cpSync(join(project,'server/dist/src'),join(output,'server/dist/src'),{recursive:true,filter:path=>statSync(path).isDirectory()||path.endsWith('.js')});
 cpSync(join(project,'data'),join(output,'data'),{recursive:true});
 const packageJson=JSON.parse(readFileSync(join(project,'server/package.json'),'utf8'));
 writeFileSync(join(output,'server/package.json'),JSON.stringify({name:packageJson.name,type:'module',version:packageJson.version,engines:packageJson.engines,dependencies:packageJson.dependencies},null,2));
 const lock=JSON.parse(readFileSync(join(project,'server/package-lock.json'),'utf8'));
 for(const [name,metadata]of Object.entries(lock.packages))if(name.startsWith('node_modules/')&&!metadata.dev){
  const source=join(project,'server',name);
  if(!existsSync(source))throw new Error('Missing production dependency '+name);
  cpSync(source,join(output,'server',name),{recursive:true});
 }
 mkdirSync(join(output,'runtime'),{recursive:true});
 cpSync(process.execPath,join(output,'runtime/node.exe'));
 }
 mkdirSync(join(output,'server/dist/tools'),{recursive:true});
 for(const name of ['backup.js','restore.js'])cpSync(join(project,'server/dist/tools',name),join(output,'server/dist/tools',name));
 mkdirSync(join(output,'docs'),{recursive:true});
 for(const name of ['DATABASE_RECOVERY.md','WINDOWS_BUILD.md','PLAYTEST_GUIDE.md','CAMPAIGN_PLAYTEST.md']){
  cpSync(join(project,'docs',name),join(output,'docs',name));
 }
 cpSync(join(project,'tools/pack-windows.runtime.mjs'),join(output,'desktop.mjs'));
 mkdirSync(join(output,'licenses'),{recursive:true});
 for(const name of ['GODOT-LICENSE.txt','GODOT-COPYRIGHT.txt','NODE-LICENSE.txt','provenance.json']){
  if(!existsSync(join(templates,name)))throw new Error('Missing official license/provenance '+name);
  cpSync(join(templates,name),join(output,'licenses',name));
 }
 cpSync(join(project,'assets/fonts/OFL.txt'),join(output,'licenses/FONT-OFL.txt'));
 writeFileSync(join(output,'Play.vbs'),'Option Explicit\r\nDim fso, sh, folder, q, command, status\r\nSet fso = CreateObject("Scripting.FileSystemObject")\r\nSet sh = CreateObject("WScript.Shell")\r\nfolder = fso.GetParentFolderName(WScript.ScriptFullName)\r\nq = Chr(34)\r\nIf Not fso.FileExists(folder & "\\Xiuxian.exe") Then\r\n MsgBox "Extract the complete Windows release package first.", 16, "Xiuxian"\r\n WScript.Quit 1\r\nEnd If\r\ncommand = q & folder & "\\runtime\\node.exe" & q & " " & q & folder & "\\desktop.mjs" & q\r\nstatus = sh.Run(command, 0, True)\r\nIf status <> 0 Then\r\n MsgBox "Unable to start. Close other copies using this save folder and inspect data-save/logs/desktop.log.", 16, "Xiuxian"\r\nEnd If\r\nWScript.Quit status\r\n');
 writeFileSync(join(output,'README.txt'),'疯狂修仙，中 · Windows x64 独立试玩版\r\n\r\n请完整解压至D盘可写目录，双击 Play.vbs。无需安装Godot、Node或npm。\r\n后台服务只监听本机随机端口；同一目录可再次双击打开第二个游戏窗口，使用不同账号测试社交/交易/对战。关闭全部窗口后服务会自动退出。\r\n本包默认使用独立的新账号数据库，与源码8080试玩服务分开。原账号无法在新库登录不表示旧档丢失；请新建测试账号或按docs的可选备份恢复流程迁入副本。不会自动迁移、覆盖或指向运行中的旧库。\r\n存档、客户端缓存及日志位于本目录 data-save；升级或搬动文件夹时完整保留该目录。可用 XIUXIAN_DESKTOP_DATA 指定固定D盘数据目录。另一版本仍占用该数据时请先关闭其窗口再切换，不能同时运行两个模拟服务。\r\n随包包含 server/dist/tools/backup.js 与 restore.js，可用 runtime/node.exe 调用；恢复只到全新路径，操作说明见docs/DATABASE_RECOVERY.md与WINDOWS_BUILD.md。\r\n本包使用官方Godot4.7.2 Windows release模板，内含Node24运行时与生产依赖；不是开发引擎改名。\r\n健康资料识别与微信等外部服务需另行配置；本人PVE/抽卡/装备/公开匹配不需要提交健康资料。\r\n验证记录与文件SHA见manifest.json。\r\n');
 const manifest={format:'xiuxian-windows-preview-v1',builtAt:new Date().toISOString(),runtime:'Godot 4.7.2 official Windows x64 release template',
  sourceCommit:execFileSync('git',['rev-parse','HEAD'],{cwd:project,encoding:'utf8'}).trim(),uncommittedSource:true,runtimeSourceFingerprint:fingerprint,
  runtimeSourceScope:'scripts/, scenes/, assets/, data/, project.godot, icon.svg (excludes Web HTML and shared export preset; Windows uses an isolated platform preset)',
  node:process.version,templateProvenance:JSON.parse(readFileSync(join(templates,'provenance.json'),'utf8')),dataDirectory:'data-save',
  files:files(output).filter(file=>file.name!=='manifest.json'&&!file.name.startsWith('data-save/'))};
 writeFileSync(join(output,'manifest.json'),JSON.stringify(manifest,null,2));
 console.log('WINDOWS_PACKAGE '+output);
}

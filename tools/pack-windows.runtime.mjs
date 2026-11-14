import {existsSync,mkdirSync,readFileSync,writeFileSync,unlinkSync,openSync,closeSync,writeSync,appendFileSync} from 'node:fs';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {createHash,randomUUID} from 'node:crypto';
import net from 'node:net';
import {spawn} from 'node:child_process';

const root=dirname(fileURLToPath(import.meta.url));
const data=resolve(process.env.XIUXIAN_DESKTOP_DATA??join(root,'data-save'));
mkdirSync(join(data,'logs'),{recursive:true});
const logPath=join(data,'logs/desktop.log');
// A first double-click can reach spawn before an asynchronous WriteStream has
// opened its fd. Numeric descriptors are ready immediately and safe for stdio.
const logFd=openSync(logPath,'a');
let logClosed=false;
const report=message=>{
 const line=new Date().toISOString()+' '+message+'\n';
 if(logClosed)appendFileSync(logPath,line);else writeSync(logFd,line);
};
const endLog=()=>{if(!logClosed){closeSync(logFd);logClosed=true;}};
process.on('uncaughtExceptionMonitor',(error,origin)=>{
 try{appendFileSync(logPath,new Date().toISOString()+' Fatal '+origin+': '+(error.stack??error)+'\n');}catch{}
});
process.once('exit',endLog);
report('Desktop launcher started PID '+process.pid);
const manifest=JSON.parse(readFileSync(join(root,'manifest.json'),'utf8'));
const build=manifest.runtimeSourceFingerprint;
// The data directory owns the process lock. A relocated/updated package cannot
// start a second simulator against a database still used by an older copy.
const pipe='\\\\.\\pipe\\xiuxian-'+createHash('sha256').update(data.toLowerCase()).digest('hex').slice(0,24);
const request={root,build,nonce:randomUUID(),action:process.argv.includes('--service-test')?'status':'launch'};
async function existing(){
 return new Promise((res,rej)=>{
  const socket=net.connect(pipe),timer=setTimeout(()=>{socket.destroy();rej(new Error('Desktop service handshake timed out'));},10000);
  let bytes='';
  socket.once('error',error=>{clearTimeout(timer);rej(error);});
  socket.once('connect',()=>socket.write(JSON.stringify(request)+'\n'));
  socket.on('data',chunk=>{bytes+=chunk;if(!bytes.includes('\n'))return;clearTimeout(timer);socket.end();
   try{const result=JSON.parse(bytes.split('\n')[0]);if(result.root!==root||result.build!==build||result.nonce!==request.nonce||!result.ok)throw new Error(result.message??'Desktop service identity mismatch');res(result);}catch(error){rej(error);}});
 });
}
let first=false;
let reused;
try{reused=await existing();}catch(error){
 if(!['ENOENT','ECONNREFUSED'].includes(error.code))throw error;
 first=true;
}
if(!first){if(request.action==='status')console.log(JSON.stringify(reused));endLog();}else{
 let app,port,closing=false,idle;
 const games=new Set();
 let readyResolve,readyReject;
 const ready=new Promise((res,rej)=>{readyResolve=res;readyReject=rej;});
 const stop=async()=>{if(closing)return;closing=true;clearTimeout(idle);server.close();if(app)await app.app.close();
  const state=join(data,'desktop-session.json');
  if(existsSync(state)&&JSON.parse(readFileSync(state,'utf8')).pid===process.pid)unlinkSync(state);
  report('Local service stopped');endLog();};
 const scheduleStop=()=>{clearTimeout(idle);idle=setTimeout(()=>{if(games.size===0)void stop();},3000);};
 const launch=()=>{
  const executable=join(root,'Xiuxian.exe');
  if(!existsSync(executable))throw new Error('Xiuxian.exe is missing; extract the complete Windows release package.');
  clearTimeout(idle);
  const args=['--rendering-method','gl_compatibility','--log-file',join(data,'logs/game-'+Date.now()+'.log')];
  if(process.env.XIUXIAN_GAME_ARGS_JSON)args.push(...JSON.parse(process.env.XIUXIAN_GAME_ARGS_JSON));
  const child=spawn(executable,args,{cwd:root,windowsHide:false,stdio:['ignore',logFd,logFd],env:{...process.env,
   APPDATA:join(data,'appdata'),XIUXIAN_BACKEND_URL:`http://127.0.0.1:${port}`}});
  games.add(child);
  child.once('error',error=>{report('Game launch failed: '+error.message);games.delete(child);scheduleStop();});
  child.once('exit',(code)=>{report('Game exited: '+code);games.delete(child);if(games.size===0)scheduleStop();});
  report('Game launched PID '+child.pid);return child.pid;
 };
 const answer=async message=>{
  if(message.root!==root||message.build!==build||typeof message.nonce!=='string'||!['launch','status'].includes(message.action))throw new Error('Desktop service identity mismatch');
  await ready;
  return {ok:true,root,build,nonce:message.nonce,pid:process.pid,port,data,game_pid:message.action==='launch'?launch():null};
 };
 const server=net.createServer(socket=>{let bytes='';socket.setTimeout(12000,()=>socket.destroy());socket.on('data',chunk=>{
  bytes+=chunk;if(bytes.length>8192){socket.destroy();return;}if(!bytes.includes('\n'))return;
  const text=bytes.split('\n')[0];bytes='';
  void(async()=>{try{socket.end(JSON.stringify(await answer(JSON.parse(text)))+'\n');}catch(error){socket.end(JSON.stringify({ok:false,root,build,nonce:request.nonce,message:error.message})+'\n');}})();
 });});
 try{
  await new Promise((res,rej)=>{server.once('error',rej);server.listen(pipe,res);});
 }catch(error){
  if(error.code==='EADDRINUSE'){await existing();endLog();process.exit(0);}throw error;
 }
 try{
  const {buildApp}=await import(pathToFileURL(join(root,'server/dist/src/app.js')));
  app=await buildApp({databasePath:join(data,'server/var/game.sqlite')});
  await app.app.listen({host:'127.0.0.1',port:0});
  port=app.app.server.address().port;
  if(port===8080)throw new Error('The operating system selected reserved port 8080; restart the desktop launcher.');
  writeFileSync(join(data,'desktop-session.json'),JSON.stringify({root,build,pid:process.pid,port,data,pipe},null,2));
  report('Local service listening on 127.0.0.1:'+port);readyResolve();
  const result=await answer(request);
  if(request.action==='status'){console.log(JSON.stringify(result));idle=setTimeout(()=>void stop(),15000);}
 }catch(error){readyReject(error);report('Startup failed: '+error.stack);await stop();throw error;}
 for(const signal of ['SIGINT','SIGTERM'])process.once(signal,()=>void stop());
}

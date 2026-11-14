import {spawn} from 'node:child_process';
import {randomUUID,createHash} from 'node:crypto';
import {mkdirSync,mkdtempSync,writeFileSync,readFileSync,existsSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import net from 'node:net';
const project=resolve(fileURLToPath(new URL('../..',import.meta.url)));
const base=join(project,'work/playtests');mkdirSync(base,{recursive:true});
const work=mkdtempSync(join(base,'equipment-async-'));
mkdirSync(join(work,'temp'));process.env.TEMP=join(work,'temp');process.env.TMP=join(work,'temp');
const {buildApp}=await import(pathToFileURL(join(project,'server/dist/src/app.js')));
const server=await buildApp({worker:false,databasePath:':memory:'});
const marker=name=>join(work,name);
async function waitForFile(name){const end=Date.now()+15000;while(!existsSync(marker(name))&&Date.now()<end)await new Promise(r=>setTimeout(r,20));assert(existsSync(marker(name)),name);}
let buyerId,accountId,holdEquipList=false,droppedDraw=false;const held=new Set(),sockets=new Set();
// Hold a real HTTP reply after the unchanged application commits it. WebSocket
// traffic continues normally, exposing an older reply arriving after newer data.
const proxy=createServer(async(request,response)=>{
 try{
  const chunks=[];for await(const chunk of request)chunks.push(chunk);
  const body=Buffer.concat(chunks);let command;
  try{command=JSON.parse(body).command;}catch{}
  const headers={...request.headers};delete headers.host;delete headers.connection;
  const upstream=await fetch(new URL(request.url,server.app.listeningOrigin),{method:request.method,headers,body:body.length?body:undefined});
  const payload=Buffer.from(await upstream.arrayBuffer());
  if(command==='growth.draw'&&!droppedDraw){
   droppedDraw=true;writeFileSync(marker('draw-committed'),'1');
   response.writeHead(503,{'content-type':'application/json'});response.end(JSON.stringify({ok:false,code:'BACKEND_UNAVAILABLE',message:'fixture: committed response lost',data:{}}));return;
  }
  if(command==='growth.list'&&holdEquipList){
   holdEquipList=false;held.add('equip-list');
   server.db.transaction(()=>{server.game.ledger.change(accountId,buyerId,'spirit_stones',31,randomUUID(),'test_only');server.db.touch(accountId);});
   server.realtime.flush();writeFileSync(marker('held-equip-list'),'1');
   await waitForFile('release-equip-list');
  }
  const name={'growth.equip':'equip','growth.set_wish':'wish','growth.market_buy':'buy'}[command];
  if(name&&!held.has(name)){
   held.add(name);writeFileSync(marker('held-'+name),'1');
   if(name==='equip'||name==='wish'){
    await waitForFile('advance-'+name);
    server.db.transaction(()=>{server.game.ledger.change(accountId,buyerId,'spirit_stones',123,randomUUID(),'test_only');server.db.touch(accountId);});
    server.realtime.flush();
   }
   await waitForFile('release-'+name);
   if(name==='equip')holdEquipList=true;
  }
  response.writeHead(upstream.status,Object.fromEntries(upstream.headers));response.end(payload);
 }catch(error){response.writeHead(500);response.end(String(error));}
});
proxy.on('connection',socket=>{sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});
proxy.on('upgrade',(request,socket,head)=>{
 const target=new URL(server.app.listeningOrigin),upstream=net.connect({host:target.hostname,port:Number(target.port)});
 upstream.once('connect',()=>{upstream.write(`${request.method} ${request.url} HTTP/1.1\r\n`+request.rawHeaders.reduce((h,value,index)=>h+value+(index%2?'\r\n':': '),'')+'\r\n');if(head.length)upstream.write(head);socket.pipe(upstream).pipe(socket);});
 upstream.on('error',()=>socket.destroy());socket.on('error',()=>upstream.destroy());socket.once('close',()=>upstream.destroy());
});
try{
 const create=async username=>{const a=await server.auth.register({username,password:'equipment-async-password'});const c=server.game.execute(a.account_id,'growth.create_member',{role:'self',name:username.slice(0,10),profile:{title:username.slice(0,10),avatar:'female'},request_id:randomUUID()});return {account:a.account_id,id:c.cultivator_id};};
 const buyer=await create('async_buyer'),seller=await create('async_seller');buyerId=buyer.id;accountId=buyer.account;
 const first=server.game.execute(accountId,'combat.expedition_start',{cultivator_id:buyerId,stage_id:'b01'},randomUUID());
 server.game.execute(accountId,'combat.expedition_leave',{cultivator_id:buyerId,run_id:first.run_id});
 server.db.transaction(()=>server.game.ledger.change(accountId,buyerId,'spirit_stones',1000,randomUUID(),'test_only'));
 for(const[id,owner,template,slot]of [['async-buyer-item',buyerId,0,'weapon'],['async-seller-item',seller.id,1,'robe']])server.db.run('INSERT INTO equipment(id,cultivator_id,catalogue_id,catalogue_version,slot,rarity,school) VALUES(?,?,?,?,?,?,?)',id,owner,'pixel:'+template,'pixel-equipment-v1',slot,'epic',0);
 const listing=server.game.execute(seller.account,'growth.market_post',{cultivator_id:seller.id,equipment_id:'async-seller-item',price:100},randomUUID());
 writeFileSync(marker('fixture.json'),JSON.stringify({listing_id:listing.listing_id}));
 await server.app.listen({host:'127.0.0.1',port:0});
 await new Promise((resolve,reject)=>proxy.once('error',reject).listen(0,'127.0.0.1',resolve));
 const child=spawn(process.env.GODOT4_CONSOLE??'D:/Projects/Codex/tools/godot-4.7.2/Godot_v4.7.2-stable_win64_console.exe',['--headless','--path',project,'--script','res://tools/playtests/equipment-async.gd','--log-file',marker('client.log'),'--','--kernel-ephemeral','--skip-intro'],{windowsHide:true,env:{...process.env,APPDATA:marker('appdata'),XIUXIAN_BACKEND_URL:'http://127.0.0.1:'+proxy.address().port,XIUXIAN_EQUIPMENT_ASYNC_WORK:work},stdio:['ignore','pipe','pipe']});
 let output='';for(const stream of [child.stdout,child.stderr])stream.on('data',data=>output+=data);
 const timer=setTimeout(()=>child.kill(),80000);
 const code=await new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject)}).finally(()=>clearTimeout(timer));
 const log=existsSync(marker('client.log'))?readFileSync(marker('client.log'),'utf8'):output;
 const result=JSON.parse(readFileSync(marker('result.json'),'utf8'));
 const final=server.game.characterSnapshot(accountId,buyerId);
 const serverChecks={wallet:final.resources.spirit_stones===1107,originalPurchasedItem:final.equipment.some(item=>item.equipment_id==='async-seller-item'),inventory:final.equipment.length===3,onePurchase:server.db.all("SELECT * FROM ledger WHERE reason='market_buy'").length===1,oneDrawDebit:JSON.stringify(server.db.all("SELECT delta FROM ledger WHERE reason='draw'").map(row=>row.delta))==='[-70]'};
 const inputs=Object.fromEntries(['scripts/treasure_panel.gd','scripts/equipment_market_panel.gd'].map(name=>[name,createHash('sha256').update(readFileSync(join(project,name))).digest('hex')]));
 const report={passed:code===0&&result.failures===0&&!/SCRIPT ERROR|ERROR:/.test(log)&&Object.values(serverChecks).every(Boolean),work,inputs,client:result,serverChecks,wallet:final.resources,inventory:final.equipment,held:[...held],expectedFault:'A committed draw reply becomes one injected HTTP 503; the original idempotency key is retried.',scope:'Explicit memory database, synthetic trading balances/equipment only for async fault isolation, random local HTTP/WS proxy, separate D-drive APPDATA. This is not natural campaign/economy evidence.'};
 writeFileSync(marker('report.json'),JSON.stringify(report,null,2));
 console.log(log);console.log(JSON.stringify({work,passed:report.passed}));
 assert.equal(report.passed,true,'Equipment async boundary regression');
}finally{for(const socket of sockets)socket.destroy();await new Promise(resolve=>proxy.close(resolve));await server.app.close();}


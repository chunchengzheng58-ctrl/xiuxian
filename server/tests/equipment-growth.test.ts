import assert from 'node:assert/strict';
import test, { type TestContext } from 'node:test';
import { secret } from '../src/core.js';
import { defaultProviders } from '../src/game/rules.js';
import { equipmentBonuses, type GrowingEquipment } from '../src/game/equipment-growth.js';
import { fixture } from './helpers.js';

async function setup(context: TestContext, randomInt = (_maximum: number) => 0) {
  const app = await fixture(context, { providers: defaultProviders, randomInt });
  const account = await app.account();
  const character = await app.command(account.token, 'growth.create_member', {
    role: 'self', name: '剑客', profile: { title: '剑客', avatar: 'male' }, request_id: secret(),
  });
  const id = character.cultivator_id as string;
  const send = (command: string, fields: Record<string, unknown> = {}, key = typeof fields.request_id === 'string' ? fields.request_id : secret()) => app.command(account.token, command, {cultivator_id: id, ...fields}, key);
  const request = (command: string, fields: Record<string, unknown>) => app.request('/api/v2/commands',
    { version: 1, command, payload: {cultivator_id: id, ...fields} }, account.token, 'POST', typeof fields.request_id === 'string' ? fields.request_id : secret());
  const fund = (resource: string, amount: number) => app.db.transaction(() => app.game.ledger.change(account.account_id, id, resource, amount, secret(), 'test_only'));
  const item = (rarity = 'epic') => {
    const equipmentId = secret();
    app.db.run(`INSERT INTO equipment (id,cultivator_id,catalogue_id,catalogue_version,slot,rarity)
      VALUES (?,?,'pixel:0','pixel-equipment-v1','weapon',?)`, equipmentId, id, rarity);
    return equipmentId;
  };
  return { app, account, id, send, request, fund, item, snapshot: () => send('growth.snapshot') };
}

test('强化与铭刻：余额不足全回滚、等级核对、幂等、分解消耗实例', async context => {
  const { app, id, send, request, fund, item, snapshot } = await setup(context);
  const equipmentId = item();
  fund('materials', 100);
  assert.equal((await request('growth.upgrade', {equipment_id: equipmentId, expected_level: 0})).body.code, 'INSUFFICIENT_FUNDS');
  assert.equal((await snapshot()).resources.materials, 100);
  assert.equal((await snapshot()).equipment[0].upgrade_level, 0);
  fund('spirit_stones', 1000);
  const payload = {equipment_id: equipmentId, expected_level: 0};
  const upgraded = await send('growth.upgrade', payload, 'upgrade-1');
  assert.deepEqual(await send('growth.upgrade', payload, 'upgrade-1'), upgraded);
  assert.equal(upgraded.resources.materials, 98);
  assert.equal(upgraded.resources.spirit_stones, 990);
  assert.equal(upgraded.equipment[0].upgrade_level, 1);
  assert.equal((await request('growth.upgrade', payload)).body.code, 'EQUIPMENT_CHANGED');
  const attuned = await send('growth.attune', {equipment_id: equipmentId, school: 1, expected_school: -1});
  assert.equal(attuned.equipment[0].school, 1);
  assert.equal(attuned.resources.materials, 93);
  assert.equal(attuned.resources.spirit_stones, 960);
  const equipped = await send('growth.equip', {equipment_id: equipmentId, slot: 'weapon'});
  assert.equal(equipped.equipment_bonuses.attack, 11);
  assert.equal((await request('growth.salvage', {equipment_id: equipmentId})).body.code, 'EQUIPMENT_EQUIPPED');
  await send('growth.unequip', {slot:'weapon',request_id:secret()});
  const posting = await send('growth.market_post', {equipment_id:equipmentId,price:100});
  assert.equal(posting.school, 1);
  assert.equal(posting.upgrade_level, 1);
  assert.equal((await request('growth.upgrade', {equipment_id: equipmentId, expected_level: 1})).body.code, 'EQUIPMENT_LISTED');
  assert.equal((await request('growth.salvage', {equipment_id: equipmentId})).body.code, 'EQUIPMENT_LISTED');
  await send('growth.market_cancel', {listing_id:posting.listing_id});
  const salvaged = await send('growth.salvage', {equipment_id:equipmentId},'salvage-1');
  assert.deepEqual(await send('growth.salvage', {equipment_id:equipmentId},'salvage-1'),salvaged);
  assert.equal(salvaged.resources.materials, 102);
  assert.deepEqual(salvaged.equipment, []);
  assert.equal((await request('growth.equip', {equipment_id:equipmentId,slot:'weapon'})).body.code,'INVALID_EQUIPMENT');
  assert.equal((await request('growth.market_post', {equipment_id:equipmentId,price:100})).body.code,'NOT_FOUND');
  assert.ok(app.db.get('SELECT id FROM equipment WHERE id = ? AND cultivator_id = ? AND salvaged_at IS NOT NULL', equipmentId, id));
});

test('套装：同流派两件和四件激活，旧装备只保留原始加成', () => {
  const base: GrowingEquipment = {id:'a',catalogue_id:'pixel:0',catalogue_version:'pixel-equipment-v1',rarity:'common',equipped:1,school:-1,upgrade_level:0};
  assert.deepEqual(equipmentBonuses([base]),{life:0,attack:3,defense:0,spirit:0,stamina:0});
  const items = [0,1,3,4].map((template,index)=>({...base,id:String(index),catalogue_id:'pixel:'+template,school:1}));
  assert.equal(equipmentBonuses(items.slice(0,2)).attack,7);
  assert.equal(equipmentBonuses(items).spirit,17);
  assert.equal(equipmentBonuses([{...base,upgrade_level:10}]).attack,14);
});

test('祈愿：流派定向、50 抽传说保障、角色隔离、余额失败不推进保障', async context => {
  const { app, id, send, request, fund } = await setup(context);
  app.db.run('UPDATE cultivators SET initial_score = 100, legendary_pity = 49 WHERE id = ?',id);
  await send('growth.set_wish',{school:2});
  assert.equal((await request('growth.draw',{count:1,request_id:'no-funds'})).body.code,'INSUFFICIENT_FUNDS');
  assert.equal(app.db.get<{legendary_pity:number}>('SELECT legendary_pity FROM cultivators WHERE id = ?',id)!.legendary_pity,49);
  fund('spirit_stones',140);
  const result = await send('growth.draw',{count:1,request_id:'guarantee'});
  assert.equal(result.legendary_guaranteed,true);
  assert.equal(result.items[0].rarity,'legendary');
  assert.equal(result.items[0].school,2);
  assert.equal(result.character.legendary_pity,0);
  assert.deepEqual(await send('growth.draw',{count:1,request_id:'guarantee'}),result);
  const next = await send('growth.draw',{count:1,request_id:'after-guarantee'});
  assert.equal(next.character.legendary_pity,1);
  assert.equal(next.character.draw_count,2);
});

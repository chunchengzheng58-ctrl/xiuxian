import assert from 'node:assert/strict';
import test, { type TestContext } from 'node:test';
import { secret } from '../src/core.js';
import { defaultProviders } from '../src/game/rules.js';
import { fixture } from './helpers.js';

async function marketFixture(context: TestContext) {
  const app = await fixture(context, { providers: defaultProviders });
  const player = async (name: string) => {
    const account = await app.account(name);
    const character = await app.command(account.token, 'growth.create_member', {
      role: 'self', name, profile: { title: name, avatar: 'male' }, request_id: secret(),
    });
    const id = character.cultivator_id as string;
    const payload = (fields: object) => ({ cultivator_id: id, ...fields });
    return {
      ...account, id,
      send: (command: string, fields: object = {}, key?: string) => app.command(account.token, command, payload(fields), key),
      request: (command: string, fields: object = {}, key = secret()) => app.request('/api/v2/commands', { version: 1, command, payload: payload(fields) }, account.token, 'POST', key),
      fund: (amount: number) => app.db.transaction(() => app.game.ledger.change(account.account_id, id, 'spirit_stones', amount, secret(), 'test_only')),
      snapshot: () => app.command(account.token, 'growth.snapshot', payload({})),
    };
  };
  const seedEquipment = (owner: string) => {
    const id = secret();
    app.db.run(`INSERT INTO equipment (id, cultivator_id, catalogue_id, catalogue_version, slot, rarity)
      VALUES (?, ?, 'pixel:0', 'pixel-equipment-v1', 'weapon', 'common')`, id, owner);
    return id;
  };
  return { app, player, seedEquipment };
}

test('万宝集：跨账号买卖转移同一实例，账本只成交一次，历史仅暴露装备和状态', async context => {
  const { app, player, seedEquipment } = await marketFixture(context);
  const seller = await player('seller');
  const buyer = await player('buyer');
  const observer = await player('observer');
  buyer.fund(300);
  const item = seedEquipment(seller.id);
  app.db.run('UPDATE equipment SET school = 1, upgrade_level = 2 WHERE id = ?', item);
  const sellerRevision = app.game.snapshot(seller.account_id).revision;
  const buyerRevision = app.game.snapshot(buyer.account_id).revision;
  const post = { equipment_id: item, price: 120 };
  const posted = await seller.send('growth.market_post', post, 'post-1');
  assert.deepEqual(await seller.send('growth.market_post', post, 'post-1'), posted);
  assert.equal((await seller.snapshot()).equipment[0].market_listing_id, posted.listing_id);
  assert.equal((await seller.request('growth.market_post', post)).body.code, 'EQUIPMENT_LISTED');
  assert.equal((await seller.request('growth.equip', { equipment_id: item, slot: 'weapon' })).body.code, 'EQUIPMENT_LISTED');
  const query = { scope: 'browse', slot: 'all', cursor: 0 };
  const listed = (await buyer.send('growth.market_list', query)).listings[0];
  assert.equal(listed.price, 120);
  assert.equal(listed.school, 1);
  assert.equal(listed.upgrade_level, 2);
  assert.equal(listed.selling, false);
  assert.deepEqual(Object.keys(listed).sort(), ['closed_at', 'created_at', 'listing_id', 'price', 'purchased', 'rarity_index', 'school', 'selling', 'slot', 'status', 'template', 'upgrade_level']);
  const order = { listing_id: posted.listing_id };
  assert.equal((await seller.request('growth.market_buy', order)).body.code, 'SELF_TRADE');
  assert.equal((await buyer.request('growth.market_cancel', order)).body.code, 'NOT_FOUND');
  const bought = await buyer.send('growth.market_buy', order, 'buy-1');
  assert.equal(bought.status, 'sold');
  assert.equal(bought.purchased, true);
  assert.deepEqual(await buyer.send('growth.market_buy', order, 'buy-1'), bought);
  assert.equal((await buyer.request('growth.market_buy', order)).body.code, 'LISTING_CLOSED');
  assert.equal((await seller.snapshot()).resources.spirit_stones, 120);
  assert.equal((await buyer.snapshot()).resources.spirit_stones, 180);
  assert.deepEqual((await seller.snapshot()).equipment, []);
  const owned = (await buyer.snapshot()).equipment[0];
  assert.equal(owned.equipment_id, item);
  assert.equal(owned.school, 1);
  assert.equal(owned.upgrade_level, 2);
  assert.equal(owned.market_listing_id, '');
  assert.ok(app.game.snapshot(seller.account_id).revision > sellerRevision);
  assert.ok(app.game.snapshot(buyer.account_id).revision > buyerRevision);
  assert.deepEqual(app.db.all<{ reason: string; delta: number }>("SELECT reason, delta FROM ledger WHERE reason LIKE 'market_%' ORDER BY delta").map(({ reason, delta }) => [reason, delta]), [
    ['market_buy', -120], ['market_sell', 120],
  ]);
  assert.deepEqual((await buyer.send('growth.market_list', query)).listings, []);
  assert.deepEqual((await buyer.send('growth.market_list', { ...query, scope: 'mine' })).listings, [bought]);
  assert.equal((await seller.send('growth.market_list', { ...query, scope: 'mine' })).listings[0].selling, true);
  assert.deepEqual((await observer.send('growth.market_list', { ...query, scope: 'mine' })).listings, []);
});

test('万宝集：余额不足回滚，两个买家并发时只有一方扣款', async context => {
  const { player, seedEquipment } = await marketFixture(context);
  const seller = await player('seller');
  const left = await player('left');
  const right = await player('right');
  const item = seedEquipment(seller.id);
  const posted = await seller.send('growth.market_post', { equipment_id: item, price: 100 }, 'post');
  const order = { listing_id: posted.listing_id };
  assert.equal((await left.request('growth.market_buy', order)).body.code, 'INSUFFICIENT_FUNDS');
  assert.equal((await seller.snapshot()).equipment[0].equipment_id, item);
  assert.equal((await seller.snapshot()).resources.spirit_stones, 0);
  assert.deepEqual((await left.snapshot()).equipment, []);
  left.fund(100);
  right.fund(100);
  const attempts = await Promise.all([left.request('growth.market_buy', order), right.request('growth.market_buy', order)]);
  assert.deepEqual(attempts.map(attempt => attempt.status).sort(), [200, 409]);
  const winner = attempts[0]?.status === 200 ? left : right;
  const loser = winner === left ? right : left;
  assert.equal((await winner.snapshot()).equipment[0].equipment_id, item);
  assert.equal((await winner.snapshot()).resources.spirit_stones, 0);
  assert.deepEqual((await loser.snapshot()).equipment, []);
  assert.equal((await loser.snapshot()).resources.spirit_stones, 100);
  assert.equal((await seller.snapshot()).resources.spirit_stones, 100);
});

test('万宝集：拒绝非法装备、角色与价格；撤单后可穿戴，游标在新挂单插入后不重复', async context => {
  const { app, player, seedEquipment } = await marketFixture(context);
  const seller = await player('seller');
  const buyer = await player('buyer');
  const elder = await app.command(seller.token, 'growth.create_member', {
    role: 'elder', name: '家人', request_id: secret(),
    profile: { title: '家人', avatar: 'male', relation: '父亲', age: 70, sex: '男', mode: 'family', consent: true },
  });
  const item = seedEquipment(seller.id);
  const offer = { equipment_id: item, price: 50 };
  assert.equal((await seller.request('growth.market_post', { ...offer, cultivator_id: elder.cultivator_id })).body.code, 'MARKET_SELF_REQUIRED');
  assert.equal((await buyer.request('growth.market_post', offer)).body.code, 'NOT_FOUND');
  assert.equal((await seller.request('growth.market_post', { ...offer, price: 0 })).body.code, 'INVALID_PRICE');
  await seller.send('growth.equip', { equipment_id: item, slot: 'weapon' }, 'wear');
  assert.equal((await seller.request('growth.market_post', offer)).body.code, 'EQUIPMENT_EQUIPPED');
  await seller.send('growth.unequip', { slot: 'weapon', request_id: secret() });
  const posted = await seller.send('growth.market_post', offer, 'first');
  await seller.send('growth.market_cancel', { listing_id: posted.listing_id }, 'cancel');
  const worn = await seller.send('growth.equip', { equipment_id: item, slot: 'weapon' }, 'wear-again');
  assert.equal(worn.equipment[0].equipped, 1);
  const makeOffer = () => seller.send('growth.market_post', { equipment_id: seedEquipment(seller.id), price: 100 }, secret());
  for (let index = 0; index < 13; index++) await makeOffer();
  const query = { scope: 'browse', slot: 'weapon', cursor: 0 };
  const first = await buyer.send('growth.market_list', query);
  assert.equal(first.listings.length, 12);
  assert.ok(first.next_cursor > 0);
  await makeOffer();
  const second = await buyer.send('growth.market_list', { ...query, cursor: first.next_cursor });
  assert.equal(second.listings.length, 1);
  assert.equal(second.next_cursor, 0);
  assert.equal(first.listings.some((listing: { listing_id: string }) => listing.listing_id === second.listings[0].listing_id), false);
  assert.deepEqual((await buyer.send('growth.market_list', { ...query, slot: 'robe' })).listings, []);
});

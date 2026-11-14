import assert from 'node:assert/strict';
import test, { type TestContext } from 'node:test';
import { secret } from '../src/core.js';
import { fixture } from './helpers.js';

async function socialFixture(context: TestContext) {
  const app = await fixture(context);
  const create = async (username: string, alias?: string) => {
    const account = await app.account(username);
    const character = await app.command(account.token, 'growth.create_member', {
      role: 'self', name: username, profile: { title: username, avatar: 'male' }, request_id: secret(),
    });
    const id = character.cultivator_id as string;
    const send = (action: string, payload: object = {}, key = secret()) => app.command(account.token, 'social.' + action, { cultivator_id: id, ...payload }, key);
    const tryCommand = (action: string, payload: object = {}) => app.request('/api/v2/commands', {
      version: 1, command: 'social.' + action, payload: { cultivator_id: id, ...payload },
    }, account.token, 'POST', secret());
    if (alias) await send('profile', { alias, rotate_code: false });
    return { id, account, send, tryCommand, home: () => send('home') };
  };
  const invite = async (from: Awaited<ReturnType<typeof create>>, to: Awaited<ReturnType<typeof create>>) => {
    await from.send('invite', { invite_code: (await to.home()).profile.invite_code });
    return (await to.home()).requests[0].relation_id as string;
  };
  return { app, create, invite };
}

test('同道录：独立名片、轮换邀请码、双方确认与请求归属', async context => {
  const { app, create, invite } = await socialFixture(context);
  const left = await create('left');
  const right = await create('right', '云栖');
  const outsider = await create('outsider', '旁观者');
  assert.deepEqual(await left.home(), { profile: null, friends: [], requests: [], blocked: [] });
  const old = (await right.home()).profile.invite_code;
  assert.equal((await left.tryCommand('invite', { invite_code: old })).body.code, 'SOCIAL_PROFILE_REQUIRED');
  await left.send('profile', { alias: '风过山', rotate_code: false });
  const ownCode = (await left.home()).profile.invite_code;
  assert.equal((await left.tryCommand('invite', { invite_code: ownCode })).body.code, 'SOCIAL_SELF_REQUEST');
  assert.equal((await left.tryCommand('profile', { alias: '坏\n昵称', rotate_code: false })).body.code, 'INVALID_ALIAS');
  await right.send('profile', { alias: '云栖', rotate_code: true }, 'rotate');
  const code = (await right.home()).profile.invite_code;
  assert.notEqual(code, old);
  await right.send('profile', { alias: '云栖', rotate_code: true }, 'rotate');
  assert.equal((await right.home()).profile.invite_code, code);
  assert.equal((await left.tryCommand('invite', { invite_code: old })).body.code, 'INVITE_UNAVAILABLE');
  const before = app.game.snapshot(right.account.account_id).revision;
  await left.send('invite', { invite_code: code.match(/.{4}/g)!.join('-').toLowerCase() });
  const pending = (await right.home()).requests[0];
  const relation = { relation_id: pending.relation_id };
  assert.deepEqual(pending, { relation_id: pending.relation_id, alias: '风过山', incoming: true });
  assert.deepEqual((await left.home()).requests, [{ ...relation, alias: '云栖', incoming: false }]);
  assert.equal((await left.tryCommand('respond', { ...relation, action: 'accept' })).body.code, 'SOCIAL_ACTION_UNAVAILABLE');
  assert.equal((await outsider.tryCommand('respond', { ...relation, action: 'accept' })).body.code, 'SOCIAL_RELATION_NOT_FOUND');
  assert.equal((await left.tryCommand('send', { ...relation, body: '招呼' })).body.code, 'SOCIAL_FRIEND_REQUIRED');
  assert.ok(app.game.snapshot(right.account.account_id).revision > before);
  assert.deepEqual(app.game.snapshot(right.account.account_id).social, { pending_requests: 1, unread_messages: 0 });
  assert.deepEqual(app.game.snapshot(outsider.account.account_id).social, { pending_requests: 0, unread_messages: 0 });
  await right.send('respond', { ...relation, action: 'decline' });
  assert.deepEqual((await left.home()).requests, []);
  const second = await invite(left, right);
  await left.send('respond', { relation_id: second, action: 'cancel' });
  assert.deepEqual((await right.home()).requests, []);
  const third = await invite(left, right);
  await right.send('respond', { relation_id: third, action: 'accept' });
  assert.deepEqual((await left.home()).friends, [{ relation_id: third, alias: '云栖', unread: 0 }]);
  assert.deepEqual((await right.home()).friends, [{ relation_id: third, alias: '风过山', unread: 0 }]);
  await right.send('profile', { alias: '松雪', rotate_code: false });
  assert.equal((await left.home()).friends[0].alias, '松雪');
  assert.equal((await right.home()).profile.invite_code, code);
  const elder = await app.command(left.account.token, 'growth.create_member', {
    role: 'elder', name: '家人', request_id: secret(),
    profile: { title: '家人', avatar: 'male', relation: '父亲', age: 70, sex: '男', mode: 'family', consent: true },
  });
  assert.equal((await left.tryCommand('home', { cultivator_id: elder.cultivator_id })).body.code, 'SOCIAL_SELF_REQUIRED');
  assert.equal((await outsider.tryCommand('home', { cultivator_id: right.id })).body.code, 'NOT_FOUND');
});

test('私信：只有好友可读写、未读隔离、重试去重、屏蔽后清除会话', async context => {
  const { app, create, invite } = await socialFixture(context);
  const left = await create('left', '风');
  const right = await create('right', '云');
  const outsider = await create('outsider', '雪');
  const relation = { relation_id: await invite(left, right) };
  await right.send('respond', { ...relation, action: 'accept' });
  const body = { ...relation, body: '  山门见。  ' };
  const first = await left.send('send', body, 'message-1');
  assert.deepEqual(await left.send('send', body, 'message-1'), first);
  const second = await right.send('send', { ...relation, body: '好。' });
  assert.deepEqual(await right.send('chat', { ...relation, before: 0 }), {
    messages: [
      { sequence: first.sequence, mine: false, body: '山门见。', sent_at: app.now() },
      { sequence: second.sequence, mine: true, body: '好。', sent_at: app.now() },
    ], next_before: 0,
  });
  assert.equal((await right.home()).friends[0].unread, 1);
  assert.deepEqual(app.game.snapshot(right.account.account_id).social, { pending_requests: 0, unread_messages: 1 });
  assert.equal((await left.home()).friends[0].unread, 1);
  assert.equal((await outsider.tryCommand('chat', { ...relation, before: 0 })).body.code, 'SOCIAL_RELATION_NOT_FOUND');
  await right.send('read', { ...relation, through: Number.MAX_SAFE_INTEGER });
  assert.equal((await right.home()).friends[0].unread, 1);
  await right.send('read', { ...relation, through: first.sequence });
  assert.equal((await right.home()).friends[0].unread, 0);
  assert.deepEqual(app.game.snapshot(right.account.account_id).social, { pending_requests: 0, unread_messages: 0 });
  assert.equal((await left.home()).friends[0].unread, 1);
  assert.equal((await left.tryCommand('send', { ...relation, body: '甲'.repeat(241) })).body.code, 'INVALID_MESSAGE');
  await right.send('respond', { ...relation, action: 'block' });
  assert.equal((await left.tryCommand('chat', { ...relation, before: 0 })).body.code, 'SOCIAL_RELATION_NOT_FOUND');
  assert.equal((await left.tryCommand('send', body)).body.code, 'SOCIAL_RELATION_NOT_FOUND');
  assert.equal(app.db.get<{ count: number }>('SELECT COUNT(*) AS count FROM social_messages')!.count, 0);
  const blocker = await right.home();
  assert.deepEqual(blocker.blocked, [{ peer_id: left.id, alias: '风' }]);
  assert.deepEqual((await left.home()).blocked, []);
  assert.equal((await left.tryCommand('invite', { invite_code: blocker.profile.invite_code })).body.code, 'INVITE_UNAVAILABLE');
  await right.send('unblock', { peer_id: left.id });
  const newRelation = { relation_id: await invite(left, right) };
  await right.send('respond', { ...newRelation, action: 'accept' });
  assert.deepEqual((await right.send('chat', { ...newRelation, before: 0 })).messages, []);
  await left.send('respond', { ...newRelation, action: 'remove' });
  assert.deepEqual((await right.home()).friends, []);
});

test('私信：频率限制、分页和保留最近 100 条', async context => {
  const { app, create, invite } = await socialFixture(context);
  const left = await create('left', '左');
  const right = await create('right', '右');
  const relation = { relation_id: await invite(left, right) };
  await right.send('respond', { ...relation, action: 'accept' });
  for (let index = 1; index <= 105; index++) {
    await left.send('send', { ...relation, body: '消息 ' + index });
    if (index % 12 === 0) {
      assert.equal((await left.tryCommand('send', { ...relation, body: '超出限制' })).body.code, 'SOCIAL_RATE_LIMITED');
      app.advance(60);
    }
  }
  const results: string[] = [];
  let before = 0;
  do {
    const page = await right.send('chat', { ...relation, before });
    assert.equal(page.messages.length, 25);
    results.unshift(...page.messages.map((message: { body: string }) => message.body));
    before = page.next_before;
  } while (before);
  assert.deepEqual(results, Array.from({ length: 100 }, (_, index) => '消息 ' + (index + 6)));
  assert.equal((await right.home()).friends[0].unread, 100);
});

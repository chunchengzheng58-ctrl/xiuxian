import assert from 'node:assert/strict';
import test, { type TestContext } from 'node:test';
import { mkdirSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { buildApp } from '../src/app.js';
import { repositoryRoot } from '../src/contracts.js';
import { secret } from '../src/core.js';
import type { Database } from '../src/database.js';
import { campaignConfig } from '../src/game/character-progression.js';
import { fixture } from './helpers.js';

async function player(context: TestContext, avatar: 'male' | 'female' = 'male', username = 'story_player') {
  const app = await fixture(context);
  const account = await app.account(username);
  const actor = await app.command(account.token, 'growth.create_member', { role: 'self', name: '守灯者', profile: { title: '行者', avatar }, request_id: secret() });
  const cid = actor.cultivator_id as string;
  const send = (command: string, fields: object = {}, key = secret()) => app.command(account.token, command, { cultivator_id: cid, ...fields }, key);
  return { app, account, cid, send };
}

// Persisted authoritative clears are fixtures for the story projection, not client commands.
function persistedClear(app: { db: Database; now: () => number }, cid: string, stageId: string) {
  const runId = secret();
  app.db.run(`INSERT INTO expedition_runs (id,cultivator_id,stage_id,avatar,stats,lifecycle_version,started_at,expires_at,finished_at,result)
    VALUES (?,?,?,'male','{}',0,?,?,?,'{"won":true}')`, runId, cid, stageId, app.now(), app.now(), app.now());
  app.db.run('INSERT INTO expedition_clears VALUES (?,?,?,?,?)', cid, stageId, runId, 250, app.now());
}

test('正式主线显示二十秘境、五域与可选教学；健康练习胜利无法解锁或领奖', async context => {
  const { app, account, cid, send } = await player(context);
  const lobby = await send('combat.expedition_lobby');
  assert.equal(lobby.stages.length, 20);
  assert.deepEqual(lobby.stages.filter((row: { unlocked: boolean }) => row.unlocked).map((row: { stage_id: string }) => row.stage_id), ['b00', 'b01']);
  const initial = await send('story.snapshot');
  assert.equal(initial.current_chapter_id, 'wood');
  assert.equal(initial.next_node_id, 'wood.intro');
  assert.match(initial.current_objective, /悬木栈道.*朽梁/);
  assert.equal(initial.chapters.length, 9);
  assert.equal(initial.chapters.find((row: { id: string }) => row.id === 'origin').optional, true);
  await send('story.advance', { node_id: 'wood.intro' });
  for (const stageId of ['b01', 'b02', 'b03']) {
    const session = await send('combat.start', { encounter_id: stageId });
    app.advance(5);
    await app.command(account.token, 'combat.finish', { session_id: session.session_id, won: true, duration_seconds: 5 });
  }
  assert.equal(app.db.get<{ count: number }>('SELECT COUNT(*) AS count FROM boss_clears WHERE cultivator_id = ?', cid)!.count, 3);
  assert.equal((await send('combat.expedition_lobby')).stages.find((row: { stage_id: string }) => row.stage_id === 'b02').unlocked, false);
  await assert.rejects(send('story.advance', { node_id: 'wood.closure' }), /正式秘境/);
  assert.equal((await send('story.snapshot')).adventure.xp, 0);
  assert.equal((await send('story.snapshot')).adventure.cleared_count, 0);
  assert.equal((await send('story.snapshot')).adventure.seal_count, 0);
  assert.equal(app.db.get<{ count: number }>('SELECT COUNT(*) AS count FROM baselines WHERE cultivator_id = ?', cid)!.count, 0);
});

test('章节奖励、剧情存档与回看可重试；故障时钱包、历练、完成标记一起回滚', async context => {
  const { app, account, cid, send } = await player(context);
  await send('story.advance', { node_id: 'wood.intro' });
  for (const stageId of ['b01', 'b02', 'b03']) persistedClear(app, cid, stageId);
  const ready = await send('story.snapshot');
  assert.equal(ready.chapters.find((row: { id: string }) => row.id === 'wood').status, 'claimable');
  assert.equal(ready.next_node_id, 'wood.closure');
  assert.equal(ready.adventure.cleared_count, 3);
  assert.equal(ready.adventure.seal_count, 1);
  const before = app.game.characterSnapshot(account.account_id, cid);
  app.db.connection.exec(`CREATE TRIGGER reject_story_marker BEFORE INSERT ON story_nodes WHEN NEW.node_id='wood.closure'
    BEGIN SELECT RAISE(ABORT,'fixture story storage failure'); END`);
  await assert.rejects(send('story.advance', { node_id: 'wood.closure' }, 'chapter-retry'), /INTERNAL_ERROR/);
  assert.deepEqual(app.game.characterSnapshot(account.account_id, cid).resources, before.resources);
  assert.equal(app.game.characterSnapshot(account.account_id, cid).adventure!.xp, 0);
  assert.equal(app.db.get('SELECT 1 FROM story_nodes WHERE cultivator_id=? AND node_id=?', cid, 'wood.closure'), undefined);
  app.db.connection.exec('DROP TRIGGER reject_story_marker');
  const claimed = await send('story.advance', { node_id: 'wood.closure' }, 'chapter-retry');
  assert.equal(claimed.current_chapter_id, 'fire');
  assert.equal(claimed.next_node_id, 'fire.intro');
  const chapter = campaignConfig.chapters.find(row => row.id === 'wood')!;
  assert.equal(claimed.adventure.xp, chapter.reward.adventure_xp);
  assert.deepEqual(await send('story.advance', { node_id: 'wood.closure' }, 'chapter-retry'), claimed);
  await send('story.advance', { node_id: 'wood.closure' }, 'another-claim-key');
  const after = app.game.characterSnapshot(account.account_id, cid);
  assert.equal(after.resources.spirit_stones - before.resources.spirit_stones, chapter.reward.spirit_stones);
  assert.equal(after.resources.materials - before.resources.materials, chapter.reward.materials);
  assert.equal(app.db.get<{ count: number }>("SELECT COUNT(*) AS count FROM adventure_awards WHERE cultivator_id=? AND kind='chapter'", cid)!.count, 1);
  const replay = (await send('story.snapshot')).chapters.find((row: { id: string }) => row.id === 'wood');
  assert.equal(replay.nodes[0].completed, true);
  assert.match(replay.nodes[1].dialogue[0].text, /新芽和旧树/);
});

test('五枚归衡印、章间顺序、旁篇与终章反馈由正式存档决定', async context => {
  const { app, cid, send } = await player(context);
  await assert.rejects(send('story.advance', { node_id: 'finale.intro' }), /先领取/);
  for (const stage of campaignConfig.stages) persistedClear(app, cid, stage.stage_id);
  const pending = await send('story.snapshot');
  assert.equal(pending.seals.length, 5);
  assert.equal(pending.ending.completed, false);
  for (const chapter of campaignConfig.chapters) {
    for (const node of chapter.nodes) await send('story.advance', { node_id: node.id });
  }
  const complete = await send('story.snapshot');
  assert.equal(complete.ending.completed, true);
  assert.equal(complete.ending.all_twenty_cleared, true);
  assert.equal(complete.adventure.cleared_count, 20);
  assert.equal(complete.adventure.seal_count, 5);
  assert.match(complete.ending.text, /锅里还有/);
  assert.equal(complete.current_chapter_id, null);
  assert.ok(complete.chapters.every((row: { status: string }) => row.status === 'completed'));
  assert.equal(complete.pending_scene.scene_id, 'stage.b19.resolution');
  await send('story.advance', { node_id: 'stage.b19.resolution' });
  const homeReady = await send('story.snapshot');
  assert.equal(homeReady.home.available, true);
  assert.equal(homeReady.home.completed, false);
  assert.equal(homeReady.pending_scene.scene_id, 'ending.home');
  assert.equal(homeReady.home.scene.kind, 'ending');
  assert.match(homeReady.home.scene.dialogue.at(-2).text, /锅里还有/);
  const xp = homeReady.adventure.xp;
  const settledHome = await send('story.advance', { node_id: 'ending.home' });
  assert.equal(settledHome.home.completed, true);
  assert.equal(settledHome.pending_scene, null);
  assert.equal(settledHome.adventure.xp, xp);
  await send('story.advance', { node_id: 'ending.home' });
  assert.equal((await send('story.snapshot')).home.completed, true);
  await send('story.advance', { node_id: 'finale.closure' });
  assert.equal((await send('story.snapshot')).adventure.xp, xp);
});

test('剧情节点拒绝越权角色、非本人角色与未登记节点，回看不改账号版本', async context => {
  const { app, account, cid, send } = await player(context);
  const other = await app.account('other_story');
  const unauthorized = await app.request('/api/v2/commands', { version: 1, command: 'story.snapshot', payload: { cultivator_id: cid } }, other.token);
  assert.equal(unauthorized.status, 404);
  await assert.rejects(send('story.advance', { node_id: 'made-up.closure' }), /剧情节点不存在/);
  const revision = app.game.snapshot(account.account_id).revision;
  await send('story.snapshot');
  await send('story.snapshot');
  assert.equal(app.game.snapshot(account.account_id).revision, revision);
  const legacy = await app.character(account.token);
  const denied = await app.request('/api/v2/commands', { version: 1, command: 'story.snapshot', payload: { cultivator_id: legacy.cultivator_id } }, account.token);
  assert.equal(denied.body.code, 'STORY_SELF_REQUIRED');
});

test('关闭并重新打开独立存档后，剧情、历练与幂等领奖回执保持一致', async () => {
  const base = join(repositoryRoot, 'work/story-persistence-tests');
  mkdirSync(base, { recursive: true });
  const options = { databasePath: join(mkdtempSync(join(base, 'restart-')), 'fixture.sqlite'), worker: false, now: () => 1793400000 };
  let server = await buildApp(options);
  try {
    const account = await server.auth.register({ username: 'persistent_story', password: 'persistent-story-pass-123' });
    const member = server.game.execute(account.account_id, 'growth.create_member', { role: 'self', name: '行者', profile: { title: '行者', avatar: 'male' }, request_id: secret() }) as { cultivator_id: string };
    const payload = { cultivator_id: member.cultivator_id, node_id: 'wood.closure' };
    server.game.execute(account.account_id, 'story.advance', { ...payload, node_id: 'wood.intro' }, 'persistent-intro');
    for (const stageId of ['b01', 'b02', 'b03']) persistedClear({ db: server.db, now: options.now }, member.cultivator_id, stageId);
    const claimed = server.game.execute(account.account_id, 'story.advance', payload, 'persistent-closure');
    const wallet = server.game.own(account.account_id, member.cultivator_id);
    await server.app.close();
    server = await buildApp(options);
    const snapshot = server.game.story.snapshot(server.game.own(account.account_id, member.cultivator_id));
    assert.equal(snapshot.current_chapter_id, 'fire');
    assert.equal(snapshot.adventure.xp, 230);
    assert.equal(snapshot.chapters.find(row => row.id === 'wood')!.status, 'completed');
    assert.deepEqual(server.game.execute(account.account_id, 'story.advance', payload, 'persistent-closure'), JSON.parse(JSON.stringify(claimed)));
    server.game.execute(account.account_id, 'story.advance', payload, 'new-request-same-node');
    const reopenedWallet = server.game.own(account.account_id, member.cultivator_id);
    assert.equal(reopenedWallet.spirit_stones, wallet.spirit_stones);
    assert.equal(reopenedWallet.materials, wallet.materials);
    assert.equal(server.db.get<{ count: number }>("SELECT COUNT(*) AS count FROM ledger WHERE reason='story_chapter'")!.count, 2);
    assert.deepEqual(server.db.all('PRAGMA foreign_key_check'), []);
  } finally { await server.app.close(); }
});

test('战前、战后与旧档补看共用幂等场景标记，跳过场景不会发奖励', async context => {
  const { app, account, cid, send } = await player(context);
  const initial = await send('story.snapshot');
  assert.equal(initial.scenes.length, 41);
  const prelude = initial.scenes.find((row: { scene_id: string }) => row.scene_id === 'stage.b01.prelude');
  assert.equal(prelude.available, true);
  assert.equal(initial.scenes.find((row: { scene_id: string }) => row.scene_id === 'stage.b01.resolution').status, 'locked');
  await assert.rejects(send('story.advance', { node_id: 'stage.b01.resolution' }), /尚未解锁/);
  const before = app.game.characterSnapshot(account.account_id, cid);
  const played = await send('story.advance', { node_id: 'stage.b01.prelude' }, 'stable-scene');
  assert.equal(played.scenes.find((row: { scene_id: string }) => row.scene_id === 'stage.b01.prelude').completed, true);
  assert.deepEqual(await send('story.advance', { node_id: 'stage.b01.prelude' }, 'stable-scene'), played);
  await send('story.advance', { node_id: 'stage.b01.prelude' }, 'another-scene-key');
  assert.equal(app.db.get<{ count: number }>('SELECT COUNT(*) AS count FROM story_nodes WHERE cultivator_id = ? AND node_id = ?', cid, 'stage.b01.prelude')!.count, 1);
  assert.deepEqual(app.game.characterSnapshot(account.account_id, cid).resources, before.resources);

  persistedClear(app, cid, 'b01');
  const won = await send('story.snapshot');
  assert.equal(won.pending_scene.scene_id, 'stage.b01.resolution');
  const resolved = await send('story.advance', { node_id: 'stage.b01.resolution' });
  assert.equal(resolved.scenes.find((row: { scene_id: string }) => row.scene_id === 'stage.b01.resolution').completed, true);
  assert.equal(resolved.pending_scene, null);

  // A legacy clear can backfill its prelude without replaying combat or changing rewards.
  persistedClear(app, cid, 'b02');
  const legacy = await send('story.snapshot');
  assert.equal(legacy.scenes.find((row: { scene_id: string }) => row.scene_id === 'stage.b02.prelude').replayable, true);
  await send('story.advance', { node_id: 'stage.b02.prelude' });
  assert.equal(app.db.get<{ count: number }>("SELECT COUNT(*) AS count FROM story_nodes WHERE cultivator_id = ? AND node_id LIKE 'stage.%'", cid)!.count, 3);
  assert.deepEqual(app.game.characterSnapshot(account.account_id, cid).resources, before.resources);
});

test('男女主角与男女阿宁四种组合共享完整剧情、奖励和结局，外观选择独立保存', async context => {
  let shared: unknown;
  for (const protagonist of ['male', 'female'] as const) {
    for (const companion of ['male', 'female'] as const) {
      const { send } = await player(context, protagonist, `parity_${protagonist}_${companion}`);
      await send('story.variant', { companion_variant: companion });
      const snapshot = await send('story.snapshot');
      assert.deepEqual(snapshot.variants, { protagonist, companion, parity: 'shared_story_rewards_flags' });
      const comparable = {
        chapters: snapshot.chapters.map((chapter: any) => ({ id: chapter.id, reward: chapter.reward, dialogue: chapter.nodes.map((node: any) => node.dialogue) })),
        scenes: snapshot.scenes.map((scene: any) => ({ id: scene.scene_id, dialogue: scene.dialogue })),
        home: snapshot.home.scene.dialogue,
      };
      if (shared === undefined) shared = comparable;
      else assert.deepEqual(comparable, shared);
    }
  }
});

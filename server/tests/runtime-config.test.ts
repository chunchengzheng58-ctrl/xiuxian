import assert from 'node:assert/strict';
import test, { type TestContext } from 'node:test';
import { createServer } from 'node:net';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import WebSocket from 'ws';
import { runtimeConfig } from '../src/runtime-config.js';
import { repositoryRoot } from '../src/contracts.js';

test('运行配置按实际端口生成规范同源，支持本机IPv6与明确HOST，wildcard绑定不变成来源', () => {
  assert.deepEqual(runtimeConfig({ PORT: '18081' }), { host: '127.0.0.1', port: 18081,
    origins: ['http://127.0.0.1:18081', 'http://localhost:18081'] });
  assert.deepEqual(runtimeConfig({ PORT: '80' }).origins, ['http://127.0.0.1', 'http://localhost']);
  for (const host of ['localhost', '::1', '[::1]']) {
    assert.deepEqual(runtimeConfig({ PORT: '8081', HOST: host }).origins,
      ['http://127.0.0.1:8081', 'http://localhost:8081', 'http://[::1]:8081']);
  }
  assert(runtimeConfig({ HOST: '192.168.1.20', PORT: '18081' }).origins.includes('http://192.168.1.20:18081'));
  assert(runtimeConfig({ HOST: 'Game.Example', PORT: '18081' }).origins.includes('http://game.example:18081'));
  for (const host of ['0.0.0.0', '::']) {
    const config = runtimeConfig({ HOST: host, PORT: '18081' });
    assert.equal(config.host, host);
    assert(!config.origins.some(value => value.includes('*') || value.includes('0.0.0.0') || value.includes('[::]')));
  }
});

test('显式来源列表只规范化与去重，不扩大权限；空列表仍保持为空', () => {
  const config = runtimeConfig({ PORT: '8081', CORS_ORIGINS: ' https://GAME.Example:443/ ,http://localhost:80,https://game.example ' });
  assert.deepEqual(config.origins, ['https://game.example', 'http://localhost']);
  assert(!config.origins.includes('http://127.0.0.1:8081'));
  assert.deepEqual(runtimeConfig({ CORS_ORIGINS: '' }).origins, []);
  for (const value of ['*', 'null', 'https://*.example.com', 'ws://localhost', 'https://user:secret@example.com', 'https://game.example/path', 'https://game.example?x=1', 'https://game.example/#']) {
    assert.throws(() => runtimeConfig({ CORS_ORIGINS: value }), /CORS_ORIGINS/);
  }
});

test('无效监听配置先拒绝，避免打开数据库后才发现PORT或HOST错误', () => {
  for (const port of ['', '0', '-1', '65536', '8e3', '0x1f90', '8080.1', 'NaN']) assert.throws(() => runtimeConfig({ PORT: port }), /PORT/);
  for (const host of ['', '*', 'http://localhost', 'localhost:8080', 'foo/bar', 'bad host', '[localhost]', '999.999.999.999']) assert.throws(() => runtimeConfig({ HOST: host }), /HOST/);
});

async function port() {
  const server = createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address();
  assert(address && typeof address === 'object');
  const value = address.port;
  await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  assert.notEqual(value, 8080);
  return value;
}

async function cli(context: TestContext, extra: NodeJS.ProcessEnv = {}) {
  const work = join(repositoryRoot, 'work/runtime-config-tests');
  mkdirSync(work, { recursive: true });
  const directory = mkdtempSync(join(work, 'main-'));
  const environmentFile = join(directory, 'isolated.env');
  writeFileSync(environmentFile, '# Isolated runtime test. Never load the user .env.\n');
  const web = join(directory, 'web');
  mkdirSync(web);
  writeFileSync(join(web, 'index.html'), '<!doctype html><title>runtime origin fixture</title>');
  const selectedPort = await port();
  const databasePath = join(directory, 'game.sqlite');
  const environment: NodeJS.ProcessEnv = { ...process.env, HOST: '127.0.0.1', PORT: String(selectedPort), DATABASE_PATH: databasePath,
    WEB_ROOT: web, XIUXIAN_ENV_FILE: environmentFile };
  delete environment.CORS_ORIGINS;
  delete environment.HEALTH_SERVICE_TOKEN;
  Object.assign(environment, extra);
  const child = spawn(process.execPath, ['--import', pathToFileURL(join(repositoryRoot, 'server/node_modules/tsx/dist/loader.mjs')).href,
    join(repositoryRoot, 'server/src/main.ts')], { cwd: join(repositoryRoot, 'server'), env: environment, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  let log = '';
  child.stdout.on('data', data => { log = (log + String(data)).slice(-12000); });
  child.stderr.on('data', data => { log = (log + String(data)).slice(-12000); });
  const exited = new Promise<number | null>((resolve, reject) => { child.once('exit', resolve); child.once('error', reject); });
  context.after(async () => {
    if (child.exitCode === null && child.signalCode === null) child.kill();
    await exited;
  });
  return { child, exited, databasePath, base: `http://${environment.HOST === '::1' ? '[::1]' : '127.0.0.1'}:${selectedPort}`, selectedPort, log: () => log };
}

async function healthy(server: Awaited<ReturnType<typeof cli>>) {
  const end = Date.now() + 10000;
  while (Date.now() < end) {
    assert.equal(server.child.exitCode, null, server.log());
    try { if ((await fetch(server.base + '/healthz')).ok) return; } catch { /* Still booting. */ }
    await new Promise(resolve => setTimeout(resolve, 40));
  }
  assert.fail('Main CLI did not start: ' + server.log());
}

async function socket(base: string, ticket: string, origin: string, expected: 'snapshot' | 403) {
  await new Promise<void>((resolve, reject) => {
    const peer = new WebSocket(base.replace('http:', 'ws:') + '/api/v2/realtime?ticket=' + ticket, { origin });
    const timer = setTimeout(() => { peer.terminate(); reject(new Error('WebSocket origin check timed out')); }, 4000);
    const finish = (error?: unknown) => { clearTimeout(timer); peer.terminate(); error ? reject(error) : resolve(); };
    peer.once('unexpected-response', (_request, response) => {
      response.resume();
      try { assert.equal(response.statusCode, expected); finish(); } catch (error) { finish(error); }
    });
    peer.once('message', data => { try { assert.equal(JSON.parse(String(data)).type, expected); finish(); } catch (error) { finish(error); } });
    peer.on('error', () => { /* Rejected upgrades also emit an error after unexpected-response. */ });
  });
}

async function account(base: string) {
  const credentials = { username: 'runtime_user', password: 'runtime-fixture-password' };
  assert.equal((await fetch(base + '/api/v2/auth/register', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(credentials) })).status, 200);
  const login = await fetch(base + '/api/v2/auth/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(credentials) });
  assert.equal(login.status, 200);
  return (await login.json() as { data: { token: string } }).data.token;
}
async function ticket(base: string, token: string) {
  const result = await fetch(base + '/api/v2/realtime/ticket', { method: 'POST', headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' }, body: '{}' });
  assert.equal(result.status, 200);
  return (await result.json() as { data: { ticket: string } }).data.ticket;
}

test('真实main CLI：非8080同源HTTP与WebSocket可用，旧端口和外部来源仍拒绝', async context => {
  const server = await cli(context);
  await healthy(server);
  const page = await fetch(server.base + '/', { headers: { origin: server.base } });
  assert.equal(page.status, 200);
  assert.equal(page.headers.get('access-control-allow-origin'), server.base);
  const denied = await fetch(server.base + '/healthz', { headers: { origin: 'http://127.0.0.1:8080' } });
  assert.equal(denied.headers.get('access-control-allow-origin'), null);
  const token = await account(server.base);
  await socket(server.base, await ticket(server.base, token), server.base, 'snapshot');
  await socket(server.base, await ticket(server.base, token), `http://localhost:${server.selectedPort}`, 'snapshot');
  await socket(server.base, await ticket(server.base, token), 'http://127.0.0.1:8080', 403);
  await socket(server.base, await ticket(server.base, token), 'https://untrusted.example', 403);
});

test('真实main CLI：显式代理来源保持限制，不自动放行本机实际端口', async context => {
  const server = await cli(context, { CORS_ORIGINS: 'https://GAME.Example:443/' });
  await healthy(server);
  const allowed = await fetch(server.base + '/healthz', { headers: { origin: 'https://game.example' } });
  assert.equal(allowed.headers.get('access-control-allow-origin'), 'https://game.example');
  const denied = await fetch(server.base + '/healthz', { headers: { origin: server.base } });
  assert.equal(denied.headers.get('access-control-allow-origin'), null);
  const token = await account(server.base);
  await socket(server.base, await ticket(server.base, token), 'https://game.example', 'snapshot');
  await socket(server.base, await ticket(server.base, token), server.base, 403);
});

test('真实main CLI：IPv6本机绑定允许浏览器规范的方括号同源WebSocket', async context => {
  const server = await cli(context, { HOST: '::1' });
  await healthy(server);
  const page = await fetch(server.base + '/', { headers: { origin: server.base } });
  assert.equal(page.status, 200);
  assert.equal(page.headers.get('access-control-allow-origin'), server.base);
  const token = await account(server.base);
  await socket(server.base, await ticket(server.base, token), server.base, 'snapshot');
});

test('真实main CLI：监听参数错误时不创建数据库，隔离配置文件不影响用户配置', async context => {
  for (const extra of [{ PORT: '70000' }, { HOST: 'http://localhost' }]) {
    const server = await cli(context, extra);
    assert.equal(await server.exited, 1);
    assert.match(server.log(), extra.PORT ? /PORT/ : /HOST/);
    assert.equal(existsSync(server.databasePath), false);
  }
});

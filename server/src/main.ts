import { loadEnvFile } from 'node:process';
import { existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { buildApp, healthScopes } from './app.js';
import { repositoryRoot } from './contracts.js';
import { runtimeConfig } from './runtime-config.js';

const serverRoot = join(repositoryRoot, 'server');
const environmentFile = resolve(serverRoot, process.env.XIUXIAN_ENV_FILE ?? '.env');
if (process.env.XIUXIAN_ENV_FILE !== undefined && !existsSync(environmentFile)) throw new Error('XIUXIAN_ENV_FILE 指定的配置文件不存在');
if (existsSync(environmentFile)) loadEnvFile(environmentFile);
const runtime = runtimeConfig(process.env);
const token = process.env.HEALTH_SERVICE_TOKEN;
const server = await buildApp({
  databasePath: resolve(serverRoot, process.env.DATABASE_PATH ?? 'var/game.sqlite'),
  services: token ? [{ id: 'health', token, scopes: [...healthScopes] }] : [],
  web: { root: resolve(repositoryRoot, process.env.WEB_ROOT ?? 'build/web'), wechatUrl: process.env.WECHAT_SERVICE_URL ?? 'http://127.0.0.1:8000', healthEntryUrl: process.env.HEALTH_ENTRY_URL ?? 'http://127.0.0.1:8001' },
  origins: runtime.origins,
});
await server.app.listen({ host: runtime.host, port: runtime.port });
console.log(`本地服务已启动：${server.app.listeningOrigin}；OpenAPI：/openapi.json`);
for (const signal of ['SIGINT', 'SIGTERM'] as const) process.once(signal, () => { void server.app.close(); });

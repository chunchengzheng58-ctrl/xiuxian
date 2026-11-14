import { isIP } from 'node:net';

export type RuntimeConfig = { host: string; port: number; origins: string[] };
type Environment = Partial<Pick<NodeJS.ProcessEnv, 'HOST' | 'PORT' | 'CORS_ORIGINS'>>;

function origin(value: string): string {
  try {
    const url = new URL(value);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.hostname.includes('*')
      || url.pathname !== '/' || url.search || url.hash || /[\s?#]/.test(value)) throw new Error();
    return url.origin;
  } catch { throw new Error('CORS_ORIGINS 必须是无用户名、路径、查询或通配符的 HTTP(S) 来源'); }
}

/** Validate listen settings before opening the database and derive exact browser origins. */
export function runtimeConfig(environment: Environment): RuntimeConfig {
  const portText = environment.PORT?.trim() ?? '8080';
  const port = Number(portText);
  if (!/^\d+$/.test(portText) || !Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT 必须为 1–65535 的整数端口');
  let host = environment.HOST?.trim() ?? '127.0.0.1';
  if (host.startsWith('[') && host.endsWith(']') && isIP(host.slice(1, -1)) === 6) host = host.slice(1, -1);
  const address = isIP(host);
  const hostname = host.length <= 253 && /[a-z]/i.test(host) && host.split('.').every(label =>
    /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label));
  if (!host || host.includes('%') || (!address && !hostname)) throw new Error('HOST 必须为 IP 地址或主机名，不包含协议、端口或路径');
  host = host.toLowerCase();
  // An explicitly configured list (including an empty one) is never broadened.
  if (environment.CORS_ORIGINS !== undefined) {
    return { host, port, origins: [...new Set(environment.CORS_ORIGINS.split(',').map(value => value.trim()).filter(Boolean).map(origin))] };
  }
  const origins = [origin(`http://127.0.0.1:${port}`), origin(`http://localhost:${port}`)];
  if (host === 'localhost' || address === 6) origins.push(origin(`http://[::1]:${port}`));
  if (!['0.0.0.0', '::'].includes(host)) origins.push(origin(`http://${address === 6 ? `[${host}]` : host}:${port}`));
  return { host, port, origins: [...new Set(origins)] };
}

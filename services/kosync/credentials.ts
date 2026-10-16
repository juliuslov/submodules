import { createHash } from 'node:crypto';
import type { KoSyncConfig } from './types';

/** Credentials and endpoint policy for one KoSync client.
 *
 * Everything here is derived from the caller's configuration and the runtime
 * environment; nothing is persisted, logged or echoed back. The addon (hidden)
 * classes keep the resolved values out of `JSON.stringify(client)`. */

export const DEFAULT_SERVER = 'https://sync.koreader.rocks';

export interface Connection {
  username: string;
  /** 32-character MD5 key, never the plain password. */
  userkey: string;
  baseUrl: URL;
  timeoutMs: number;
}

const LOOPBACK = ['localhost', '127.0.0.1', '[::1]'];

function keyFrom(config: KoSyncConfig): string {
  if ((config.password !== undefined) === (config.userkey !== undefined)) {
    throw new Error('set exactly one KoSync password or userkey');
  }
  if (config.userkey !== undefined) {
    if (typeof config.userkey !== 'string' || !/^[0-9a-f]{32}$/i.test(config.userkey)) {
      throw new Error('KoSync userkey must be a 32-character MD5 key');
    }
    return config.userkey.toLowerCase();
  }
  if (typeof config.password !== 'string' || !config.password || Buffer.byteLength(config.password) > 4096) {
    throw new Error('invalid KoSync password');
  }
  // KOReader registers/login with md5(password) and sends that key directly.
  return createHash('md5').update(config.password, 'utf8').digest('hex');
}

function endpointOf(config: KoSyncConfig): URL {
  let url: URL;
  try {
    url = new URL(config.baseUrl ?? DEFAULT_SERVER);
  } catch {
    throw new Error('invalid KoSync server URL');
  }
  if (url.username || url.password || url.hash || url.search) {
    throw new Error('KoSync server URL cannot contain credentials, query or fragment');
  }
  const loopback = LOOPBACK.includes(url.hostname);
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback && config.allowInsecureLocal === true)) {
    throw new Error('KoSync requires HTTPS (HTTP allowed only for explicitly enabled loopback testing)');
  }
  return url;
}

export function resolveConnection(config: KoSyncConfig): Connection {
  if (!config || typeof config !== 'object') throw new Error('KoSync configuration required');
  if (typeof config.username !== 'string' || !/^[\x21-\x7e]{1,128}$/.test(config.username) || config.username.includes(':')) {
    throw new Error('invalid KoSync username');
  }
  const timeoutMs = config.timeoutMs ?? 10000;
  if (!Number.isInteger(timeoutMs) || timeoutMs < 50 || timeoutMs > 60000) {
    throw new Error('KoSync timeout must be 50..60000 ms');
  }
  return { username: config.username, userkey: keyFrom(config), baseUrl: endpointOf(config), timeoutMs };
}

export { DEFAULT_SERVER as defaultServer };

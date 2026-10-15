import { createHash } from 'node:crypto';
import { documentId, percentage, record, stringField, timestamp } from './validation';
import type { KoSyncConfig, ProgressState, ProgressUpdate } from './types';
const MEDIA_TYPE = 'application/vnd.koreader.v1+json';
export const DEFAULT_SERVER = 'https://sync.koreader.rocks';
const MAX_RESPONSE = 128 * 1024;
export class KoSyncClient {
  #username: string; #userkey: string; #url: URL; #timeout: number;
  constructor(config: KoSyncConfig) {
    if (!config || typeof config !== 'object') throw new Error('KoSync configuration required');
    if (typeof config.username !== 'string' || !/^[\x21-\x7e]{1,128}$/.test(config.username) || config.username.includes(':')) throw new Error('invalid KoSync username');
    this.#username = config.username;
    if ((config.password !== undefined) === (config.userkey !== undefined)) throw new Error('set exactly one KoSync password or userkey');
    if (config.userkey !== undefined) {
      if (typeof config.userkey !== 'string' || !/^[0-9a-f]{32}$/i.test(config.userkey)) throw new Error('KoSync userkey must be a 32-character MD5 key');
      this.#userkey = config.userkey.toLowerCase();
    } else {
      if (typeof config.password !== 'string' || !config.password || Buffer.byteLength(config.password) > 4096) throw new Error('invalid KoSync password');
      this.#userkey = createHash('md5').update(config.password, 'utf8').digest('hex');
    }
    let url: URL;
    try { url = new URL(config.baseUrl ?? DEFAULT_SERVER); }
    catch { throw new Error('invalid KoSync server URL'); }
    if (url.username || url.password || url.hash || url.search) throw new Error('KoSync server URL cannot contain credentials, query or fragment');
    const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
    if (url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback && config.allowInsecureLocal === true)) throw new Error('KoSync requires HTTPS (HTTP allowed only for explicitly enabled loopback testing)');
    this.#url = url;
    this.#timeout = config.timeoutMs ?? 10000;
    if (!Number.isInteger(this.#timeout) || this.#timeout < 50 || this.#timeout > 60000) throw new Error('KoSync timeout must be 50..60000 ms');
  }
  async #request(method: string, endpoint: string, statuses: number[], payload?: object): Promise<{ status: number; body: unknown }> {
    const url = new URL(this.#url);
    url.pathname = this.#url.pathname.replace(/\/+$/, '') + endpoint;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.#timeout);
    timer.unref();
    try {
      let response: Response;
      try {
        response = await fetch(url, {
          method, redirect: 'manual', signal: controller.signal,
          headers: { Accept: MEDIA_TYPE, 'Content-Type': 'application/json',
            ...(endpoint === '/users/create' ? {} : { 'X-Auth-User': this.#username, 'X-Auth-Key': this.#userkey }) },
          body: payload === undefined ? undefined : JSON.stringify(payload),
        });
      } catch { throw new Error('KoSync connection failed or timed out'); }
      if (!statuses.includes(response.status)) {
        await response.body?.cancel();
        // Never include the server body, URL or request headers: they may echo credentials.
        throw new Error(`KoSync HTTP ${response.status}${response.status === 401 ? ' (unauthorized)' : ''}`);
      }
      if (Number(response.headers.get('content-length') || 0) > MAX_RESPONSE) {
        await response.body?.cancel(); throw new Error('KoSync response exceeds 128 KiB');
      }
      const chunks: Uint8Array[] = [];
      let length = 0;
      const reader = response.body?.getReader();
      try {
        if (!reader) throw new Error('no body');
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          length += value.length;
          if (length > MAX_RESPONSE) { await reader.cancel(); throw new Error('too large'); }
          chunks.push(value);
        }
        return { status: response.status, body: JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks))) };
      } catch { throw new Error('KoSync response invalid, oversized or timed out'); }
      finally { reader?.releaseLock(); }
    } finally { clearTimeout(timer); }
  }
  async authorize(): Promise<{ authorized: true }> {
    const { body } = await this.#request('GET', '/users/auth', [200]);
    if (record(body).authorized !== 'OK') throw new Error('invalid KoSync authorization response');
    return { authorized: true };
  }
  async register(): Promise<{ username: string }> {
    const { body } = await this.#request('POST', '/users/create', [201], { username: this.#username, password: this.#userkey });
    if (record(body).username !== this.#username) throw new Error('invalid KoSync registration response');
    return { username: this.#username };
  }
  async pull(document: string): Promise<ProgressState> {
    document = documentId(document);
    const { body } = await this.#request('GET', `/syncs/progress/${document}`, [200]);
    // Some Lua JSON implementations encode empty tables as [].
    if (Array.isArray(body) && body.length === 0) return { found: false, document };
    const data = record(body);
    if (Object.keys(data).length === 0) return { found: false, document };
    if (data.document !== undefined && data.document !== document) throw new Error('KoSync response document mismatch');
    return {
      found: true, document, progress: stringField(data.progress, 'progress'), percentage: percentage(data.percentage),
      ...(data.device === undefined ? {} : { device: stringField(data.device, 'device', 128) }),
      ...(data.device_id === undefined ? {} : { device_id: stringField(data.device_id, 'device_id', 128) }),
      ...(data.timestamp === undefined ? {} : { timestamp: timestamp(data.timestamp) }),
    };
  }
  async push(update: ProgressUpdate): Promise<{ document: string; timestamp?: number; accepted: boolean }> {
    const data = record(update);
    const payload: ProgressUpdate = {
      document: documentId(data.document), progress: stringField(data.progress, 'progress'), percentage: percentage(data.percentage),
      device: stringField(data.device, 'device', 128), device_id: stringField(data.device_id, 'device_id', 128),
    };
    const { status, body } = await this.#request('PUT', '/syncs/progress', [200, 202], payload);
    const result = record(body);
    if (result.document !== undefined && result.document !== payload.document) throw new Error('KoSync response document mismatch');
    return { document: payload.document, accepted: status === 202,
      ...(result.timestamp === undefined ? {} : { timestamp: timestamp(result.timestamp) }) };
  }
}

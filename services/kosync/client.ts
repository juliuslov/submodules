import { resolveConnection, type Connection } from './credentials';
import { request } from './transport';
import { documentId, percentage, record, stringField, timestamp } from './validation';
import type { KoSyncConfig, ProgressState, ProgressUpdate } from './types';

export { DEFAULT_SERVER } from './credentials';

/** KOReader-compatible progress-sync client.
 *
 * Only the four upstream endpoints documented in docs/KOSYNC.md are used, the
 * media type is `application/vnd.koreader.v1+json`, and nothing here creates an
 * account, uploads progress or contacts a server unless the caller explicitly
 * asks for that operation. Credentials live in private fields, so a client
 * serialises as `{}`. */
export class KoSyncClient {
  readonly #connection: Connection;

  constructor(config: KoSyncConfig) {
    this.#connection = resolveConnection(config);
  }

  async authorize(): Promise<{ authorized: true }> {
    const { body } = await request(this.#connection, 'GET', '/users/auth', [200]);
    if (record(body).authorized !== 'OK') throw new Error('invalid KoSync authorization response');
    return { authorized: true };
  }

  async register(): Promise<{ username: string }> {
    const { body } = await request(this.#connection, 'POST', '/users/create', [201], {
      username: this.#connection.username,
      password: this.#connection.userkey,
    });
    if (record(body).username !== this.#connection.username) throw new Error('invalid KoSync registration response');
    return { username: this.#connection.username };
  }

  async pull(document: string): Promise<ProgressState> {
    document = documentId(document);
    const { body } = await request(this.#connection, 'GET', `/syncs/progress/${document}`, [200]);
    // Some Lua JSON implementations encode an empty table as [].
    if (Array.isArray(body) && body.length === 0) return { found: false, document };
    const data = record(body);
    if (Object.keys(data).length === 0) return { found: false, document };
    if (data.document !== undefined && data.document !== document) throw new Error('KoSync response document mismatch');
    return {
      found: true,
      document,
      progress: stringField(data.progress, 'progress'),
      percentage: percentage(data.percentage),
      ...(data.device === undefined ? {} : { device: stringField(data.device, 'device', 128) }),
      ...(data.device_id === undefined ? {} : { device_id: stringField(data.device_id, 'device_id', 128) }),
      ...(data.timestamp === undefined ? {} : { timestamp: timestamp(data.timestamp) }),
    };
  }

  async push(update: ProgressUpdate): Promise<{ document: string; timestamp?: number; accepted: boolean }> {
    const data = record(update);
    const payload: ProgressUpdate = {
      document: documentId(data.document),
      progress: stringField(data.progress, 'progress'),
      percentage: percentage(data.percentage),
      device: stringField(data.device, 'device', 128),
      device_id: stringField(data.device_id, 'device_id', 128),
    };
    const { status, body } = await request(this.#connection, 'PUT', '/syncs/progress', [200, 202], payload);
    const result = record(body);
    if (result.document !== undefined && result.document !== payload.document) throw new Error('KoSync response document mismatch');
    return {
      document: payload.document,
      accepted: status === 202,
      ...(result.timestamp === undefined ? {} : { timestamp: timestamp(result.timestamp) }),
    };
  }
}

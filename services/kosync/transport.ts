import type { Connection } from './credentials';

/** Bounded HTTP transport for the KoSync client.
 *
 * Deliberately small and explicit: manual redirect handling (credentials are
 * never forwarded to another origin), a deadline that also covers a streaming
 * body, a 128 KiB response ceiling, and sanitised errors — a server body, URL
 * or header value is never echoed back, because any of them may contain the
 * credentials that were sent. */

export const MEDIA_TYPE = 'application/vnd.koreader.v1+json';
export const MAX_RESPONSE = 128 * 1024;

export async function request(
  connection: Connection,
  method: string,
  endpoint: string,
  statuses: number[],
  payload?: object,
): Promise<{ status: number; body: unknown }> {
  const url = new URL(connection.baseUrl);
  url.pathname = connection.baseUrl.pathname.replace(/\/+$/, '') + endpoint;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), connection.timeoutMs);
  timer.unref();
  try {
    let response: Response;
    try {
      response = await fetch(url, {
        method,
        redirect: 'manual',
        signal: controller.signal,
        headers: {
          Accept: MEDIA_TYPE,
          'Content-Type': 'application/json',
          // Registration creates the account, so it cannot authenticate yet.
          ...(endpoint === '/users/create' ? {} : { 'X-Auth-User': connection.username, 'X-Auth-Key': connection.userkey }),
        },
        body: payload === undefined ? undefined : JSON.stringify(payload),
      });
    } catch {
      throw new Error('KoSync connection failed or timed out');
    }
    if (!statuses.includes(response.status)) {
      await response.body?.cancel();
      throw new Error(`KoSync HTTP ${response.status}${response.status === 401 ? ' (unauthorized)' : ''}`);
    }
    if (Number(response.headers.get('content-length') || 0) > MAX_RESPONSE) {
      await response.body?.cancel();
      throw new Error('KoSync response exceeds 128 KiB');
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
        if (length > MAX_RESPONSE) {
          await reader.cancel();
          throw new Error('too large');
        }
        chunks.push(value);
      }
      const text = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks));
      return { status: response.status, body: JSON.parse(text) as unknown };
    } catch {
      throw new Error('KoSync response invalid, oversized or timed out');
    } finally {
      reader?.releaseLock();
    }
  } finally {
    clearTimeout(timer);
  }
}

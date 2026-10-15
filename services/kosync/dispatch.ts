import { boundedRead } from '../epub/src/archive';
import { KoSyncClient } from './client';
import { documentChecksum } from './checksum';
import type { KoSyncRequest, ProgressUpdate } from './types';
export async function runKoSync(request: KoSyncRequest): Promise<unknown> {
  if (!request || typeof request !== 'object') throw new Error('KoSync request required');
  if (request.operation === 'document') return { document: documentChecksum(request.path!, request.checksum ?? 'binary') };
  if (!['authorize', 'register', 'pull', 'push'].includes(request.operation)) throw new Error('unknown KoSync operation');
  if (request.allowInsecureLocal !== undefined && typeof request.allowInsecureLocal !== 'boolean') throw new Error('allowInsecureLocal must be boolean');
  // Only runtime environment supplies CLI credentials. Never argv, JSON output,
  // repository config, automatic persistence, or an external credential provider.
  const client = new KoSyncClient({
    username: process.env.KOSYNC_USERNAME!, password: process.env.KOSYNC_PASSWORD,
    userkey: process.env.KOSYNC_USERKEY, baseUrl: request.server ?? process.env.KOSYNC_URL,
    allowInsecureLocal: request.allowInsecureLocal ?? process.env.KOSYNC_ALLOW_INSECURE_LOCAL === '1',
  });
  switch (request.operation) {
    case 'authorize': return client.authorize();
    case 'register': return client.register();
    case 'pull': return client.pull(request.document!);
    case 'push': {
      const input = request.inputPath === undefined ? request.progress : JSON.parse(boundedRead(request.inputPath, 128 * 1024).toString('utf8')) as ProgressUpdate;
      return client.push(input!);
    }
  }
}

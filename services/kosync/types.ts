export interface KoSyncConfig {
  username: string; password?: string; userkey?: string;
  baseUrl?: string; timeoutMs?: number; allowInsecureLocal?: boolean;
}
export interface ProgressUpdate {
  document: string; progress: string; percentage: number; device: string; device_id: string;
}
export type ProgressState = { found: false; document: string } | {
  found: true; document: string; progress: string; percentage: number;
  device?: string; device_id?: string; timestamp?: number;
};
export interface KoSyncRequest {
  operation: 'authorize' | 'register' | 'pull' | 'push' | 'document';
  server?: string; allowInsecureLocal?: boolean; document?: string; progress?: ProgressUpdate;
  path?: string; checksum?: 'binary' | 'filename'; inputPath?: string;
}

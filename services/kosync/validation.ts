export function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('KoSync expected a JSON object');
  return value as Record<string, unknown>;
}
export function stringField(value: unknown, label: string, max = 8192): string {
  if (typeof value !== 'string' || !value || Buffer.byteLength(value) > max || /[\x00-\x1f\x7f]/.test(value)) throw new Error(`invalid KoSync ${label}`);
  return value;
}
export function documentId(value: unknown): string {
  const id = stringField(value, 'document', 256);
  if (!/^[A-Za-z0-9_]+$/.test(id)) throw new Error('KoSync document must be alphanumeric/underscore (usually a checksum)');
  return id;
}
export function percentage(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > 1) throw new Error('KoSync percentage must be a number in [0, 1]');
  return value;
}
export function timestamp(value: unknown): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) throw new Error('invalid KoSync timestamp');
  return value;
}

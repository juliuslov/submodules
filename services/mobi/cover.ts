/** Cover images for either output format.
 *
 * Covers travel as opaque bytes: hikari never re-encodes an image, so quality is
 * preserved and no image library is needed. Only formats that EPUB readers and
 * Kindle firmware actually accept are allowed, and the size is bounded because
 * a cover record larger than the book itself is a mistake, not a feature. */

export const MAX_COVER_BYTES = 4 * 1024 * 1024;

const SIGNATURES: { kind: string; test: (head: Buffer) => boolean; mediaType: string; extension: string }[] = [
  { kind: 'jpeg', mediaType: 'image/jpeg', extension: 'jpg',
    test: head => head.length > 3 && head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff },
  { kind: 'png', mediaType: 'image/png', extension: 'png',
    test: head => head.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) },
  { kind: 'gif', mediaType: 'image/gif', extension: 'gif',
    test: head => head.subarray(0, 6).toString('ascii') === 'GIF87a' || head.subarray(0, 6).toString('ascii') === 'GIF89a' },
];

/** Detected image kind by magic bytes, or `null` for anything else. */
export function coverKind(image: Buffer): string | null {
  for (const signature of SIGNATURES) if (signature.test(image.subarray(0, 16))) return signature.kind;
  return null;
}

export interface CoverImage {
  kind: string;
  mediaType: string;
  extension: string;
  bytes: Buffer;
}

/** Validates a cover buffer and reports how to declare it in EPUB metadata. */
export function inspectCover(image: Buffer): CoverImage {
  const signature = SIGNATURES.find(entry => entry.test(image.subarray(0, 16)));
  if (!signature) throw new Error('cover must be JPEG, PNG or GIF (detected by content, not by file name)');
  if (!image.length || image.length > MAX_COVER_BYTES) {
    throw new Error(`cover must be 1 byte to ${Math.floor(MAX_COVER_BYTES / (1024 * 1024))} MiB`);
  }
  return { kind: signature.kind, mediaType: signature.mediaType, extension: signature.extension, bytes: image };
}

/** Cover files looked up next to a book when none is embedded. */
export const COVER_NAMES = ['cover.jpg', 'cover.jpeg', 'cover.png', 'cover.gif', 'folder.jpg', 'folder.png', 'front.jpg'];

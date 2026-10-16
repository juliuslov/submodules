/** Relative luminance and alpha compositing.
 *
 * Coefficients are the ITU-R BT.709 / sRGB relative-luminance weights also
 * used by stb_image-based tooling: Y = 0.2126 R + 0.7152 G + 0.0722 B.
 * Transparent pixels are composited onto the chosen paper colour first, so a
 * PNG with alpha renders exactly like the same image flattened onto that
 * background. */

export function luminance(red: number, green: number, blue: number): number {
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}

/** Perceived brightness of one pixel, composited onto `background` (0 or 255). */
export function compositedLuminance(red: number, green: number, blue: number, alpha: number, background: number): number {
  const coverage = alpha / 255;
  return luminance(red, green, blue) * coverage + background * (1 - coverage);
}

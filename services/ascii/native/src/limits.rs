//! Hard limits shared with the TypeScript fallback (`services/ascii/limits.ts`).
//! Both implementations must reject the same hostile inputs; keep them in sync.

/// Encoded input ceiling, checked before any decode allocation.
pub const MAX_INPUT: u64 = 32 * 1024 * 1024;

/// Output grid ceilings (terminal cells, not pixels).
pub const MAX_COLUMNS: usize = 400;
pub const MAX_ROWS: usize = 200;

/// Ramp: 2..64 printable ASCII bytes, darkest first.
pub const MIN_RAMP: usize = 2;
pub const MAX_RAMP: usize = 64;

/// Decoded-image ceilings.
pub const MAX_DIMENSION: usize = 8192;
pub const MAX_PIXELS: usize = 16 * 1024 * 1024;

pub const DEFAULT_RAMP: &str = "@%#*+=-:. ";

pub const DECODE_ERROR: &str =
    "invalid, unsupported or oversized image (PNG/JPEG/BMP/PNM only)";

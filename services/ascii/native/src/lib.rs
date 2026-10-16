//! hikari's image-to-ASCII renderer, exposed to Node.js through napi-rs.
//!
//! Build (from the repository root, with Rust 1.88+ and Node 22.13+):
//!
//! ```sh
//! make ascii                      # wraps scripts/build-ascii.mjs
//! npx napi build --platform --release --manifest-path services/ascii/native/Cargo.toml \
//!   --output-dir build --no-js
//! ```
//!
//! The result is `build/hikari-ascii.<platform-arch-abi>.node`, which
//! `services/ascii/backends/native.ts` loads. When the addon is absent the
//! TypeScript renderer in `services/ascii/render/` produces the same grids, so
//! the feature never depends on a working Rust toolchain.
//!
//! Rust unit tests (`cargo test --manifest-path services/ascii/native/Cargo.toml`)
//! cover the renderer without a Node runtime; `npm test` covers the same cases
//! through the JavaScript boundary.

#![deny(clippy::all)]

mod image;
mod limits;
mod options;
mod render;

use napi::bindgen_prelude::{Buffer, Error, Result, Status};
use napi_derive::napi;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Options accepted from JavaScript. `services/ascii/options.ts` validates the
/// same shape first; the Rust side re-validates so a direct addon caller cannot
/// skip the limits.
#[napi(object)]
#[derive(Default)]
pub struct AsciiOptions {
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub invert: Option<bool>,
    pub ramp: Option<String>,
    /// `white` (default) or `black`.
    pub background: Option<String>,
}

/// One rendered grid: plain ASCII text plus the exact column/row count.
#[napi(object)]
pub struct AsciiRender {
    pub text: String,
    pub columns: u32,
    pub rows: u32,
}

fn failure(message: String) -> Error {
    Error::new(Status::GenericFailure, message)
}

fn from_native(result: render::Render) -> AsciiRender {
    AsciiRender {
        text: result.text,
        columns: result.columns as u32,
        rows: result.rows as u32,
    }
}

/// Renders one image file (PNG, JPEG, BMP or Netpbm) to ASCII.
#[napi]
pub fn render_ascii(path: String, options: Option<AsciiOptions>) -> Result<AsciiRender> {
    let parsed = options::from_js(options).map_err(failure)?;
    let decoded = image::load(&path).map_err(failure)?;
    render::render(&decoded, &parsed).map(from_native).map_err(failure)
}

/// Renders image bytes that the caller already holds, avoiding a second read.
#[napi]
pub fn render_ascii_bytes(data: Buffer, options: Option<AsciiOptions>) -> Result<AsciiRender> {
    let parsed = options::from_js(options).map_err(failure)?;
    let decoded = image::decode(data.as_ref()).map_err(failure)?;
    render::render(&decoded, &parsed).map(from_native).map_err(failure)
}

/// Build identity reported by `:HikariDoctor`.
#[napi]
pub fn native_info() -> String {
    format!(
        "hikari-ascii {VERSION} ({}-{})",
        std::env::consts::OS,
        std::env::consts::ARCH
    )
}

/// Limits the TypeScript layer reports in diagnostics, so a mismatch between
/// the addon and the fallback is visible instead of silent.
#[napi(object)]
pub struct AsciiLimits {
    pub max_columns: u32,
    pub max_rows: u32,
    pub max_input_bytes: i64,
    pub max_dimension: u32,
    pub max_pixels: u32,
}

#[napi]
pub fn native_limits() -> AsciiLimits {
    AsciiLimits {
        max_columns: limits::MAX_COLUMNS as u32,
        max_rows: limits::MAX_ROWS as u32,
        max_input_bytes: limits::MAX_INPUT as i64,
        max_dimension: limits::MAX_DIMENSION as u32,
        max_pixels: limits::MAX_PIXELS as u32,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_and_info_are_stable_strings() {
        assert!(!VERSION.is_empty());
        let info = native_info();
        assert!(info.starts_with("hikari-ascii "));
        assert!(info.contains(VERSION));
    }

    #[test]
    fn limits_match_the_documented_values() {
        let limits = native_limits();
        assert_eq!(limits.max_columns, 400);
        assert_eq!(limits.max_rows, 200);
        assert_eq!(limits.max_input_bytes, 32 * 1024 * 1024);
        assert_eq!(limits.max_dimension, 8192);
        assert_eq!(limits.max_pixels, 16 * 1024 * 1024);
    }

    #[test]
    fn bytes_are_rendered_without_touching_the_filesystem() {
        let ppm = Buffer::from(b"P6\n2 1\n255\n\0\0\0\xff\xff\xff".to_vec());
        let options = Some(AsciiOptions {
            width: Some(2),
            height: Some(1),
            invert: None,
            ramp: Some("@ ".into()),
            background: None,
        });
        let rendered = render_ascii_bytes(ppm, options).unwrap();
        assert_eq!(rendered.text, "@ \n");
        assert_eq!((rendered.columns, rendered.rows), (2, 1));
    }

    #[test]
    fn decode_failures_are_reported_as_errors() {
        let broken = Buffer::from(b"not an image".to_vec());
        assert!(render_ascii_bytes(broken, None).is_err());
    }

    #[test]
    fn missing_files_are_reported_as_errors() {
        let error = render_ascii("/nonexistent/hikari-image".into(), None).unwrap_err();
        assert!(error.reason.contains("cannot open image"));
    }
}

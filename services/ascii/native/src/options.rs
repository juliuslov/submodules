//! Option parsing for the JavaScript boundary.
//!
//! `services/ascii/options.ts` validates and normalises the same values before
//! they reach the addon; this module repeats the checks so a direct
//! `require('hikari-ascii....node')` caller cannot bypass the limits.

use crate::limits::{DEFAULT_RAMP, MAX_COLUMNS, MAX_RAMP, MAX_ROWS, MIN_RAMP};
use crate::AsciiOptions;

#[derive(Debug, Clone)]
pub struct Options {
    pub width: usize,
    pub height: Option<usize>,
    pub invert: bool,
    pub ramp: String,
    /// 255 = white paper, 0 = black paper.
    pub background: u8,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            width: 80,
            height: None,
            invert: false,
            ramp: DEFAULT_RAMP.to_string(),
            background: 255,
        }
    }
}

/// Converts the JavaScript object (`lib.rs::AsciiOptions`) into validated
/// options, re-applying every limit the TypeScript layer also enforces.
pub fn from_js(input: Option<AsciiOptions>) -> Result<Options, String> {
    let input = input.unwrap_or_default();
    let width = input.width.unwrap_or(80) as usize;
    if width < 1 || width > MAX_COLUMNS {
        return Err("invalid ASCII width".into());
    }
    let height = match input.height {
        None => None,
        Some(value) => {
            let value = value as usize;
            if value < 1 || value > MAX_ROWS {
                return Err("invalid ASCII height".into());
            }
            Some(value)
        }
    };
    let ramp = input.ramp.unwrap_or_else(|| DEFAULT_RAMP.to_string());
    let bytes = ramp.as_bytes();
    if bytes.len() < MIN_RAMP
        || bytes.len() > MAX_RAMP
        || !bytes.iter().all(|byte| (32..=126).contains(byte))
    {
        return Err("invalid ASCII ramp".into());
    }
    let background = match input.background.as_deref() {
        None | Some("white") => 255,
        Some("black") => 0,
        Some(_) => return Err("invalid ASCII background".into()),
    };
    Ok(Options {
        width,
        height,
        invert: input.invert.unwrap_or(false),
        ramp,
        background,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn options() -> Option<AsciiOptions> {
        Some(AsciiOptions {
            width: Some(40),
            height: Some(10),
            invert: Some(true),
            ramp: Some("@ ".into()),
            background: Some("black".into()),
        })
    }

    #[test]
    fn defaults_match_the_documented_behaviour() {
        let parsed = from_js(None).unwrap();
        assert_eq!(parsed.width, 80);
        assert_eq!(parsed.height, None);
        assert_eq!(parsed.background, 255);
        assert_eq!(parsed.ramp, DEFAULT_RAMP);
    }

    #[test]
    fn explicit_options_are_used() {
        let parsed = from_js(options()).unwrap();
        assert_eq!((parsed.width, parsed.height), (40, Some(10)));
        assert!(parsed.invert);
        assert_eq!(parsed.background, 0);
    }

    #[test]
    fn rejects_out_of_range_and_non_ascii_values() {
        assert!(from_js(Some(AsciiOptions { width: Some(0), ..Default::default() })).is_err());
        assert!(from_js(Some(AsciiOptions { width: Some(401), ..Default::default() })).is_err());
        assert!(from_js(Some(AsciiOptions { height: Some(201), ..Default::default() })).is_err());
        assert!(from_js(Some(AsciiOptions { ramp: Some("a".into()), ..Default::default() })).is_err());
        assert!(from_js(Some(AsciiOptions { ramp: Some("\u{1b} ".into()), ..Default::default() })).is_err());
        assert!(from_js(Some(AsciiOptions { ramp: Some("é ".into()), ..Default::default() })).is_err());
        assert!(from_js(Some(AsciiOptions { background: Some("blue".into()), ..Default::default() })).is_err());
    }
}

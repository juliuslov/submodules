//! Image loading and decoding.
//!
//! Decoding itself is delegated to the pinned stb_image decoder compiled from
//! `src/decode.c`; this module owns the file policy (regular file, bounded
//! size) and the FFI contract.

use std::ffi::{c_int, c_void};
use std::fs::File;
use std::io::Read;

use crate::limits::{DECODE_ERROR, MAX_DIMENSION, MAX_INPUT, MAX_PIXELS};

#[derive(Debug)]
pub struct Image {
    pub width: usize,
    pub height: usize,
    pub rgba: Vec<u8>,
}

extern "C" {
    fn wiz_image_decode(
        bytes: *const u8,
        length: c_int,
        width: *mut c_int,
        height: *mut c_int,
    ) -> *mut u8;
    fn wiz_image_free(pixels: *mut c_void);
}

/// Decodes an in-memory image. Returns `DECODE_ERROR` for malformed data.
pub fn decode(bytes: &[u8]) -> Result<Image, String> {
    if bytes.is_empty() || bytes.len() as u64 > MAX_INPUT {
        return Err("image must contain 1 byte to 32 MiB".into());
    }
    let (mut width, mut height) = (0, 0);
    // SAFETY: `bytes` is live and its length is bounded to c_int by the check
    // above (32 MiB < i32::MAX). The C shim validates the header dimensions
    // before decoding and returns an owned RGBA allocation or NULL.
    let pointer = unsafe {
        wiz_image_decode(
            bytes.as_ptr(),
            bytes.len() as c_int,
            &mut width,
            &mut height,
        )
    };
    if pointer.is_null() {
        return Err(DECODE_ERROR.into());
    }
    let (width, height) = (width as usize, height as usize);
    if width < 1
        || height < 1
        || width > MAX_DIMENSION
        || height > MAX_DIMENSION
        || width * height > MAX_PIXELS
    {
        unsafe { wiz_image_free(pointer.cast()) };
        return Err(DECODE_ERROR.into());
    }
    let length = width * height * 4;
    // SAFETY: the C shim guarantees positive dimensions <= 16 megapixels and
    // exactly four bytes per pixel. Copy before releasing with stb's allocator.
    let rgba = unsafe { std::slice::from_raw_parts(pointer, length).to_vec() };
    unsafe { wiz_image_free(pointer.cast()) };
    Ok(Image {
        width,
        height,
        rgba,
    })
}

/// Reads and decodes one regular file, never following a FIFO or device.
pub fn load(path: &str) -> Result<Image, String> {
    let file = File::open(path).map_err(|_| format!("cannot open image: {path}"))?;
    let metadata = file
        .metadata()
        .map_err(|_| format!("cannot stat image: {path}"))?;
    if !metadata.is_file() || metadata.len() > MAX_INPUT {
        return Err("expected a regular image file at most 32 MiB".into());
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    // `take` keeps a file that grows mid-read from exceeding the budget.
    file.take(MAX_INPUT + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "cannot read image".to_string())?;
    decode(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_garbage() {
        assert!(decode(b"not an image").is_err());
    }

    #[test]
    fn decodes_binary_ppm() {
        let image = decode(b"P6\n2 1\n255\n\0\0\0\xff\xff\xff").unwrap();
        assert_eq!((image.width, image.height), (2, 1));
        assert_eq!(image.rgba, vec![0, 0, 0, 255, 255, 255, 255, 255]);
    }

    #[test]
    fn bounds_dimensions_before_decode() {
        assert!(decode(b"P6\n9000 9000\n255\n\0").is_err());
    }

    #[test]
    fn rejects_empty_input() {
        assert!(decode(b"").is_err());
    }

    #[test]
    fn missing_files_report_a_stable_error() {
        let error = load("/nonexistent/hikari-image").unwrap_err();
        assert!(error.contains("cannot open image"));
    }
}

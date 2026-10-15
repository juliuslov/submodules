use std::ffi::{c_int, c_void};
use std::fs::File;
use std::io::Read;

pub const MAX_INPUT: u64 = 32 * 1024 * 1024;
#[derive(Debug)]
pub struct Image { pub width: usize, pub height: usize, pub rgba: Vec<u8> }
extern "C" {
    fn wiz_image_decode(bytes: *const u8, length: c_int, width: *mut c_int, height: *mut c_int) -> *mut u8;
    fn wiz_image_free(pixels: *mut c_void);
}
pub fn decode(bytes: &[u8]) -> Result<Image, String> {
    if bytes.is_empty() || bytes.len() as u64 > MAX_INPUT { return Err("image must contain 1 byte to 32 MiB".into()); }
    let (mut width, mut height) = (0, 0);
    // SAFETY: bytes is live and bounded to c_int length. The C shim checks
    // dimensions before decoding, returning an owned RGBA allocation or NULL.
    let ptr = unsafe { wiz_image_decode(bytes.as_ptr(), bytes.len() as c_int, &mut width, &mut height) };
    if ptr.is_null() { return Err("invalid, unsupported or oversized image (PNG/JPEG/BMP/PNM only)".into()); }
    let len = (width as usize) * (height as usize) * 4;
    // SAFETY: the C shim guarantees positive dimensions <= 16 megapixels and
    // exactly four bytes per pixel. Copy before releasing with the same allocator.
    let rgba = unsafe { std::slice::from_raw_parts(ptr, len).to_vec() };
    unsafe { wiz_image_free(ptr.cast()); }
    Ok(Image { width: width as usize, height: height as usize, rgba })
}
pub fn load(path: &str) -> Result<Image, String> {
    let file = File::open(path).map_err(|_| "cannot open image".to_string())?;
    let stat = file.metadata().map_err(|_| "cannot stat image".to_string())?;
    if !stat.is_file() || stat.len() > MAX_INPUT { return Err("expected a regular image file at most 32 MiB".into()); }
    let mut bytes = Vec::new();
    file.take(MAX_INPUT + 1).read_to_end(&mut bytes).map_err(|_| "cannot read image".to_string())?;
    decode(&bytes)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn rejects_garbage() { assert!(decode(b"not an image").is_err()); }
    #[test] fn decodes_binary_ppm() {
        let image = decode(b"P6\n2 1\n255\n\0\0\0\xff\xff\xff").unwrap();
        assert_eq!((image.width, image.height), (2, 1));
        assert_eq!(image.rgba, vec![0,0,0,255,255,255,255,255]);
    }
    #[test] fn bounds_dimensions_before_decode() {
        assert!(decode(b"P6\n9000 9000\n255\n\0").is_err());
    }
}

use crate::image::Image;
pub const DEFAULT_RAMP: &str = "@%#*+=-:. ";
#[derive(Debug)]
pub struct Options { pub width: usize, pub height: Option<usize>, pub invert: bool, pub ramp: String, pub background: u8 }
impl Default for Options {
    fn default() -> Self { Self { width: 80, height: None, invert: false, ramp: DEFAULT_RAMP.into(), background: 255 } }
}
pub fn render(image: &Image, options: &Options) -> Result<String, String> {
    if !(1..=400).contains(&options.width) || options.height.is_some_and(|h| !(1..=200).contains(&h)) {
        return Err("width must be 1..400 and height 1..200".into());
    }
    let ramp = options.ramp.as_bytes();
    if !(2..=64).contains(&ramp.len()) || !ramp.iter().all(|b| (32..=126).contains(b)) {
        return Err("ramp must contain 2..64 printable ASCII characters, darkest first".into());
    }
    if image.width == 0 || image.height == 0 || image.width > 8192 || image.height > 8192 ||
        image.width * image.height > 16 * 1024 * 1024 || image.rgba.len() != image.width * image.height * 4 {
        return Err("invalid image dimensions or pixel buffer".into());
    }
    let mut width = options.width;
    let height = match options.height {
        Some(height) => height,
        None => {
            let natural = width as f64 * image.height as f64 / image.width as f64 * 0.5;
            if natural > 200.0 {
                width = (200.0 * 2.0 * image.width as f64 / image.height as f64).floor().max(1.0) as usize;
            }
            (width as f64 * image.height as f64 / image.width as f64 * 0.5).round().clamp(1.0, 200.0) as usize
        }
    };
    let mut output = String::with_capacity((width + 1) * height);
    for row in 0..height {
        let y0 = row as f64 * image.height as f64 / height as f64;
        let y1 = (row + 1) as f64 * image.height as f64 / height as f64;
        for column in 0..width {
            let x0 = column as f64 * image.width as f64 / width as f64;
            let x1 = (column + 1) as f64 * image.width as f64 / width as f64;
            let (mut weighted, mut area) = (0.0, 0.0);
            for y in y0.floor() as usize..(y1.ceil() as usize).min(image.height) {
                for x in x0.floor() as usize..(x1.ceil() as usize).min(image.width) {
                    let weight = (x1.min((x+1) as f64) - x0.max(x as f64)) *
                        (y1.min((y+1) as f64) - y0.max(y as f64));
                    let p = (y * image.width + x) * 4;
                    let alpha = image.rgba[p+3] as f64 / 255.0;
                    let luminance = 0.2126 * image.rgba[p] as f64 + 0.7152 * image.rgba[p+1] as f64 + 0.0722 * image.rgba[p+2] as f64;
                    weighted += (luminance * alpha + options.background as f64 * (1.0-alpha)) * weight;
                    area += weight;
                }
            }
            let mut index = (weighted / area / 255.0 * (ramp.len()-1) as f64).round() as usize;
            index = index.min(ramp.len()-1);
            if options.invert { index = ramp.len()-1-index; }
            output.push(ramp[index] as char);
        }
        output.push('\n');
    }
    Ok(output)
}
#[cfg(test)]
mod tests {
    use super::*;
    fn pair() -> Image { Image { width:2, height:1, rgba:vec![0,0,0,255,255,255,255,255] } }
    fn opts() -> Options { Options { width:2, height:Some(1), ramp:"@ ".into(), ..Options::default() } }
    #[test] fn black_and_white() { assert_eq!(render(&pair(), &opts()).unwrap(), "@ \n"); }
    #[test] fn inversion() { assert_eq!(render(&pair(), &Options { invert:true, ..opts() }).unwrap(), " @\n"); }
    #[test] fn averaged_luminance() {
        assert_eq!(render(&pair(), &Options { width:1, ramp:"@x ".into(), ..opts() }).unwrap(), "x\n");
    }
    #[test] fn transparent_white_background() {
        let image = Image { width:1, height:1, rgba:vec![0,0,0,0] };
        assert_eq!(render(&image, &opts()).unwrap(), "  \n");
        assert_eq!(render(&image, &Options { background:0, ..opts() }).unwrap(), "@@\n");
    }
    #[test] fn rejects_bad_dimensions() { assert!(render(&pair(), &Options { width:0, ..opts() }).is_err()); }
    #[test] fn rejects_control_or_unicode_ramp() {
        for ramp in ["a", "a\n", "é ", "\x1b "] { assert!(render(&pair(), &Options { ramp:ramp.into(), ..opts() }).is_err()); }
    }
    #[test] fn aspect_ratio_accounts_for_terminal_cells() {
        let output = render(&pair(), &Options { width:8, ..Options::default() }).unwrap();
        assert_eq!(output.lines().count(), 2);
        assert_eq!(output.lines().next().unwrap().len(), 8);
    }
    #[test] fn tall_images_fit_maximum_grid() {
        let image = Image { width:1, height:8192, rgba:vec![255;8192*4] };
        let output = render(&image, &Options::default()).unwrap();
        assert_eq!(output.lines().count(), 200);
        assert!(output.len() <= 80200);
    }
}

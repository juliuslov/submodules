//! Area-sampled terminal rendering.
//!
//! Every output cell averages the source pixels that overlap it, weighted by
//! the exact overlap area, then maps the mean relative luminance
//! (0.2126 R + 0.7152 G + 0.0722 B, composited onto the chosen paper colour)
//! onto the darkest-first ramp. `services/ascii/render/` is the TypeScript
//! equivalent; both must produce identical grids for identical inputs.

use crate::image::Image;
use crate::limits::{MAX_COLUMNS, MAX_PIXELS, MAX_RAMP, MAX_ROWS, MIN_RAMP};
use crate::options::Options;

pub struct Render {
    pub text: String,
    pub columns: usize,
    pub rows: usize,
}

pub fn render(image: &Image, options: &Options) -> Result<Render, String> {
    if !(1..=MAX_COLUMNS).contains(&options.width)
        || options.height.is_some_and(|h| !(1..=MAX_ROWS).contains(&h))
    {
        return Err(format!(
            "width must be 1..{MAX_COLUMNS} and height must be 1..{MAX_ROWS}"
        ));
    }
    let ramp = options.ramp.as_bytes();
    if !(MIN_RAMP..=MAX_RAMP).contains(&ramp.len())
        || !ramp.iter().all(|byte| (32..=126).contains(byte))
    {
        return Err("ramp must contain 2..64 printable ASCII characters, darkest first".into());
    }
    if image.width == 0
        || image.height == 0
        || image.width * image.height > MAX_PIXELS
        || image.rgba.len() != image.width * image.height * 4
    {
        return Err("invalid image dimensions or pixel buffer".into());
    }
    let mut width = options.width;
    let height = match options.height {
        Some(height) => height,
        None => {
            // Terminal cells are about twice as tall as they are wide.
            let natural = width as f64 * image.height as f64 / image.width as f64 * 0.5;
            if natural > MAX_ROWS as f64 {
                width = (MAX_ROWS as f64 * 2.0 * image.width as f64 / image.height as f64)
                    .floor()
                    .max(1.0) as usize;
            }
            (width as f64 * image.height as f64 / image.width as f64 * 0.5).round()
                .clamp(1.0, MAX_ROWS as f64) as usize
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
                let vertical = y1.min((y + 1) as f64) - y0.max(y as f64);
                if vertical <= 0.0 {
                    continue;
                }
                for x in x0.floor() as usize..(x1.ceil() as usize).min(image.width) {
                    let weight = (x1.min((x + 1) as f64) - x0.max(x as f64)) * vertical;
                    if weight <= 0.0 {
                        continue;
                    }
                    let at = (y * image.width + x) * 4;
                    let alpha = image.rgba[at + 3] as f64 / 255.0;
                    let luminance = 0.2126 * image.rgba[at] as f64
                        + 0.7152 * image.rgba[at + 1] as f64
                        + 0.0722 * image.rgba[at + 2] as f64;
                    weighted +=
                        (luminance * alpha + options.background as f64 * (1.0 - alpha)) * weight;
                    area += weight;
                }
            }
            let brightness = if area > 0.0 {
                weighted / area
            } else {
                options.background as f64
            };
            let last = ramp.len() - 1;
            let mut index = ((brightness / 255.0 * last as f64).round() as usize).min(last);
            if options.invert {
                index = last - index;
            }
            output.push(ramp[index] as char);
        }
        output.push('\n');
    }
    Ok(Render {
        text: output,
        columns: width,
        rows: height,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair() -> Image {
        Image {
            width: 2,
            height: 1,
            rgba: vec![0, 0, 0, 255, 255, 255, 255, 255],
        }
    }

    fn options() -> Options {
        Options {
            width: 2,
            height: Some(1),
            ramp: "@ ".into(),
            ..Options::default()
        }
    }

    #[test]
    fn black_and_white() {
        assert_eq!(render(&pair(), &options()).unwrap().text, "@ \n");
    }

    #[test]
    fn inversion() {
        let inverted = Options {
            invert: true,
            ..options()
        };
        assert_eq!(render(&pair(), &inverted).unwrap().text, " @\n");
    }

    #[test]
    fn averaged_luminance() {
        let averaged = Options {
            width: 1,
            ramp: "@x ".into(),
            ..options()
        };
        assert_eq!(render(&pair(), &averaged).unwrap().text, "x\n");
    }

    #[test]
    fn transparent_white_background() {
        let image = Image {
            width: 1,
            height: 1,
            rgba: vec![0, 0, 0, 0],
        };
        assert_eq!(render(&image, &options()).unwrap().text, "  \n");
        let black = Options {
            background: 0,
            ..options()
        };
        assert_eq!(render(&image, &black).unwrap().text, "@@\n");
    }

    #[test]
    fn rejects_bad_dimensions() {
        let zero = Options { width: 0, ..options() };
        assert!(render(&pair(), &zero).is_err());
        let tall = Options {
            height: Some(201),
            ..options()
        };
        assert!(render(&pair(), &tall).is_err());
    }

    #[test]
    fn rejects_control_or_unicode_ramp() {
        for ramp in ["a", "a\n", "é ", "\x1b "] {
            let invalid = Options {
                ramp: ramp.into(),
                ..options()
            };
            assert!(render(&pair(), &invalid).is_err(), "ramp {ramp:?} accepted");
        }
    }

    #[test]
    fn aspect_ratio_accounts_for_terminal_cells() {
        let natural = Options {
            width: 8,
            ..Options::default()
        };
        let result = render(&pair(), &natural).unwrap();
        assert_eq!(result.rows, 2);
        assert_eq!(result.columns, 8);
        assert_eq!(result.text.lines().count(), 2);
    }

    #[test]
    fn tall_images_fit_maximum_grid() {
        let image = Image {
            width: 1,
            height: 8192,
            rgba: vec![255; 8192 * 4],
        };
        let result = render(&image, &Options::default()).unwrap();
        assert_eq!(result.rows, MAX_ROWS);
        assert!(result.text.len() <= (MAX_COLUMNS + 1) * MAX_ROWS);
    }

    #[test]
    fn wide_images_shrink_columns_instead_of_squashing() {
        let image = Image {
            width: 8192,
            height: 16,
            rgba: vec![0; 8192 * 16 * 4],
        };
        let result = render(&image, &Options::default()).unwrap();
        assert!(result.columns <= MAX_COLUMNS);
        assert!(result.rows <= MAX_ROWS);
    }
}

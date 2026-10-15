mod image;
mod render;
use std::env;
use std::io::{self, Write};
use render::Options;
const USAGE: &str = "wiz-ascii <image> [--width 1..400] [--height 1..200] [--invert] [--ramp 'dark to light'] [--background white|black]";
fn run(args: Vec<String>) -> Result<(), String> {
    if args == ["--version"] { println!("wiz-ascii 1.0.0"); return Ok(()); }
    if args == ["--help"] { println!("{USAGE}"); return Ok(()); }
    if args.is_empty() { return Err(USAGE.into()); }
    let path = &args[0];
    let mut options = Options::default();
    let mut index = 1;
    while index < args.len() {
        let flag = &args[index];
        if flag == "--invert" { options.invert = true; index += 1; continue; }
        index += 1;
        let value = args.get(index).ok_or_else(|| format!("missing value for {flag}"))?;
        match flag.as_str() {
            "--width" => options.width = value.parse().map_err(|_| "invalid width")?,
            "--height" => options.height = Some(value.parse().map_err(|_| "invalid height")?),
            "--ramp" => options.ramp = value.clone(),
            "--background" => options.background = match value.as_str() { "white" => 255, "black" => 0, _ => return Err("background must be white or black".into()) },
            _ => return Err(format!("unknown option: {flag}")),
        }
        index += 1;
    }
    let output = render::render(&image::load(path)?, &options)?;
    io::stdout().write_all(output.as_bytes()).map_err(|_| "cannot write ASCII output".into())
}
fn main() {
    if let Err(error) = run(env::args().skip(1).collect()) { eprintln!("{error}"); std::process::exit(1); }
}

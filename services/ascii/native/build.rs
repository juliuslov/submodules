use std::path::Path;

fn main() {
  // Required napi-rs setup: links the Node N-API symbols on every platform.
  napi_build::setup();

  // The image codecs stay in C: stb_image is the pinned upstream decoder that
  // both the Rust addon and (through the same file) the documented format list
  // refer to. Everything else — sampling, luminance, ramp mapping — is Rust.
  let vendor = Path::new("../../../vendor/stb");
  if !vendor.join("stb_image.h").exists() {
    panic!(
      "vendor/stb/stb_image.h is missing; run `git submodule update --init --recursive` from the repository root"
    );
  }
  cc::Build::new()
    .file("src/decode.c")
    .include(vendor)
    .flag_if_supported("-std=c99")
    .opt_level(2)
    .warnings(false)
    .compile("wiz_image");
}

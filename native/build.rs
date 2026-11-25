use std::env;

fn main() {
    println!("cargo:rerun-if-changed=src/pair_import.m");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    cc::Build::new()
        .file("src/pair_import.m")
        .flag("-fobjc-arc")
        .flag("-fblocks")
        .compile("tern_pair_import");
    for framework in ["AppKit", "Foundation", "Vision", "ImageIO", "CoreGraphics", "CoreFoundation"] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
    println!("cargo:rustc-link-lib=objc");
}

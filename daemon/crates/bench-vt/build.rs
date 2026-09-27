//! Links the vendored libghostty-vt archive for the target, and checks that `src/ffi.rs`
//! still describes the vendored header before anything links against it.
//!
//! The archive is built once per Ghostty bump by `scripts/bump-ghostty.sh`, so the gate
//! needs no zig. A header change that moves a struct or a signature would link cleanly
//! and misbehave at runtime; `abi.c` redeclares everything `ffi.rs` uses against the real
//! header, so such a change fails here instead.

use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let vendor = manifest.join("../../vendor/libghostty-vt");
    let vendor = vendor.canonicalize().unwrap_or(vendor);
    let target = std::env::var("TARGET").unwrap();
    let dir = vendor.join(&target);
    let archive = dir.join("libghostty-vt.a");
    if !archive.is_file() {
        panic!(
            "no libghostty-vt for {target} at {}: scripts/bump-ghostty.sh builds the \
             archives for aarch64-apple-darwin and x86_64-unknown-linux-gnu",
            archive.display()
        );
    }
    println!("cargo:rustc-link-search=native={}", dir.display());
    println!("cargo:rustc-link-lib=static=ghostty-vt");
    println!("cargo:rerun-if-changed={}", archive.display());

    let include = vendor.join("include");
    let abi = manifest.join("abi.c");
    println!("cargo:rerun-if-changed={}", abi.display());
    println!("cargo:rerun-if-changed={}", include.display());
    let cc = std::env::var("CC").unwrap_or_else(|_| "cc".into());
    let out = Command::new(&cc)
        .args(["-fsyntax-only", "-std=c11", "-Werror", "-I"])
        .arg(&include)
        .arg(&abi)
        .output()
        .unwrap_or_else(|e| panic!("{cc} (for the libghostty-vt ABI check): {e}"));
    if !out.status.success() {
        panic!(
            "src/ffi.rs no longer matches the vendored libghostty-vt header \
             (abi.c):\n{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
}

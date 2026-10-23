//! `cargo xtask ios`: the iOS app's Rust core (`photocraft-ffi`) as an XCFramework, and its Swift
//! bindings (UniFFI), where the Xcode project in `ios/` picks them up.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::{cargo, run};

const DEVICE: &str = "aarch64-apple-ios";
const SIMULATOR: &str = "aarch64-apple-ios-sim";
/// Keep in step with `deploymentTarget` in ios/project.yml.
const DEPLOYMENT_TARGET: &str = "17.0";

pub fn cmd(root: &Path, args: &[&str]) -> Result<(), String> {
    let release = args.contains(&"--release");
    let targets = match (args.contains(&"--sim"), args.contains(&"--device")) {
        (true, false) => vec![SIMULATOR],
        (false, true) => vec![DEVICE],
        _ => vec![DEVICE, SIMULATOR],
    };
    let target_dir = std::env::var_os("CARGO_TARGET_DIR").map_or_else(|| root.join("target"), PathBuf::from);
    let profile = if release { "release" } else { "debug" };
    for t in &targets {
        let mut c = cargo();
        c.args(["build", "-p", "photocraft-ffi", "--lib", "--target", t]).env("IPHONEOS_DEPLOYMENT_TARGET", DEPLOYMENT_TARGET);
        if release {
            c.arg("--release");
            // Keep the builder's home and checkout paths out of the shipped library's panic messages.
            // rustc uses the last rule that matches, so the checkout (inside home) goes last.
            let mut flags = Vec::new();
            if let Some(home) = std::env::var_os("HOME") {
                flags.push(format!("--remap-path-prefix={}=~", Path::new(&home).display()));
            }
            flags.push(format!("--remap-path-prefix={}=.", root.display()));
            c.env("CARGO_ENCODED_RUSTFLAGS", flags.join("\x1f"));
        }
        run(c, &format!("cargo build -p photocraft-ffi --target {t} ({profile})"))
            .map_err(|e| format!("{e}\n(the iOS targets come from rustup: `rustup target add {DEVICE} {SIMULATOR}`, and cargo must be rustup's)"))?;
    }

    // UniFFI reads the API from a host build of the library.
    let mut c = cargo();
    c.args(["build", "-p", "photocraft-ffi", "--lib"]);
    run(c, "cargo build -p photocraft-ffi (host, for the bindings)")?;
    let out = target_dir.join("ios");
    let swift = out.join("swift");
    let headers = out.join("headers");
    for d in [&swift, &headers] {
        let _ = std::fs::remove_dir_all(d);
        std::fs::create_dir_all(d).map_err(|e| format!("{}: {e}", d.display()))?;
    }
    let host_lib = target_dir.join("debug").join("libphotocraft_ffi.dylib");
    let mut c = cargo();
    c.args(["run", "-q", "-p", "photocraft-ffi", "--features", "bindgen", "--bin", "uniffi-bindgen", "--", "generate", "--library"])
        .arg(&host_lib)
        .args(["--language", "swift", "--out-dir"])
        .arg(&swift);
    run(c, "uniffi-bindgen generate (Swift)")?;
    copy(&swift.join("photocraft_ffiFFI.h"), &headers.join("photocraft_ffiFFI.h"))?;
    copy(&swift.join("photocraft_ffiFFI.modulemap"), &headers.join("module.modulemap"))?;

    let framework = root.join("ios/Frameworks/PhotoWagonCore.xcframework");
    let _ = std::fs::remove_dir_all(&framework);
    let mut c = Command::new("xcodebuild");
    c.arg("-create-xcframework");
    // Keep the other platform's library from an earlier build, so a device build doesn't drop the
    // simulator's (or the other way round).
    for t in [DEVICE, SIMULATOR] {
        let lib = target_dir.join(t).join(profile).join("libphotocraft_ffi.a");
        if targets.contains(&t) || lib.exists() {
            c.arg("-library").arg(lib).arg("-headers").arg(&headers);
        }
    }
    c.arg("-output").arg(&framework);
    run(c, "xcodebuild -create-xcframework")?;
    copy(&swift.join("photocraft_ffi.swift"), &root.join("ios/PhotoWagon/Core/photocraft_ffi.swift"))?;
    crate::licenses::write(root, DEVICE, &out.join("Acknowledgements.json"))?;
    eprintln!("ios: {} and ios/PhotoWagon/Core/photocraft_ffi.swift are up to date", framework.display());
    Ok(())
}

fn copy(from: &Path, to: &Path) -> Result<(), String> {
    if let Some(dir) = to.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    std::fs::copy(from, to).map(|_| ()).map_err(|e| format!("{} -> {}: {e}", from.display(), to.display()))
}

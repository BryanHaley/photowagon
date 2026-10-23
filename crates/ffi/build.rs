//! Builds LibRaw from the `submodules/LibRaw` checkout, with the wrapper in `src/libraw.cpp`, and
//! libjxl from `submodules/libjxl` (with CMake), with the wrapper in `src/jxl.cpp`.

use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../submodules/LibRaw");
    let src = root.join("src");
    println!("cargo:rerun-if-changed=src/libraw.cpp");
    println!("cargo:rerun-if-changed={}", src.display());
    let mut files = Vec::new();
    collect(&src, &mut files);
    // The `*_ph.cpp` files are included by others, not built on their own.
    files.retain(|f| f.extension().is_some_and(|e| e == "cpp") && !f.file_stem().is_some_and(|s| s.to_string_lossy().ends_with("_ph")));
    assert!(!files.is_empty(), "LibRaw sources missing: run `git submodule update --init`");
    cc::Build::new()
        .cpp(true)
        .std("c++14")
        .include(&root)
        .define("USE_ZLIB", None)
        .files(&files)
        .file("src/libraw.cpp")
        .warnings(false)
        .opt_level(3)
        .compile("libraw");
    println!("cargo:rustc-link-lib=z");
    libjxl();
}

/// libjxl (encoder and decoder), its colour management (skcms) and thread pool, with highway and
/// brotli, as static libraries, then the wrapper.
fn libjxl() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../submodules/libjxl");
    println!("cargo:rerun-if-changed=src/jxl.cpp");
    println!("cargo:rerun-if-changed={}", root.join("lib").display());
    assert!(
        root.join("third_party/highway/CMakeLists.txt").exists()
            && root.join("third_party/brotli/CMakeLists.txt").exists()
            && root.join("third_party/skcms/skcms.h").exists(),
        "libjxl's dependencies are missing: run `git -C submodules/libjxl submodule update --init --depth 1 third_party/highway third_party/brotli third_party/skcms`"
    );
    let out = PathBuf::from(std::env::var("OUT_DIR").expect("cargo sets OUT_DIR")).join("libjxl");
    let target = std::env::var("TARGET").unwrap_or_default();
    // Xcode's build step runs cargo with a bare PATH: look where Homebrew puts the tools too.
    let tool = |name: &str| {
        ["/opt/homebrew/bin", "/usr/local/bin"].iter().map(|d| Path::new(d).join(name)).find(|p| p.exists()).unwrap_or_else(|| PathBuf::from(name))
    };
    let cmake = tool("cmake");
    let ninja = tool("ninja");
    let mut c = Command::new(&cmake);
    c.arg("-S").arg(&root).arg("-B").arg(&out).arg("-DCMAKE_BUILD_TYPE=Release").arg("-DCMAKE_POSITION_INDEPENDENT_CODE=ON");
    // Only the baseline SIMD target (NEON on arm64, which every iPhone since the XR has): highway
    // otherwise also builds SVE, SVE2 and BF16 code no Apple chip runs, most of the library.
    c.args(["-DCMAKE_C_FLAGS=-DHWY_COMPILE_ONLY_STATIC=1", "-DCMAKE_CXX_FLAGS=-DHWY_COMPILE_ONLY_STATIC=1"]);
    if ninja.exists() {
        c.arg("-G").arg("Ninja").arg(format!("-DCMAKE_MAKE_PROGRAM={}", ninja.display()));
    }
    for (k, v) in [
        ("BUILD_SHARED_LIBS", "OFF"),
        ("BUILD_TESTING", "OFF"),
        ("JPEGXL_ENABLE_TOOLS", "OFF"),
        ("JPEGXL_ENABLE_JPEGLI", "OFF"),
        ("JPEGXL_ENABLE_DOXYGEN", "OFF"),
        ("JPEGXL_ENABLE_MANPAGES", "OFF"),
        ("JPEGXL_ENABLE_BENCHMARK", "OFF"),
        ("JPEGXL_ENABLE_EXAMPLES", "OFF"),
        ("JPEGXL_ENABLE_JNI", "OFF"),
        ("JPEGXL_ENABLE_SJPEG", "OFF"),
        ("JPEGXL_ENABLE_OPENEXR", "OFF"),
        ("JPEGXL_ENABLE_SKCMS", "ON"),
        ("JPEGXL_ENABLE_FUZZERS", "OFF"),
        ("JPEGXL_ENABLE_PLUGINS", "OFF"),
        ("JPEGXL_ENABLE_VIEWERS", "OFF"),
        ("JPEGXL_ENABLE_DEVTOOLS", "OFF"),
        ("JPEGXL_BUNDLE_LIBPNG", "OFF"),
        ("JPEGXL_ENABLE_AVX512", "OFF"),
    ] {
        c.arg(format!("-D{k}={v}"));
    }
    if target.contains("apple-ios") {
        let sdk = if target.ends_with("-sim") { "iphonesimulator" } else { "iphoneos" };
        let deployment = std::env::var("IPHONEOS_DEPLOYMENT_TARGET").unwrap_or_else(|_| "17.0".into());
        c.args([
            "-DCMAKE_SYSTEM_NAME=iOS",
            &format!("-DCMAKE_OSX_SYSROOT={sdk}"),
            "-DCMAKE_OSX_ARCHITECTURES=arm64",
            &format!("-DCMAKE_OSX_DEPLOYMENT_TARGET={deployment}"),
        ]);
    }
    run(&mut c, "configure libjxl");
    run(Command::new(&cmake).arg("--build").arg(&out).args(["--target", "jxl", "jxl_cms", "jxl_threads", "--parallel"]), "build libjxl");
    for dir in ["lib", "third_party/highway", "third_party/brotli"] {
        println!("cargo:rustc-link-search=native={}", out.join(dir).display());
    }
    for lib in ["jxl", "jxl_cms", "jxl_threads", "hwy", "brotlienc", "brotlidec", "brotlicommon"] {
        println!("cargo:rustc-link-lib=static={lib}");
    }
    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .include(root.join("lib/include"))
        .include(out.join("lib/include"))
        .define("JXL_STATIC_DEFINE", None)
        .define("JXL_CMS_STATIC_DEFINE", None)
        .define("JXL_THREADS_STATIC_DEFINE", None)
        .file("src/jxl.cpp")
        .opt_level(3)
        .compile("pcjxl");
}

fn run(c: &mut Command, what: &str) {
    let status = c.status().unwrap_or_else(|e| panic!("{what}: {e} (CMake is needed to build libjxl: `brew install cmake ninja`)"));
    assert!(status.success(), "{what} failed");
}

fn collect(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.is_dir() { collect(&path, out) } else { out.push(path) }
    }
}

//! Every format and option we import, checked against the format's own decoder (feature `corpus`).
//!
//! `corpus/formats` is made by `python3 -I scripts/format_samples.py`: our test chart written by
//! each format's standard encoder, with a reference decode (raw f32 RGBA or CMYKA) by its standard
//! decoder. Each sample is imported and flattened in the document's own colour mode, then compared:
//! exact (within half a level of its bit depth) for lossless files, within a small mean and max
//! error for lossy ones (decoders round and upsample differently). Size, depth, mode, profile and
//! layer count are checked against what the sample should open as. Colour errors are weighted by
//! alpha (none under transparent pixels). Prints a table and writes `corpus/formats/report.md`.

#![cfg(feature = "corpus")]

use std::path::{Path, PathBuf};

use photocraft_color::{ColorMode, PixelFormat, SampleType};
use serde_json::Value;

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../corpus/formats")
}

struct Outcome {
    name: String,
    verdict: &'static str,
    detail: String,
}

fn check(dir: &Path, s: &Value) -> Outcome {
    let file = s["file"].as_str().unwrap_or_default();
    let name = format!("{}/{}", s["format"].as_str().unwrap_or("?"), s["option"].as_str().unwrap_or("?"));
    let bytes = match std::fs::read(dir.join(file)) {
        Ok(b) => b,
        Err(e) => return Outcome { name, verdict: "MISSING", detail: e.to_string() },
    };
    let file_name = Path::new(file).file_name().and_then(|n| n.to_str()).unwrap_or(file).to_string();
    let imported = match std::panic::catch_unwind(|| photocraft_io::import(&file_name, &bytes)) {
        Err(_) => return Outcome { name, verdict: "CRASH", detail: "import panicked".into() },
        Ok(Err(e)) => return Outcome { name, verdict: "ERROR", detail: e.to_string() },
        Ok(Ok(r)) => r,
    };
    let mut imported = imported;
    // Targa alpha opens as an "Alpha 1" channel over an opaque Background, as in Photoshop: turn it
    // back into transparency to compare it.
    if s["format"] == "tga" {
        photocraft_io::tga_alpha_channel_to_transparency(&mut imported.document);
    }
    let doc = &imported.document;
    // Files only the hostile-input check uses: opening without a crash or hang is the test.
    if s["open_only"].as_bool() == Some(true) {
        return Outcome { name, verdict: "PASS", detail: "opened (no reference decode)".into() };
    }
    let e = &s["expect"];
    let mut problems = Vec::new();
    let (w, h) = (s["width"].as_u64().unwrap_or(0) as u32, s["height"].as_u64().unwrap_or(0) as u32);
    if (doc.size.width, doc.size.height) != (w, h) {
        problems.push(format!("size {}×{}, expected {w}×{h}", doc.size.width, doc.size.height));
    }
    let depth = match doc.depth {
        SampleType::U8 => 8,
        SampleType::U16 => 16,
        SampleType::F32 => 32,
    };
    if let Some(d) = e["depth"].as_u64()
        && d != depth
    {
        problems.push(format!("{depth}-bit, expected {d}-bit"));
    }
    let mode = format!("{:?}", doc.mode);
    let want_mode = e["mode"].as_str().unwrap_or("Rgb");
    // Palette files may open as Indexed (as Photoshop does) or expanded to RGB.
    if want_mode != "*" && mode != want_mode && !(want_mode == "Rgb" && mode == "Indexed") {
        problems.push(format!("{mode}, expected {want_mode}"));
    }
    if e["icc"].as_bool() == Some(true) && doc.icc_profile.is_none() {
        problems.push("embedded profile dropped".into());
    }
    if let Some(n) = e["layers"].as_u64()
        && doc.layers.len() as u64 != n
    {
        problems.push(format!("{} layers, expected {n}", doc.layers.len()));
    }
    if !problems.is_empty() && (doc.size.width, doc.size.height) != (w, h) {
        return Outcome { name, verdict: "FAIL", detail: problems.join("; ") };
    }

    // Pixels, in the document's own mode: grey as grey, CMYK as inks.
    let (target, ours_ch, ref_map): (ColorMode, usize, &[usize]) = match doc.mode {
        ColorMode::Grayscale | ColorMode::Bitmap => (ColorMode::Grayscale, 2, &[0, 3]),
        ColorMode::Cmyk => (ColorMode::Cmyk, 5, &[0, 1, 2, 3, 4]),
        _ => (ColorMode::Rgb, 4, &[0, 1, 2, 3]),
    };
    let surface = photocraft_compose::flatten_to_surface(doc, PixelFormat { mode: target, sample: SampleType::F32, alpha: true }, None);
    let ours = surface.read_region(doc.bounds());
    let ref_ch = s["channels"].as_u64().unwrap_or(4) as usize;
    let reference: Vec<f32> = match std::fs::read(dir.join(s["reference"].as_str().unwrap_or_default())) {
        Ok(b) => b.as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes(*c)).collect(),
        Err(e) => return Outcome { name, verdict: "MISSING", detail: format!("reference: {e}") },
    };
    let n = (w * h) as usize;
    if ours.len() != n * ours_ch || reference.len() != n * ref_ch {
        problems.push(format!("pixel count: ours {}, reference {}", ours.len() / ours_ch.max(1), reference.len() / ref_ch.max(1)));
        return Outcome { name, verdict: "FAIL", detail: problems.join("; ") };
    }
    let (mut max, mut sum, mut count, mut worst) = (0f32, 0f64, 0usize, 0usize);
    for i in 0..n {
        let o = &ours[i * ours_ch..(i + 1) * ours_ch];
        let r = &reference[i * ref_ch..(i + 1) * ref_ch];
        let (oa, ra) = (o[ours_ch - 1], r[ref_ch - 1]);
        for (k, &rk) in ref_map.iter().enumerate() {
            // Colour under transparent pixels is undefined; alpha is always compared.
            if k + 1 < ref_map.len() && ra <= 0.0 && oa <= 0.0 {
                continue;
            }
            // HDR formats keep values above 1: compare relative to the value's size. Colour counts
            // as much as it shows (un-premultiplying a faint pixel magnifies rounding).
            let scale = r[rk].abs().max(1.0);
            let shows = if k + 1 < ref_map.len() { ra.clamp(0.0, 1.0) } else { 1.0 };
            let d = (o[k] - r[rk]).abs() / scale * shows;
            let d = if d.is_nan() { f32::INFINITY } else { d };
            if d > max {
                (max, worst) = (d, i);
            }
            sum += f64::from(d);
            count += 1;
        }
    }
    let mean = (sum / count.max(1) as f64) as f32;
    let (max_ok, mean_ok) = match s["tolerance"].as_str().unwrap_or("exact") {
        "lossy" => (0.25, 0.008),
        "loose" => (0.25, 0.03),
        _ => {
            let levels = match depth {
                8 => 255.0,
                16 => 65535.0,
                _ => 2048.0, // half floats carry 11 significant bits
            };
            (0.51 / levels + 1e-5, 0.51 / levels)
        }
    };
    let stats = format!("max {:.4} mean {:.5}", max, mean);
    if max > max_ok || mean > mean_ok {
        let at = |v: &[f32], ch: usize| v[worst * ch..(worst + 1) * ch].iter().map(|x| format!("{x:.3}")).collect::<Vec<_>>().join(" ");
        problems.push(format!(
            "pixels differ: {stats} (allowed max {max_ok:.4} mean {mean_ok:.5}); worst at ({}, {}): ours [{}], reference [{}]",
            worst % w as usize,
            worst / w as usize,
            at(&ours, ours_ch),
            at(&reference, ref_ch)
        ));
    }
    if problems.is_empty() { Outcome { name, verdict: "PASS", detail: stats } } else { Outcome { name, verdict: "FAIL", detail: problems.join("; ") } }
}

/// Samples that aren't expected to pass yet, and why. Anything else that doesn't pass fails the test;
/// one of these that starts passing is reported, to be taken off the list.
const KNOWN: &[(&str, &str)] = &[
    ("jpeg/arithmetic", "arithmetic coding: zune-jpeg doesn't decode it (iOS opens it with Apple's decoder)"),
    ("jpeg/12bit", "12-bit JPEG: zune-jpeg reads 8-bit only (iOS: Apple's decoder)"),
    ("tiff/rgb8-zstd", "ZSTD TIFF: the tiff crate decodes it only through C libzstd, which would break the wasm build"),
    ("tiff/rgb8-lzma", "LZMA TIFF: no pure-Rust decoder wired in"),
    ("tiff/bilevel-g3", "CCITT Group 3 TIFF: fax34 reads Group 4 only (iOS: Apple's decoder)"),
    ("tiff/bilevel-g4", "1-bit opens as Grayscale; Photoshop opens it as Bitmap"),
    ("pnm/pbm-ascii", "1-bit opens as Grayscale; Photoshop opens it as Bitmap"),
    ("pnm/pbm", "1-bit opens as Grayscale; Photoshop opens it as Bitmap"),
    ("heif/apple", "heic-rs 0.1.4 drops the colour of Apple's 10-bit 4:2:0 HEIC (the app doesn't build it: iOS opens HEIC with Apple's decoder)"),
    ("heif/apple-alpha", "as heif/apple"),
    ("avif/8bit-420", "AVIF decoding isn't built (#463; iOS: Apple's decoder)"),
    ("avif/8bit-444", "AVIF decoding isn't built (#463)"),
    ("avif/10bit", "AVIF decoding isn't built (#463)"),
    ("avif/12bit", "AVIF decoding isn't built (#463)"),
    ("avif/gray-400", "AVIF decoding isn't built (#463)"),
    ("avif/lossless", "AVIF decoding isn't built (#463)"),
    ("avif/alpha", "AVIF decoding isn't built (#463)"),
    ("libtiff/logluv-3c-16b.tiff", "SGI LogLuv isn't decoded"),
    ("libtiff/miniswhite-1c-1b.g3", "a raw Group 3 fax stream, not a TIFF"),
    ("libtiff/ojpeg_chewey_subsamp21_multi_strip.tiff", "old-style JPEG with chroma subsampling: the tiff crate refuses it"),
    ("libtiff/ojpeg_single_strip_no_rowsperstrip.tiff", "old-style JPEG with chroma subsampling"),
    ("libtiff/ojpeg_zackthecat_subsamp22_single_strip.tiff", "old-style JPEG with chroma subsampling"),
    ("libtiff/quad-lzw-compat.tiff", "pre-TIFF 5 'compat' LZW (reversed bit order)"),
    ("libtiff/testfax3_bug54_1dnoEOL.tif", "CCITT Group 3: fax34 reads Group 4 only"),
    ("libtiff/testfax3_bug_513.tiff", "CCITT Group 3"),
    ("libtiff/webp_lossless_rgba_alpha_fully_opaque.tif", "tiff 0.11.3 gives image-webp a 4-channel buffer for RGBA whose WebP has no alpha"),
    ("libjpeg-turbo/monkey12.jpg", "12-bit JPEG (zune-jpeg reads 8-bit only)"),
    ("libjpeg-turbo/testimgari.jpg", "arithmetic-coded JPEG"),
];

#[test]
fn every_format_and_option_matches_its_reference_decoder() {
    let dir = root();
    let manifest: Value = match std::fs::read(dir.join("manifest.json")).map(|b| serde_json::from_slice(&b)) {
        Ok(Ok(v)) => v,
        _ => panic!("corpus/formats/manifest.json is missing: run `python3 -I scripts/format_samples.py`"),
    };
    let samples = manifest["samples"].as_array().cloned().unwrap_or_default();
    let outcomes: Vec<Outcome> = samples.iter().map(|s| check(&dir, s)).collect();
    let mut report = String::from("# Format matrix\n\n| Sample | Result | Detail |\n|---|---|---|\n");
    for o in &outcomes {
        println!("{:8} {:32} {}", o.verdict, o.name, o.detail);
        report.push_str(&format!("| {} | {} | {} |\n", o.name, o.verdict, o.detail.replace('|', "/")));
    }
    let pass = outcomes.iter().filter(|o| o.verdict == "PASS").count();
    println!("{pass} of {} pass", outcomes.len());
    let _ = std::fs::write(dir.join("report.md"), report);
    // JPEG XL is read by the app's bridge with libjxl, not this crate: crates/ffi/src/jxl.rs tests
    // check those samples.
    let known = |n: &str| n.starts_with("jxl") || KNOWN.iter().any(|(k, _)| *k == n);
    let crashes: Vec<&str> = outcomes.iter().filter(|o| o.verdict == "CRASH").map(|o| o.name.as_str()).collect();
    assert!(crashes.is_empty(), "import panicked on {crashes:?}");
    for o in outcomes.iter().filter(|o| o.verdict == "PASS" && known(&o.name)) {
        println!("{} passes now: take it off KNOWN", o.name);
    }
    let unexpected: Vec<String> =
        outcomes.iter().filter(|o| o.verdict != "PASS" && !known(&o.name)).map(|o| format!("{} ({}: {})", o.name, o.verdict, o.detail)).collect();
    assert!(unexpected.is_empty(), "unexpected results:\n{}", unexpected.join("\n"));
}

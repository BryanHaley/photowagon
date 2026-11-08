//! Writes the small files Omega's Files section opens (`OmegaFiles.swift`), all made by our own
//! writers and test generators, none copied from anywhere:
//!
//! ```text
//! cargo run -p photocraft-engine --example make_omega_files -- ios/PhotoWagonUITests/Samples/formats
//! ```
//!
//! The folder is checked in; run this again only to change what's in it.

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::too_many_lines)]

use std::io::Write as _;
use std::path::{Path, PathBuf};

use photocraft_codecs::{DpxBits, ExrCompression, TiffCompression};
use photocraft_engine::Session;
use photocraft_io::ExportOptions;
use photocraft_psd::abr::{AbrSample, LegacyBrush, LegacyTip, write_v6, write_v12};
use photocraft_psd::aco::{AcoColor, AcoSwatch};
use photocraft_psd::ase::{AseColor, AseEntry, AseFile, AseKind, AseSwatch};
use photocraft_psd::atn::{AtnAction, AtnEvent, AtnFile, AtnItem};
use photocraft_psd::descriptor::{Descriptor, Id, ReferenceItem, UnicodeString, Value as D};
use photocraft_psd::grd::{GrdColor, GrdGradient, GrdStop};
use photocraft_psd::patterns::{PsdPattern, write_pat_file};
use photocraft_raw::testgen::{self, Cr2Spec, DngSpec, DngStorage, RafSpec};
use serde_json::{Value, json};

const W: u32 = 64;
const H: u32 = 48;
/// Keeps the repository small.
const MAX_BYTES: usize = 200 * 1024;

struct Out(PathBuf);

impl Out {
    fn put(&self, name: &str, bytes: &[u8]) {
        assert!(bytes.len() < MAX_BYTES, "{name} is {} bytes", bytes.len());
        let path = self.0.join(name);
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).unwrap();
        }
        std::fs::write(&path, bytes).unwrap();
        println!("{name:32} {:7} bytes", bytes.len());
    }
}

/// A step the document may refuse: reported, not fatal, so one change doesn't stop the rest.
fn step(s: &mut Session, id: &str, p: Value) {
    if let Err(e) = s.execute(id, p) {
        println!("  note: {id}: {e}");
    }
}

/// A picture with a gradient, a block and a stroke, so a file that opens blank is easy to see.
fn picture(w: u32, h: u32, mode: &str, depth: u32) -> Session {
    let mut s = Session::new();
    s.execute("file.new", json!({"width": w, "height": h, "name": "omega"})).unwrap();
    step(&mut s, "paint.gradient", json!({"from": [0, 0], "to": [w, h]}));
    step(&mut s, "select.rect", json!({"x": w / 8, "y": h / 8, "width": w / 2, "height": h / 2}));
    step(&mut s, "edit.fill", json!({"color": "#c04020"}));
    step(&mut s, "select.deselect", json!({}));
    step(&mut s, "paint.stroke", json!({"points": [[2, h - 3], [w - 4, 4]], "color": "#2060d0", "size": 5}));
    if mode != "rgb" {
        step(&mut s, &format!("image.mode.{mode}"), json!({}));
    }
    if depth != 8 {
        step(&mut s, &format!("image.mode.bits{depth}"), json!({}));
    }
    // The CMYK profile alone is 240 KB.
    if mode == "cmyk" {
        step(&mut s, "edit.assignProfile", json!({"profile": "none"}));
    }
    s
}

/// Adds a layer of every kind, and the extras a layered file carries.
fn add_every_layer_kind(s: &mut Session) {
    let (w, h) = (W as i32, H as i32);
    step(s, "layer.new.layer", json!({}));
    step(s, "paint.stroke", json!({"points": [[8, 8], [w - 8, h - 8]], "color": "#30a040", "size": 4}));
    step(s, "layer.layerMask.revealAll", json!({}));
    step(s, "layer.layerStyle.replace", json!({"effects": [{"kind": "dropShadow", "params": {}}, {"kind": "stroke", "params": {}}]}));
    step(s, "type.create", json!({"x": 6, "y": h - 8, "text": "Omega", "size": 12}));
    step(s, "shape.create", json!({"kind": "rect", "rect": [10, 10, 20, 14], "fill": "#ff0000"}));
    step(s, "shape.create", json!({"kind": "ellipse", "rect": [30, 10, 20, 14], "fill": "#00a0ff"}));
    step(s, "layer.newFillLayer.solidColor", json!({"color": "#808000"}));
    step(s, "layer.layerStyle.blendingOptions", json!({"opacity": 30}));
    step(s, "layer.newFillLayer.gradient", json!({}));
    step(s, "layer.layerStyle.blendingOptions", json!({"opacity": 30}));
    for adj in [
        "invert",
        "levels",
        "curves",
        "hueSaturation",
        "brightnessContrast",
        "colorBalance",
        "blackWhite",
        "photoFilter",
        "channelMixer",
        "posterize",
        "threshold",
        "selectiveColor",
        "gradientMap",
        "vibrance",
        "exposure",
    ] {
        step(s, &format!("layer.newAdjustmentLayer.{adj}"), json!({}));
        step(s, "layer.layerStyle.blendingOptions", json!({"opacity": 10}));
    }
    step(s, "layer.new.layer", json!({}));
    step(s, "paint.stroke", json!({"points": [[w - 10, 6], [10, h - 6]], "color": "#a030a0", "size": 3}));
    step(s, "layer.groupLayers", json!({}));
    step(s, "layer.new.layer", json!({}));
    step(s, "paint.stroke", json!({"points": [[20, 6], [20, h - 6]], "color": "#f0c000", "size": 3}));
    step(s, "layer.smartObjects.convertToSmartObject", json!({}));
    step(s, "notes.add", json!({"x": 5, "y": 5, "text": "An Omega note"}));
    step(s, "view.newGuide", json!({"orientation": "horizontal", "position": h / 2}));
    step(s, "slice.new", json!({"rect": [4, 4, 20, 20], "name": "omega"}));
    step(s, "select.rect", json!({"x": 12, "y": 12, "width": 24, "height": 16}));
    step(s, "select.saveSelection", json!({"name": "Omega"}));
    step(s, "select.toWorkPath", json!({}));
    step(s, "select.deselect", json!({}));
    step(s, "layerComp.new", json!({"name": "Omega"}));
}

fn export(s: &Session, ext: &str, opts: &ExportOptions) -> Vec<u8> {
    photocraft_io::export(&s.active().unwrap().doc, ext, opts).unwrap_or_else(|e| panic!("{ext}: {e}")).bytes
}

fn with(f: impl FnOnce(&mut ExportOptions)) -> ExportOptions {
    let mut o = ExportOptions::default();
    f(&mut o);
    o
}

fn flat_formats(out: &Out) {
    let rgb8 = picture(W, H, "rgb", 8);
    let rgb16 = picture(W, H, "rgb", 16);
    let rgb32 = picture(W, H, "rgb", 32);
    let gray8 = picture(W, H, "grayscale", 8);
    let gray16 = picture(W, H, "grayscale", 16);
    let cmyk8 = picture(W, H, "cmyk", 8);
    let lab8 = picture(W, H, "lab", 8);

    for (name, s, c) in [
        ("rgb8-none.tif", &rgb8, TiffCompression::None),
        ("rgb8-lzw.tif", &rgb8, TiffCompression::Lzw),
        ("rgb16-deflate.tif", &rgb16, TiffCompression::Deflate),
        ("rgb32-none.tif", &rgb32, TiffCompression::None),
        ("gray8-packbits.tif", &gray8, TiffCompression::PackBits),
        ("gray16-lzw.tif", &gray16, TiffCompression::Lzw),
        ("cmyk8-lzw.tif", &cmyk8, TiffCompression::Lzw),
        ("lab8-deflate.tif", &lab8, TiffCompression::Deflate),
    ] {
        out.put(name, &export(s, "tif", &with(|o| o.encode.tiff_compression = c)));
    }
    out.put("rgb8-bigtiff.tif", &export(&rgb8, "tif", &with(|o| o.encode.tiff_bigtiff = true)));

    for (name, c) in [
        ("rgb32-none.exr", ExrCompression::None),
        ("rgb32-rle.exr", ExrCompression::Rle),
        ("rgb32-zip1.exr", ExrCompression::Zip1),
        ("rgb32-zip16.exr", ExrCompression::Zip16),
        ("rgb32-piz.exr", ExrCompression::Piz),
    ] {
        out.put(name, &export(&rgb32, "exr", &with(|o| o.encode.exr_compression = c)));
    }
    out.put("parts.exr", &exr_with_parts());
    out.put("groups.exr", &exr_with_groups(&["diffuse", "specular"]));
    out.put("aovs.exr", &exr_with_groups(&["directdiffuse", "indirectdiffuse", "directspecular", "indirectspecular", "emission"]));
    out.put("deep-none.exr", &deep_exr(16, 12, 0));
    out.put("deep-rle.exr", &deep_exr(16, 12, 1));
    out.put("deep-zips.exr", &deep_exr(16, 12, 2));

    for (name, bits) in [("rgb-8.dpx", DpxBits::Bits8), ("rgb-10.dpx", DpxBits::Bits10), ("rgb-12.dpx", DpxBits::Bits12), ("rgb-16.dpx", DpxBits::Bits16)] {
        out.put(name, &export(&rgb16, "dpx", &with(|o| o.encode.dpx_bits = Some(bits))));
    }
    out.put("gray-16.dpx", &export(&gray16, "dpx", &ExportOptions::default()));

    for (name, s) in [("rgb8.fits", &rgb8), ("rgb16.fits", &rgb16), ("rgb32.fits", &rgb32), ("gray8.fits", &gray8), ("gray16.fits", &gray16)] {
        out.put(name, &export(s, "fits", &ExportOptions::default()));
    }

    out.put("lossless.webp", &export(&rgb8, "webp", &with(|o| o.encode.webp_lossless = true)));
    for q in [20u8, 80] {
        out.put(
            &format!("lossy-q{q}.webp"),
            &export(
                &rgb8,
                "webp",
                &with(|o| {
                    o.encode.webp_lossless = false;
                    o.encode.webp_quality = q;
                }),
            ),
        );
    }
    let mut cutout = picture(W, H, "rgb", 8);
    step(&mut cutout, "layer.new.layer", json!({}));
    step(&mut cutout, "paint.stroke", json!({"points": [[8, 8], [50, 40]], "color": "#30a040", "size": 9}));
    step(&mut cutout, "select.all", json!({}));
    step(&mut cutout, "layer.mergeDown", json!({}));
    out.put(
        "transparent-lossy.webp",
        &export(
            &cutout,
            "webp",
            &with(|o| {
                o.encode.webp_lossless = false;
                o.encode.webp_quality = 70;
            }),
        ),
    );

    out.put("rgb8.png", &export(&rgb8, "png", &ExportOptions::default()));
    out.put("rgb16-interlaced.png", &export(&rgb16, "png", &with(|o| o.encode.png_interlaced = true)));
    out.put("gray8.jpg", &export(&gray8, "jpg", &ExportOptions::default()));
    out.put("cmyk8.jpg", &export(&cmyk8, "jpg", &ExportOptions::default()));
    for (name, ext, s) in [
        ("rgb8.bmp", "bmp", &rgb8),
        ("rgb8.gif", "gif", &rgb8),
        ("rgb8.tga", "tga", &rgb8),
        ("rgb8.qoi", "qoi", &rgb8),
        ("rgb8.ico", "ico", &rgb8),
        ("rgb32.hdr", "hdr", &rgb32),
        ("rgb8.ppm", "ppm", &rgb8),
        ("gray8.pgm", "pgm", &gray8),
        ("rgb32.pfm", "pfm", &rgb32),
    ] {
        out.put(name, &export(s, ext, &ExportOptions::default()));
    }
}

fn exr_channel(name: &str, v: f32) -> exr::prelude::AnyChannel<exr::prelude::FlatSamples> {
    use exr::prelude::*;
    let samples = (0..16 * 12).map(|i| v * (i % 16) as f32 / 15.0).collect();
    AnyChannel::new(name, FlatSamples::F32(samples))
}

fn exr_image_bytes(layers: Vec<exr::prelude::Layer<exr::prelude::AnyChannels<exr::prelude::FlatSamples>>>) -> Vec<u8> {
    use exr::prelude::*;
    let image = Image::from_layers(ImageAttributes::new(IntegerBounds::new((0, 0), (16usize, 12usize))), layers);
    let mut out = std::io::Cursor::new(Vec::new());
    image.write().to_buffered(&mut out).unwrap();
    out.into_inner()
}

/// Two named parts, as a renderer writes them.
fn exr_with_parts() -> Vec<u8> {
    use exr::prelude::*;
    let layer = |name: &str, list: Vec<AnyChannel<FlatSamples>>| {
        let encoding = Encoding { compression: Compression::ZIP16, blocks: Blocks::ScanLines, line_order: LineOrder::Increasing };
        Layer::new((16usize, 12usize), LayerAttributes::named(name), encoding, AnyChannels::sort(list.into_iter().collect()))
    };
    exr_image_bytes(vec![
        layer("beauty", vec![exr_channel("R", 0.8), exr_channel("G", 0.4), exr_channel("B", 0.2), exr_channel("A", 1.0)]),
        layer("Z", vec![exr_channel("Z", 5.0)]),
    ])
}

/// Render passes as channel groups in one part.
fn exr_with_groups(groups: &[&str]) -> Vec<u8> {
    use exr::prelude::*;
    let mut list: Vec<_> = ["R", "G", "B", "A"].iter().map(|n| exr_channel(n, 0.5)).collect();
    for g in groups {
        list.extend(["R", "G", "B"].iter().map(|c| exr_channel(&format!("{g}.{c}"), 0.3)));
    }
    let encoding = Encoding { compression: Compression::RLE, blocks: Blocks::ScanLines, line_order: LineOrder::Increasing };
    exr_image_bytes(vec![Layer::new((16usize, 12usize), LayerAttributes::default(), encoding, AnyChannels::sort(list.into_iter().collect()))])
}

/// A deep scan-line EXR with one to three samples per pixel; `compression`: 0 none, 1 RLE, 2 ZIPS.
fn deep_exr(w: usize, h: usize, compression: u8) -> Vec<u8> {
    fn attr(out: &mut Vec<u8>, name: &str, ty: &str, payload: &[u8]) {
        out.extend_from_slice(name.as_bytes());
        out.push(0);
        out.extend_from_slice(ty.as_bytes());
        out.push(0);
        out.extend_from_slice(&(payload.len() as i32).to_le_bytes());
        out.extend_from_slice(payload);
    }
    /// The byte split and +128 predictor both RLE and ZIPS store.
    fn predicted(raw: &[u8]) -> Vec<u8> {
        let half = raw.len().div_ceil(2);
        let mut b = vec![0u8; raw.len()];
        for (i, &v) in raw.iter().enumerate() {
            b[if i % 2 == 0 { i / 2 } else { half + i / 2 }] = v;
        }
        let mut prev = 0i16;
        for (i, x) in b.iter_mut().enumerate() {
            let v = i16::from(*x);
            if i > 0 {
                *x = (v - prev + 128) as u8;
            }
            prev = v;
        }
        b
    }
    /// EXR's RLE: a run of n + 1 equal bytes as (n, byte); n literals as (-n, bytes).
    fn rle(b: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut i = 0;
        while i < b.len() {
            let run = b[i..].iter().take(128).take_while(|&&v| v == b[i]).count();
            if run >= 3 {
                out.extend_from_slice(&[(run - 1) as u8, b[i]]);
                i += run;
            } else {
                let mut n = 1;
                while n < 127 && i + n < b.len() && !(i + n + 2 < b.len() && b[i + n] == b[i + n + 1] && b[i + n] == b[i + n + 2]) {
                    n += 1;
                }
                out.push((-(n as i32)) as u8);
                out.extend_from_slice(&b[i..i + n]);
                i += n;
            }
        }
        out
    }
    let pack = |raw: &[u8]| -> Vec<u8> {
        let packed = match compression {
            1 => rle(&predicted(raw)),
            2 => {
                let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
                z.write_all(&predicted(raw)).unwrap();
                z.finish().unwrap()
            }
            _ => raw.to_vec(),
        };
        if packed.len() < raw.len() { packed } else { raw.to_vec() }
    };

    let mut out = 0x0131_2F76u32.to_le_bytes().to_vec();
    out.extend_from_slice(&(2u32 | 0x800).to_le_bytes());
    let mut chlist = Vec::new();
    for name in ["A", "B", "G", "R", "Z"] {
        chlist.extend_from_slice(name.as_bytes());
        chlist.push(0);
        chlist.extend_from_slice(&2i32.to_le_bytes());
        chlist.extend_from_slice(&[0u8; 4]);
        chlist.extend_from_slice(&1i32.to_le_bytes());
        chlist.extend_from_slice(&1i32.to_le_bytes());
    }
    chlist.push(0);
    attr(&mut out, "channels", "chlist", &chlist);
    attr(&mut out, "compression", "compression", &[compression]);
    let window: Vec<u8> = [0i32, 0, w as i32 - 1, h as i32 - 1].iter().flat_map(|v| v.to_le_bytes()).collect();
    attr(&mut out, "dataWindow", "box2i", &window);
    attr(&mut out, "displayWindow", "box2i", &window);
    attr(&mut out, "lineOrder", "lineOrder", &[0]);
    attr(&mut out, "pixelAspectRatio", "float", &1f32.to_le_bytes());
    attr(&mut out, "screenWindowCenter", "v2f", &[0u8; 8]);
    attr(&mut out, "screenWindowWidth", "float", &1f32.to_le_bytes());
    attr(&mut out, "type", "string", b"deepscanline");
    attr(&mut out, "version", "int", &1i32.to_le_bytes());
    out.push(0);

    let count = |x: usize, y: usize| 1 + (x + y) % 3;
    let mut chunks = Vec::new();
    for y in 0..h {
        let mut table = Vec::new();
        let mut total = 0u32;
        for x in 0..w {
            total += count(x, y) as u32;
            table.extend_from_slice(&total.to_le_bytes());
        }
        let mut data = Vec::new();
        for channel in 0..5 {
            for x in 0..w {
                for n in 0..count(x, y) {
                    // Premultiplied colour at half alpha, further samples further away.
                    let v = match channel {
                        0 => 0.5,
                        1 => 0.5 * y as f32 / h as f32,
                        2 => 0.25,
                        3 => 0.5 * x as f32 / w as f32,
                        _ => 1.0 + n as f32,
                    };
                    data.extend_from_slice(&f32::to_le_bytes(v));
                }
            }
        }
        let (ct, cd) = (pack(&table), pack(&data));
        let mut c = (y as i32).to_le_bytes().to_vec();
        c.extend_from_slice(&(ct.len() as u64).to_le_bytes());
        c.extend_from_slice(&(cd.len() as u64).to_le_bytes());
        c.extend_from_slice(&(data.len() as u64).to_le_bytes());
        c.extend_from_slice(&ct);
        c.extend_from_slice(&cd);
        chunks.push(c);
    }
    let mut pos = out.len() + chunks.len() * 8;
    for c in &chunks {
        out.extend_from_slice(&(pos as u64).to_le_bytes());
        pos += c.len();
    }
    for c in chunks {
        out.extend_from_slice(&c);
    }
    out
}

fn layered_formats(out: &Out) {
    let mut every = picture(W, H, "rgb", 8);
    add_every_layer_kind(&mut every);
    out.put("every-layer.psd", &export(&every, "psd", &ExportOptions::default()));
    out.put(
        "every-layer-small.psd",
        &export(
            &every,
            "psd",
            &with(|o| {
                o.image_previews = false;
                o.psd_maximize_compatibility = false;
            }),
        ),
    );
    out.put("every-layer.psb", &export(&every, "psb", &ExportOptions::default()));
    out.put(
        "every-layer.tif",
        &export(
            &every,
            "tif",
            &with(|o| {
                o.tiff_layers = true;
                o.encode.tiff_compression = TiffCompression::Lzw;
            }),
        ),
    );
    out.put("every-layer.ora", &export(&every, "ora", &ExportOptions::default()));
    let opened = every.active().unwrap();
    out.put("every-layer.pcraft", &photocraft_format::save_to_bytes(&opened.doc, &photocraft_format::SaveOptions::default()).unwrap());

    for (mode, depth) in [("cmyk", 8), ("cmyk", 16), ("lab", 16), ("grayscale", 8), ("grayscale", 32), ("rgb", 16), ("rgb", 32)] {
        let mut s = picture(W, H, mode, depth);
        add_every_layer_kind(&mut s);
        out.put(&format!("layers-{mode}{depth}.psd"), &export(&s, "psd", &ExportOptions::default()));
    }
    for mode in ["indexedColor", "bitmap", "duotone", "multichannel"] {
        let mut s = picture(W, H, "grayscale", 8);
        if mode == "indexedColor" {
            s = picture(W, H, "rgb", 8);
        }
        step(&mut s, &format!("image.mode.{mode}"), json!({}));
        out.put(&format!("mode-{mode}.psd"), &export(&s, "psd", &ExportOptions::default()));
    }
    let mut ora = picture(W, H, "rgb", 16);
    step(&mut ora, "layer.new.layer", json!({}));
    step(&mut ora, "paint.stroke", json!({"points": [[4, 4], [60, 44]], "color": "#30a040", "size": 4}));
    step(&mut ora, "layer.layerStyle.blendingOptions", json!({"blend": "multiply"}));
    step(&mut ora, "layer.groupLayers", json!({}));
    out.put("layered16.ora", &export(&ora, "ora", &ExportOptions::default()));

    out.put("shapes.svg", SVG.as_bytes());
}

const SVG: &str = r##"<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="96" height="64" viewBox="0 0 96 64">
  <title>Omega test art</title>
  <defs>
    <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#2060d0"/><stop offset="1" stop-color="#f0e0a0"/>
    </linearGradient>
    <radialGradient id="sun" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#fff0a0"/><stop offset="1" stop-color="#e06010" stop-opacity="0.2"/>
    </radialGradient>
    <clipPath id="box"><rect x="50" y="30" width="36" height="24" rx="4"/></clipPath>
    <g id="dot"><circle r="3" fill="#ffffff"/></g>
  </defs>
  <rect width="96" height="64" fill="url(#sky)"/>
  <g id="Sun" opacity="0.9"><circle cx="24" cy="20" r="14" fill="url(#sun)"/></g>
  <g id="Hills" transform="translate(0 4)">
    <path d="M0 50 C 20 30, 40 30, 60 50 S 90 60, 96 44 L96 64 L0 64 Z" fill="#30a040" stroke="#104020" stroke-width="1.5"/>
    <ellipse cx="70" cy="40" rx="10" ry="5" fill="#208030" fill-opacity="0.6"/>
  </g>
  <g id="Clipped" clip-path="url(#box)"><polygon points="50,30 90,34 70,60" fill="#c04020"/></g>
  <polyline points="4,4 12,10 20,4 28,10" fill="none" stroke="#ffffff" stroke-width="1" stroke-dasharray="2 1"/>
  <line x1="60" y1="6" x2="90" y2="6" stroke="#000000" stroke-linecap="round" stroke-width="2"/>
  <use xlink:href="#dot" x="80" y="16"/>
  <text x="6" y="58" font-family="Helvetica" font-size="8" fill="#000000">Omega</text>
</svg>
"##;

fn raw_formats(out: &Out) {
    let (w, h) = (64, 48);
    let rgb = testgen::scene(w, h);
    let cfa = testgen::mosaic(&rgb, w, [0, 1, 1, 2], 256, 16000);
    let dng = |storage: DngStorage| DngSpec { storage, bits: 16, black: vec![256], white: 16000, ..DngSpec::cfa(w, h, cfa.clone()) };

    out.put("cfa-uncompressed.dng", &dng(DngStorage::Strips { rows: 16 }).build());
    out.put("cfa-ljpeg-strips.dng", &dng(DngStorage::Lj92Strips { rows: 16 }).build());
    out.put("cfa-ljpeg-tiles.dng", &dng(DngStorage::Lj92Tiles { width: 32, height: 24 }).build());
    out.put("cfa-deflate.dng", &dng(DngStorage::DeflateStrips { rows: 16, predictor: 2 }).build());
    out.put(
        "cfa-matrix.dng",
        &DngSpec {
            color_matrix1: Some((21, [0.9, -0.3, -0.1, -0.4, 1.3, 0.1, -0.05, 0.2, 0.6])),
            as_shot_neutral: Some([0.5, 1.0, 0.7]),
            baseline_exposure: Some(0.25),
            orientation: 6,
            active_area: Some([2, 2, 46, 62]),
            opcode_list2: Some(testgen::gain_map_opcode_list([0, 0, h as u32, w as u32], 1, [[1.0, 1.1], [1.1, 1.2]])),
            ..dng(DngStorage::Strips { rows: 48 })
        }
        .build(),
    );
    out.put(
        "cfa-lossy.dng",
        &DngSpec {
            storage: DngStorage::LossyJpegStrips { rows: 16 },
            bits: 8,
            white: 255,
            data: cfa.iter().map(|v| v >> 6).collect(),
            black: vec![1],
            ..DngSpec::cfa(w, h, cfa.clone())
        }
        .build(),
    );
    let gray: Vec<u16> = rgb.iter().map(|p| (p[1] * 60000.0) as u16).collect();
    out.put("mono.dng", &DngSpec::monochrome(w, h, gray).build());
    let linear: Vec<u16> = rgb.iter().flat_map(|p| p.map(|v| (v * 60000.0) as u16)).collect();
    out.put("linear-rgb.dng", &DngSpec { samples: 3, ..DngSpec::cfa(w, h, linear) }.build());

    let (cw, ch) = (56, 44);
    let (l, t) = (8, 4);
    let img = testgen::mosaic(&testgen::scene(cw - l, ch - t), cw - l, [0, 1, 1, 2], 512, 13000);
    let mut sensor = vec![512u16; cw * ch];
    for y in t..ch {
        sensor[y * cw + l..(y + 1) * cw].copy_from_slice(&img[(y - t) * (cw - l)..(y - t + 1) * (cw - l)]);
    }
    out.put(
        "camera.cr2",
        &Cr2Spec {
            width: cw,
            height: ch,
            data: sensor,
            precision: 14,
            components: 2,
            slices: vec![20, 20, 16],
            borders: Some([l as u16, t as u16, cw as u16 - 1, ch as u16 - 1]),
            wb_rggb: Some([2000, 1024, 1024, 1500]),
            orientation: 1,
            model_id: None,
        }
        .build(),
    );
    let m12 = testgen::mosaic(&rgb, w, [0, 1, 1, 2], 128, 4095);
    out.put("camera.rw2", &testgen::rw2(60, 40, &testgen::mosaic(&testgen::scene(60, 40), 60, [0, 1, 1, 2], 128, 4095), 12));
    out.put("camera.orf", &testgen::orf(w, h, &m12));
    out.put("camera.nef", &testgen::tiff_ep("NIKON CORPORATION", w, h, &m12, [2, 1, 1, 0], 12, vec![]));
    out.put("camera.arw", &testgen::sony_craw(64, 32, &testgen::mosaic(&testgen::scene(64, 32), 64, [0, 1, 1, 2], 256, 1900), [8000, 10400, 12900, 14100]));
    const XTRANS: [u8; 36] = [1, 1, 0, 1, 1, 2, 1, 1, 2, 1, 1, 0, 2, 0, 1, 0, 2, 1, 1, 1, 2, 1, 1, 0, 1, 1, 0, 1, 1, 2, 0, 2, 1, 2, 0, 1];
    out.put("xtrans.raf", &RafSpec::new(48, 36, testgen::mosaic_cfa(&testgen::scene(48, 36), 48, &XTRANS, 6, 256, 16383), XTRANS.to_vec()).build());
}

fn presets(out: &Out) {
    let grad = |name: &str, stops: Vec<(f32, GrdColor)>| GrdGradient {
        name: name.into(),
        noise: false,
        stops: stops.into_iter().map(|(location, color)| GrdStop { location, midpoint: 0.5, color }).collect(),
        opacity: vec![(0.0, 1.0, 0.5), (0.6, 0.4, 0.5), (1.0, 1.0, 0.5)],
    };
    out.put(
        "gradients.grd",
        &photocraft_psd::grd::write(&[
            grad("RGB", vec![(0.0, GrdColor::Rgb([1.0, 0.2, 0.1])), (1.0, GrdColor::Rgb([0.1, 0.2, 1.0]))]),
            grad("HSB", vec![(0.0, GrdColor::Hsb([30.0, 1.0, 1.0])), (0.5, GrdColor::Hsb([200.0, 0.5, 0.8])), (1.0, GrdColor::Hsb([300.0, 1.0, 0.5]))]),
            grad("CMYK", vec![(0.0, GrdColor::Cmyk([1.0, 0.0, 0.0, 0.0])), (1.0, GrdColor::Cmyk([0.0, 1.0, 1.0, 0.1]))]),
            grad("Lab", vec![(0.0, GrdColor::Lab([30.0, 40.0, -20.0])), (1.0, GrdColor::Lab([90.0, -10.0, 60.0]))]),
            grad("Gray", vec![(0.0, GrdColor::Gray(0.0)), (1.0, GrdColor::Gray(1.0))]),
            grad("Foreground", vec![(0.0, GrdColor::Foreground), (1.0, GrdColor::Rgb([1.0, 1.0, 1.0]))]),
            GrdGradient { name: "Noise".into(), noise: true, ..Default::default() },
        ]),
    );

    let swatch = |name: &str, color: AcoColor| AcoSwatch { name: name.into(), color };
    out.put(
        "swatches.aco",
        &photocraft_psd::aco::write(&[
            swatch("Red", AcoColor::Rgb([65535, 0, 0])),
            swatch("Orange (HSB)", AcoColor::Hsb([5000, 65535, 65535])),
            swatch("Cyan ink", AcoColor::Cmyk([65535, 0, 0, 0])),
            swatch("Lab", AcoColor::Lab { l: 5000, a: 2000, b: -3000 }),
            swatch("Gray", AcoColor::Gray(5000)),
        ])
        .unwrap(),
    );
    let ase = |name: &str, color: AseColor, kind: AseKind| AseSwatch { name: name.into(), color, kind };
    out.put(
        "swatches.ase",
        &photocraft_psd::ase::write(&AseFile {
            entries: vec![
                AseEntry::Swatch(ase("Red", AseColor::Rgb([1.0, 0.0, 0.0]), AseKind::Process)),
                AseEntry::Group {
                    name: "Inks".into(),
                    swatches: vec![
                        ase("Cyan", AseColor::Cmyk([1.0, 0.0, 0.0, 0.0]), AseKind::Spot),
                        ase("Lab", AseColor::Lab([0.5, 20.0, -30.0]), AseKind::Global),
                        ase("Gray", AseColor::Gray(0.5), AseKind::Process),
                    ],
                },
            ],
        })
        .unwrap(),
    );

    let plane = |w: u32, h: u32, seed: u32| -> Vec<u8> { (0..w * h).map(|i| ((i * 7 + seed * 31) % 251) as u8).collect() };
    let pattern = |name: &str, mode: u32, depth: u16, channels: usize, alpha: bool| {
        let (w, h) = (16, 12);
        let widen = |p: Vec<u8>| if depth == 16 { p.iter().flat_map(|v| [*v, *v]).collect() } else { p };
        PsdPattern {
            mode,
            width: w,
            height: h,
            name: name.into(),
            id: format!("omega-{name}"),
            palette: None,
            depth,
            channels: (0..channels).map(|c| widen(plane(w, h, c as u32))).collect(),
            alpha: alpha.then(|| widen(plane(w, h, 9))),
        }
    };
    out.put(
        "patterns.pat",
        &write_pat_file(&[
            pattern("RGB", 3, 8, 3, true),
            pattern("Gray", 1, 8, 1, false),
            pattern("RGB16", 3, 16, 3, false),
            pattern("CMYK", 4, 8, 4, false),
            pattern("Lab", 9, 8, 3, false),
        ])
        .unwrap(),
    );

    let tip = |id: &str, depth: u16| {
        let (w, h) = (24u32, 24u32);
        let mut data = Vec::new();
        for y in 0..h {
            for x in 0..w {
                let d = ((x as f32 - 12.0).powi(2) + (y as f32 - 12.0).powi(2)).sqrt();
                let v = (255.0 * (1.0 - d / 12.0).clamp(0.0, 1.0)) as u8;
                data.extend(std::iter::repeat_n(v, usize::from(depth / 8)));
            }
        }
        AbrSample { id: id.into(), width: w, height: h, depth, data }
    };
    let legacy = |rle: bool, version: u16| {
        let sampled = if version == 2 { "Sampled" } else { "" };
        write_v12(
            version,
            &[
                LegacyBrush { name: sampled.into(), spacing: 25, anti_alias: true, tip: LegacyTip::Sampled(AbrSample { id: String::new(), ..tip("", 8) }) },
                LegacyBrush {
                    name: String::new(),
                    spacing: 10,
                    anti_alias: true,
                    tip: LegacyTip::Computed { diameter: 19, hardness: 60, angle: 30, roundness: 70 },
                },
            ],
            rle,
        )
        .unwrap()
    };
    out.put("brushes-v1.abr", &legacy(false, 1));
    out.put("brushes-v2.abr", &legacy(true, 2));
    let unit = |v: f64, u: &[u8; 4]| D::UnitFloat { unit: *u, value: v };
    let text = |s: &str| D::Text(UnicodeString::new_nul(s));
    let preset = Descriptor::new("brushPreset")
        .with("Nm  ", text("Omega Sampled"))
        .with(
            "Brsh",
            D::Descriptor(
                Descriptor::new("sampledBrush").with("Dmtr", unit(24.0, b"#Pxl")).with("Spcn", unit(20.0, b"#Prc")).with("sampledData", text("$tip8")),
            ),
        )
        .with("useTipDynamics", D::Boolean(true))
        .with("useScatter", D::Boolean(true))
        .with("dualBrush", D::Descriptor(Descriptor::new("dualBrush").with("useDualBrush", D::Boolean(false))));
    let computed = Descriptor::new("brushPreset").with("Nm  ", text("Omega Computed")).with(
        "Brsh",
        D::Descriptor(
            Descriptor::new("computedBrush")
                .with("Dmtr", unit(30.0, b"#Pxl"))
                .with("Hrdn", unit(50.0, b"#Prc"))
                .with("Angl", unit(45.0, b"#Ang"))
                .with("Rndn", unit(60.0, b"#Prc"))
                .with("Spcn", unit(15.0, b"#Prc")),
        ),
    );
    let sampled16 = Descriptor::new("brushPreset")
        .with("Nm  ", text("Omega 16"))
        .with("Brsh", D::Descriptor(Descriptor::new("sampledBrush").with("sampledData", text("$tip16"))));
    out.put(
        "brushes-v6.abr",
        &write_v6(2, &[tip("$tip8", 8), tip("$tip16", 16)], &[pattern("Grit", 1, 8, 1, false)], &[preset, computed, sampled16], true).unwrap(),
    );

    out.put(
        "contours.shc",
        &photocraft_psd::shc::write(&[photocraft_psd::shc::ShcContour {
            name: "Omega".into(),
            points: vec![
                photocraft_psd::shc::ShcPoint { input: 0.0, output: 0.0, continuous: true },
                photocraft_psd::shc::ShcPoint { input: 128.0, output: 255.0, continuous: false },
                photocraft_psd::shc::ShcPoint { input: 255.0, output: 0.0, continuous: true },
            ],
        }])
        .unwrap(),
    );
}

/// A file of many one-step actions (each named after its command), so playing one that a document
/// refuses doesn't stop the rest; and a second file with the kinds of step that aren't commands.
fn actions(out: &Out) {
    let mut s = Session::new();
    s.execute("file.new", json!({"width": 32, "height": 24})).unwrap();
    let wanted = |id: &str| {
        [
            "filter.",
            "image.adjustments.",
            "layer.newAdjustmentLayer.",
            "layer.newFillLayer.",
            "select.",
            "layer.new.",
            "image.rotate",
            "image.imageSize",
            "image.canvasSize",
            "image.trim",
            "image.crop",
        ]
        .iter()
        .any(|p| id.starts_with(p))
    };
    let ids: Vec<&str> = photocraft_engine::commands::command_specs().iter().map(|c| c.id).filter(|id| wanted(id)).collect();
    let extra = [
        ("image.imageSize", json!({"width": 40})),
        ("image.canvasSize", json!({"width": 40, "height": 30})),
        ("select.rect", json!({"x": 2, "y": 2, "width": 10, "height": 10})),
        ("select.modify.feather", json!({"radius": 2})),
        ("edit.fill", json!({"color": "#808080"})),
        ("layer.duplicate", json!({})),
        ("layer.renameLayer", json!({"name": "Renamed"})),
        ("layer.layerStyle.blendingOptions", json!({"opacity": 50})),
        ("layer.layerStyle.blendingOptions", json!({"blend": "multiply"})),
        ("layer.flattenImage", json!({})),
        ("layer.mergeDown", json!({})),
        ("layer.groupLayers", json!({})),
        ("edit.transform", json!({"scaleX": 50, "scaleY": 50})),
        ("edit.transform.flipHorizontal", json!({})),
        ("file.new", json!({"width": 20, "height": 20})),
    ];
    let mut steps: Vec<(String, Value)> = ids.iter().map(|id| ((*id).to_string(), json!({}))).collect();
    steps.extend(extra.iter().map(|(id, p)| ((*id).to_string(), p.clone())));
    let mut made = 0;
    for (n, (id, params)) in steps.into_iter().enumerate() {
        let name = format!("{id} #{n}");
        s.execute("actions.record", json!({"name": name})).unwrap();
        let ran = s.execute(&id, params).is_ok();
        s.execute("actions.stop", json!({})).unwrap();
        if ran {
            made += 1;
        } else {
            s.execute("actions.delete", json!({"action": name})).unwrap();
        }
        // Back to a plain document for the next one.
        let _ = s.execute("file.closeAll", json!({}));
        s.execute("file.new", json!({"width": 32, "height": 24})).unwrap();
    }
    let saved = s.execute("actions.save", json!({"skipUnsupported": true})).unwrap();
    println!("  actions: {made} recorded, {} steps saved, {} skipped", saved["steps"], saved["skipped"].as_array().map_or(0, Vec::len));
    let data = saved["data"].as_str().unwrap();
    out.put("many-steps.atn", &photocraft_paint::tile::b64_decode(data).unwrap());

    let d = |class: &str| Descriptor::new(class);
    let item = |event: AtnEvent, label: &str, desc: Option<Descriptor>| AtnItem { event, dictionary: label.into(), descriptor: desc, ..Default::default() };
    let code = |c: &[u8; 4]| AtnEvent::Code(*c);
    let stop = d("null").with("Msge", D::Text(UnicodeString::new_nul("Check the result"))).with("Cntn", D::Boolean(true));
    let tool = d("null").with(
        "null",
        D::Reference(vec![ReferenceItem::Class(photocraft_psd::descriptor::Class { name: UnicodeString::new_nul(""), class_id: Id::new("MvTl") })]),
    );
    let odd = AtnFile {
        name: UnicodeString::new_nul("Odd Steps"),
        expanded: true,
        actions: vec![AtnAction {
            name: UnicodeString::new_nul("Odd"),
            function_key: 3,
            items: vec![
                item(AtnEvent::Name("stop".into()), "Stop", Some(stop)),
                item(code(b"slct"), "Select", Some(tool)),
                item(AtnEvent::Name("syntheticFill".into()), "Generative Fill", Some(d("null").with("prompt", D::Text(UnicodeString::new_nul("a cat"))))),
                AtnItem { enabled: false, ..item(code(b"Fltn"), "Flatten Image", None) },
                AtnItem { with_dialog: true, dialog_options: 2, ..item(code(b"Invs"), "Inverse", None) },
            ],
            ..Default::default()
        }],
        warnings: Vec::new(),
    };
    out.put("odd-steps.atn", &photocraft_psd::atn::write(&odd).unwrap());
}

/// A filter plug-in, from WebAssembly text: `pc_filter` inverts every sample.
fn plugin(out: &Out) {
    let manifest = r#"{"id":"net.photowagon.omega.invert","name":"Omega Invert","version":"1","kind":"filter","params":{"amount":{"type":"number","min":0,"max":1,"default":0.5}}}"#;
    let src = format!(
        r#"(module
  (memory (export "memory") 1)
  (data (i32.const 16) "{data}")
  (func (export "pc_abi_version") (result i32) (i32.const 1))
  (func (export "pc_manifest") (result i64) (i64.or (i64.shl (i64.const {len}) (i64.const 32)) (i64.const 16)))
  (func (export "pc_alloc") (param $n i32) (result i32) (local $old i32)
    (local.set $old (memory.grow (i32.shr_u (i32.add (local.get $n) (i32.const 65535)) (i32.const 16))))
    (if (result i32) (i32.eq (local.get $old) (i32.const -1)) (then (i32.const 0)) (else (i32.mul (local.get $old) (i32.const 65536)))))
  (func (export "pc_filter") (param $buf i32) (param $len i32) (param $w i32) (param $h i32)
    (param $ch i32) (param $fmt i32) (param $pp i32) (param $pl i32) (result i32) (local $i i32)
    (block $done (loop $l
      (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
      (f32.store (i32.add (local.get $buf) (local.get $i)) (f32.sub (f32.const 1) (f32.load (i32.add (local.get $buf) (local.get $i)))))
      (local.set $i (i32.add (local.get $i) (i32.const 4)))
      (br $l)))
    (i32.const 0)))"#,
        data = manifest.replace('"', "\\\""),
        len = manifest.len()
    );
    out.put("omega-invert.wasm", &wat::parse_str(src).unwrap());
}

fn inputs(out: &Out) {
    // Notes to import, data sets, footage: a GIF and a folder of frames.
    let mut notes = picture(W, H, "rgb", 8);
    step(&mut notes, "notes.add", json!({"x": 5, "y": 5, "text": "Imported note"}));
    step(&mut notes, "notes.add", json!({"x": 30, "y": 20, "text": "Second note ✓"}));
    out.put("notes.psd", &export(&notes, "psd", &ExportOptions::default()));
    out.put("datasets.csv", b"DataSet,v\nFirst,true\nSecond,false\n");
    for i in 0..4 {
        let mut f = picture(W / 2, H / 2, "rgb", 8);
        step(&mut f, "paint.stroke", json!({"points": [[i * 8, 2], [i * 8, 20]], "color": "#ffffff", "size": 3}));
        out.put(&format!("frames/frame-{i}.png"), &export(&f, "png", &ExportOptions::default()));
    }
    out.put("clip.gif", &gif_clip());
}

/// A three-frame animated GIF, with one palette per frame.
fn gif_clip() -> Vec<u8> {
    use photocraft_codecs::web::{GifFrame, encode_gif_animated};
    let (w, h) = (24u32, 16u32);
    let palette: Vec<[u8; 3]> = (0..4u8).map(|i| [i * 80, 200 - i * 50, i * 30]).collect();
    let frames: Vec<GifFrame> = (0..3u32)
        .map(|n| GifFrame { indices: (0..w * h).map(|i| (((i % w) / 6 + n) % 4) as u8).collect(), palette: palette.clone(), transparent: None, delay_cs: 10 })
        .collect();
    encode_gif_animated(w, h, &frames, true).unwrap()
}

fn main() {
    let dir = std::env::args().nth(1).unwrap_or_else(|| "ios/PhotoWagonUITests/Samples/formats".into());
    let out = Out(Path::new(&dir).to_path_buf());
    std::fs::create_dir_all(&out.0).unwrap();
    flat_formats(&out);
    layered_formats(&out);
    raw_formats(&out);
    presets(&out);
    actions(&out);
    plugin(&out);
    inputs(&out);
}

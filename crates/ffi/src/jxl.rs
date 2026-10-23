//! JPEG XL files through libjxl (built from `submodules/libjxl` with the wrapper in `jxl.cpp`).
//!
//! Opening: gray, RGB or CMYK at the file's depth (8-bit, 16-bit, or 32-bit float for floats and
//! integers past 16 bits), alpha, the colour profile, EXIF and XMP. A still made of layers opens
//! with its layers (position, name, blend mode); an animation with a layer per frame and its
//! timeline, as an animated GIF does. Extra channels besides the alpha and black (depth, masks, a
//! second alpha…) open as alpha channels.
//!
//! Saving: the flattened image, lossless or lossy (a quality 0–100), with an effort; gray, RGB or
//! CMYK, 8-bit, 16-bit or float, alpha, the profile, EXIF and XMP. libjxl's lossy encoder fails
//! on NaN and infinite samples, so floats are made finite first.

use std::ffi::{c_char, c_int, c_uint, c_ulonglong, c_void};

use photocraft_codecs::{ChannelLayout, Image, SampleType};
use photocraft_color::{BlendMode, ColorMode, PixelFormat};
use photocraft_doc::{AlphaChannel, Document, LayerContent};
use photocraft_geom::Rect;
use photocraft_raster::Surface;

#[repr(C)]
struct PcJxlFrame {
    data: *mut u8,
    x0: c_uint,
    y0: c_uint,
    w: c_uint,
    h: c_uint,
    blend: c_uint,
    duration_ms: c_uint,
    name: *mut c_char,
}

#[repr(C)]
struct PcJxlExtra {
    data: *mut u8,
    kind: c_uint,
    name: *mut c_char,
}

#[repr(C)]
struct PcJxl {
    width: c_uint,
    height: c_uint,
    channels: c_uint,
    cmyk: c_uint,
    bytes: c_uint,
    animation: c_uint,
    loops: c_uint,
    frame_count: c_uint,
    frames: *mut PcJxlFrame,
    extra_count: c_uint,
    extras: *mut PcJxlExtra,
    icc: *mut u8,
    icc_len: usize,
    exif: *mut u8,
    exif_len: usize,
    xmp: *mut u8,
    xmp_len: usize,
}

#[repr(C)]
struct PcJxlLayer {
    pixels: *const c_void,
    x0: c_uint,
    y0: c_uint,
    w: c_uint,
    h: c_uint,
    name: *const c_char,
}

#[repr(C)]
struct PcJxlChannel {
    pixels: *const c_void,
    name: *const c_char,
}

#[repr(C)]
struct PcJxlEncode {
    pixels: *const c_void,
    extras: *const PcJxlChannel,
    extra_count: c_uint,
    layers: *const PcJxlLayer,
    layer_count: c_uint,
    width: c_uint,
    height: c_uint,
    channels: c_uint,
    cmyk: c_uint,
    bytes: c_uint,
    icc: *const u8,
    icc_len: usize,
    exif: *const u8,
    exif_len: usize,
    xmp: *const u8,
    xmp_len: usize,
    lossless: c_uint,
    quality: f32,
    effort: c_uint,
}

#[allow(unsafe_code)]
unsafe extern "C" {
    fn pc_jxl_decode(data: *const c_void, len: usize, max_pixels: c_ulonglong, out: *mut PcJxl, error: *mut c_char, error_len: usize) -> c_int;
    fn pc_jxl_release(out: *mut PcJxl);
    fn pc_jxl_encode(input: *const PcJxlEncode, out: *mut *mut u8, out_len: *mut usize, error: *mut c_char, error_len: usize) -> c_int;
    fn pc_jxl_free(p: *mut c_void);
}

/// Most pixels a file may have (as the engine's own decoders allow).
const MAX_PIXELS: u64 = 1 << 28;

/// A bare codestream (`FF 0A`) or the ISO BMFF container (`JXL ` signature box).
pub fn is_jxl(b: &[u8]) -> bool {
    b.starts_with(&[0xFF, 0x0A]) || b.starts_with(&[0, 0, 0, 0x0C, b'J', b'X', b'L', b' ', 0x0D, 0x0A, 0x87, 0x0A])
}

struct Frame {
    image: Image,
    x0: i32,
    y0: i32,
    blend: u32,
    duration_ms: u32,
    name: String,
}

struct Decoded {
    width: u32,
    height: u32,
    layout: ChannelLayout,
    sample: SampleType,
    animation: bool,
    loops: u32,
    frames: Vec<Frame>,
    /// Extra channels of the (only) frame: name and samples.
    extras: Vec<(String, Vec<u8>)>,
    icc: Option<Vec<u8>>,
}

/// Names for unnamed extra channels, by libjxl's JxlExtraChannelType.
fn extra_name(kind: u32) -> &'static str {
    match kind {
        0 => "Alpha",
        1 => "Depth",
        3 => "Selection Mask",
        5 => "CFA",
        6 => "Thermal",
        _ => "Channel",
    }
}

#[allow(unsafe_code)]
fn decode_raw(bytes: &[u8]) -> Result<Decoded, String> {
    // SAFETY: zeroed is a valid empty PcJxl (null pointers, zero counts) for the wrapper to fill.
    let mut out: PcJxl = unsafe { std::mem::zeroed() };
    let mut error = [0 as c_char; 256];
    // SAFETY: `bytes`, `out` and `error` outlive the call; the wrapper writes at most
    // `error.len()` bytes into `error` and fills `out` only when it returns 0.
    let rc = unsafe { pc_jxl_decode(bytes.as_ptr().cast(), bytes.len(), MAX_PIXELS, &mut out, error.as_mut_ptr(), error.len()) };
    if rc != 0 {
        return Err(text(&error));
    }
    let result = read_decoded(&out);
    // SAFETY: `out` was filled by the wrapper and is released once, after it was read.
    unsafe { pc_jxl_release(&mut out) };
    result
}

#[allow(unsafe_code)]
fn read_decoded(out: &PcJxl) -> Result<Decoded, String> {
    let layout = match (out.channels, out.cmyk != 0) {
        (1, _) => ChannelLayout::Gray,
        (2, _) => ChannelLayout::GrayA,
        (3, _) => ChannelLayout::Rgb,
        (4, false) => ChannelLayout::Rgba,
        (4, true) => ChannelLayout::Cmyk,
        (5, true) => ChannelLayout::CmykA,
        (c, _) => return Err(format!("{c} channels")),
    };
    let sample = match out.bytes {
        1 => SampleType::U8,
        2 => SampleType::U16,
        _ => SampleType::F32,
    };
    // SAFETY (for every slice below): the wrapper allocated each buffer with exactly the length
    // read here (counts and sizes it reported), and they stay valid until `pc_jxl_release`.
    let bytes = |p: *const u8, n: usize| if p.is_null() || n == 0 { None } else { Some(unsafe { std::slice::from_raw_parts(p, n) }.to_vec()) };
    let string = |p: *const c_char| if p.is_null() { String::new() } else { unsafe { std::ffi::CStr::from_ptr(p) }.to_string_lossy().into_owned() };
    let icc = bytes(out.icc, out.icc_len);
    let exif = bytes(out.exif, out.exif_len);
    let xmp = bytes(out.xmp, out.xmp_len).map(|x| String::from_utf8_lossy(&x).trim_end_matches('\0').to_string());
    let frames_raw: &[PcJxlFrame] = if out.frames.is_null() { &[] } else { unsafe { std::slice::from_raw_parts(out.frames, out.frame_count as usize) } };
    let mut frames = Vec::with_capacity(frames_raw.len());
    for f in frames_raw {
        let n =
            (f.w as usize).checked_mul(f.h as usize).and_then(|p| p.checked_mul(out.channels as usize * out.bytes as usize)).ok_or("the image is too large")?;
        let data = bytes(f.data, n).ok_or("a frame has no pixels")?;
        let mut image = Image::from_raw(f.w, f.h, layout, sample, data).map_err(|e| e.to_string())?;
        image.icc = icc.clone();
        image.meta.exif = exif.clone();
        image.meta.xmp = xmp.clone();
        frames.push(Frame { image, x0: f.x0 as i32, y0: f.y0 as i32, blend: f.blend, duration_ms: f.duration_ms, name: string(f.name) });
    }
    let extras_raw: &[PcJxlExtra] = if out.extras.is_null() { &[] } else { unsafe { std::slice::from_raw_parts(out.extras, out.extra_count as usize) } };
    // The first frame's size (the extra channels are kept for a single full-canvas frame).
    let plane = frames_raw.first().map_or(0, |f| f.w as usize * f.h as usize * out.bytes as usize);
    let extras = extras_raw
        .iter()
        .filter_map(|e| {
            let name = string(e.name);
            Some((if name.is_empty() { extra_name(e.kind).to_string() } else { name }, bytes(e.data, plane)?))
        })
        .collect();
    Ok(Decoded { width: out.width, height: out.height, layout, sample, animation: out.animation != 0, loops: out.loops, frames, extras, icc })
}

/// Opens a JPEG XL file as a document named `name`.
pub fn open(name: &str, bytes: &[u8]) -> Result<Document, String> {
    let d = decode_raw(bytes)?;
    let import = |img: &Image| photocraft_io::import_image(name, img).map(|r| r.document).map_err(|e| e.to_string());
    if d.animation && d.frames.len() > 1 {
        let frames = d.frames.iter().map(|f| Ok((import(&f.image)?, f.duration_ms))).collect::<Result<Vec<_>, String>>()?;
        return photocraft_engine::anim_cmds::document_from_frames(&frames, d.loops).ok_or_else(|| "no frames".into());
    }
    if let [only] = d.frames.as_slice()
        && (only.x0, only.y0, only.image.dimensions()) == (0, 0, (d.width, d.height))
    {
        let mut doc = import(&only.image)?;
        add_extra_channels(&mut doc, &d);
        return Ok(doc);
    }
    // Layers: each on a canvas-sized document of the same kind.
    let blank = Image::from_raw(d.width, d.height, d.layout, d.sample, vec![0; d.width as usize * d.height as usize * d.layout.channels() * d.sample.bytes()])
        .map_err(|e| e.to_string())?;
    let mut blank = blank;
    blank.icc = d.icc.clone();
    blank.meta = d.frames.first().map(|f| f.image.meta.clone()).unwrap_or_default();
    let mut doc = import(&blank)?;
    doc.layers.clear();
    for (i, f) in d.frames.iter().enumerate() {
        let Some(mut layer) = import(&f.image)?.layers.into_iter().next() else { continue };
        layer.name = if f.name.is_empty() { format!("Layer {}", i + 1) } else { f.name.clone() };
        layer.locks = Default::default();
        // JxlBlendMode: 0 replace, 1 add, 2 blend, 3 muladd, 4 mul.
        layer.blend = match f.blend {
            1 => BlendMode::LinearDodge,
            4 => BlendMode::Multiply,
            _ => BlendMode::Normal,
        };
        if let LayerContent::Raster(s) = &mut layer.content
            && (f.x0, f.y0) != (0, 0)
        {
            *s = s.translated(f.x0, f.y0, s.content_bounds());
        }
        doc.layers.push(layer);
    }
    Ok(doc)
}

/// The extra channels as alpha channels (Photoshop's Channels panel).
fn add_extra_channels(doc: &mut Document, d: &Decoded) {
    let r = Rect::new(0, 0, d.width as i32, d.height as i32);
    for (name, data) in &d.extras {
        let values: Vec<f32> = match d.sample {
            SampleType::U8 => data.iter().map(|&v| f32::from(v) / 255.0).collect(),
            SampleType::U16 => data.as_chunks::<2>().0.iter().map(|c| f32::from(u16::from_ne_bytes(*c)) / 65535.0).collect(),
            _ => data.as_chunks::<4>().0.iter().map(|c| f32::from_ne_bytes(*c)).collect(),
        };
        let mut s = Surface::new(PixelFormat::new(ColorMode::Grayscale, doc.depth, false));
        s.write_region(r, &values);
        s.prune();
        doc.channels.push(AlphaChannel::new(name.clone(), s));
    }
}

/// The settings a JPEG XL save takes.
pub struct EncodeOptions {
    pub lossless: bool,
    /// 0–100, mapped to a distance by libjxl (90 is visually lossless, distance 1).
    pub quality: f32,
    /// 1 (fastest) – 10 (smallest).
    pub effort: u32,
}

/// Encodes an image (gray, RGB or CMYK, with or without alpha) as a JPEG XL file, with `extra_channels`
/// (a name and values 0–1, one per pixel) as named extra channels.
pub fn encode(img: &Image, extra_channels: &[(String, Vec<f32>)], opts: &EncodeOptions) -> Result<Vec<u8>, String> {
    encode_with_layers(img, extra_channels, &[], opts)
}

/// A document's alpha channels, for [`encode`].
pub fn alpha_channels(doc: &Document) -> Vec<(String, Vec<f32>)> {
    doc.channels.iter().map(|c| (c.name.clone(), c.surface.read_region(doc.bounds()))).collect()
}

/// libjxl's lossy encoder fails on NaN and infinite samples: floats made finite.
fn finite_samples(img: &Image) -> std::borrow::Cow<'_, [u8]> {
    if img.sample_type() != SampleType::F32 {
        return std::borrow::Cow::Borrowed(img.data());
    }
    let finite = img
        .data()
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|c| {
            let v = f32::from_ne_bytes(*c);
            let v = if v.is_nan() { 0.0 } else { v.clamp(-f32::MAX, f32::MAX) };
            v.to_ne_bytes()
        })
        .collect();
    std::borrow::Cow::Owned(finite)
}

/// [`encode`]; with `layers` (images of `img`'s kind, a position and a name each), those blended in
/// order onto `img`'s canvas instead of `img`'s pixels.
#[allow(unsafe_code)]
fn encode_with_layers(
    img: &Image,
    extra_channels: &[(String, Vec<f32>)],
    layers: &[(&Image, u32, u32, &str)],
    opts: &EncodeOptions,
) -> Result<Vec<u8>, String> {
    let (channels, cmyk) = match img.layout() {
        ChannelLayout::Gray => (1, false),
        ChannelLayout::GrayA => (2, false),
        ChannelLayout::Rgb => (3, false),
        ChannelLayout::Rgba => (4, false),
        ChannelLayout::Cmyk => (4, true),
        ChannelLayout::CmykA => (5, true),
        other => return Err(format!("JPEG XL can't hold {other:?} images")),
    };
    if layers.iter().any(|(l, ..)| (l.layout(), l.sample_type()) != (img.layout(), img.sample_type())) {
        return Err("every layer must have the image's layout and depth".into());
    }
    let pixels = finite_samples(img);
    let layer_pixels: Vec<_> = layers.iter().map(|(l, ..)| finite_samples(l)).collect();
    let names: Vec<std::ffi::CString> = layers.iter().map(|(.., n)| std::ffi::CString::new(n.replace('\0', "")).unwrap_or_default()).collect();
    let pc_layers: Vec<PcJxlLayer> = layers
        .iter()
        .zip(&layer_pixels)
        .zip(&names)
        .map(|(((l, x0, y0, _), px), name)| PcJxlLayer { pixels: px.as_ptr().cast(), x0: *x0, y0: *y0, w: l.width(), h: l.height(), name: name.as_ptr() })
        .collect();
    // Extra channels in the image's sample type.
    let n = img.width() as usize * img.height() as usize;
    let extra_pixels: Vec<Vec<u8>> = extra_channels
        .iter()
        .map(|(_, v)| {
            let v = v.iter().copied().chain(std::iter::repeat(0.0)).take(n);
            match img.sample_type() {
                SampleType::U8 => v.map(|x| (x.clamp(0.0, 1.0) * 255.0).round() as u8).collect(),
                SampleType::U16 => v.flat_map(|x| ((x.clamp(0.0, 1.0) * 65535.0).round() as u16).to_ne_bytes()).collect(),
                _ => v.flat_map(|x| (if x.is_finite() { x } else { 0.0 }).to_ne_bytes()).collect(),
            }
        })
        .collect();
    let extra_names: Vec<std::ffi::CString> = extra_channels.iter().map(|(n, _)| std::ffi::CString::new(n.replace('\0', "")).unwrap_or_default()).collect();
    let pc_extras: Vec<PcJxlChannel> =
        extra_pixels.iter().zip(&extra_names).map(|(p, n)| PcJxlChannel { pixels: p.as_ptr().cast(), name: n.as_ptr() }).collect();
    let exif = img.meta.exif.as_deref().unwrap_or_default();
    let xmp = img.meta.xmp.as_deref().unwrap_or_default().as_bytes();
    let icc = img.icc.as_deref().unwrap_or_default();
    let input = PcJxlEncode {
        pixels: pixels.as_ptr().cast(),
        extras: if pc_extras.is_empty() { std::ptr::null() } else { pc_extras.as_ptr() },
        extra_count: pc_extras.len() as c_uint,
        layers: if pc_layers.is_empty() { std::ptr::null() } else { pc_layers.as_ptr() },
        layer_count: pc_layers.len() as c_uint,
        width: img.width(),
        height: img.height(),
        channels,
        cmyk: c_uint::from(cmyk),
        bytes: img.sample_type().bytes() as c_uint,
        icc: icc.as_ptr(),
        icc_len: icc.len(),
        exif: exif.as_ptr(),
        exif_len: exif.len(),
        xmp: xmp.as_ptr(),
        xmp_len: xmp.len(),
        lossless: c_uint::from(opts.lossless),
        quality: opts.quality.clamp(0.0, 100.0),
        effort: opts.effort.clamp(1, 10),
    };
    let (mut out, mut len) = (std::ptr::null_mut::<u8>(), 0usize);
    let mut error = [0 as c_char; 256];
    // SAFETY: `input` points into buffers (`pixels`, the extra channels' and layers' pixels and
    // names, `icc`, `exif`, `xmp`) that outlive the call, with the lengths given; the wrapper writes the file to `out` /
    // `len` only when it returns 0.
    let rc = unsafe { pc_jxl_encode(&input, &mut out, &mut len, error.as_mut_ptr(), error.len()) };
    if rc != 0 {
        return Err(text(&error));
    }
    // SAFETY: on success `out` holds `len` bytes the wrapper allocated; read once, then freed.
    let file = unsafe { std::slice::from_raw_parts(out, len) }.to_vec();
    // SAFETY: `out` came from the wrapper's allocation and is not used again.
    unsafe { pc_jxl_free(out.cast()) };
    Ok(file)
}

/// A NUL-terminated C string in `buf`.
fn text(buf: &[c_char]) -> String {
    let bytes: Vec<u8> = buf.iter().take_while(|c| **c != 0).map(|c| *c as u8).collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image(w: u32, h: u32, layout: ChannelLayout, sample: SampleType, f: impl Fn(usize) -> f32) -> Image {
        let n = (w * h) as usize * layout.channels();
        let data: Vec<u8> = (0..n)
            .flat_map(|i| match sample {
                SampleType::U8 => vec![(f(i).clamp(0.0, 1.0) * 255.0).round() as u8],
                SampleType::U16 => ((f(i).clamp(0.0, 1.0) * 65535.0).round() as u16).to_ne_bytes().to_vec(),
                _ => f(i).to_ne_bytes().to_vec(),
            })
            .collect();
        Image::from_raw(w, h, layout, sample, data).unwrap()
    }

    fn round_trip(img: &Image, lossless: bool) -> Decoded {
        let file = encode(img, &[], &EncodeOptions { lossless, quality: 90.0, effort: 3 }).unwrap();
        assert!(is_jxl(&file));
        decode_raw(&file).unwrap()
    }

    #[test]
    fn signatures_and_hostile_input() {
        assert!(is_jxl(&[0xFF, 0x0A, 0]) && is_jxl(&[0, 0, 0, 0x0C, b'J', b'X', b'L', b' ', 0x0D, 0x0A, 0x87, 0x0A]));
        assert!(!is_jxl(b"\x89PNG") && !is_jxl(&[]));
        for bad in [&[0xFF, 0x0A][..], &[0xFF, 0x0A, 0xFA, 0x12, 0x34, 0x56][..], &[0u8; 64][..]] {
            assert!(decode_raw(bad).is_err());
        }
        // A real file cut short.
        let file = encode(
            &image(16, 16, ChannelLayout::Rgb, SampleType::U8, |i| (i % 7) as f32 / 7.0),
            &[],
            &EncodeOptions { lossless: true, quality: 90.0, effort: 1 },
        )
        .unwrap();
        assert!(decode_raw(&file[..file.len() / 2]).is_err());
    }

    #[test]
    fn lossless_round_trips_keep_every_sample() {
        for (layout, sample) in [
            (ChannelLayout::Gray, SampleType::U8),
            (ChannelLayout::GrayA, SampleType::U16),
            (ChannelLayout::Rgb, SampleType::U8),
            (ChannelLayout::Rgba, SampleType::U16),
            (ChannelLayout::Rgba, SampleType::F32),
        ] {
            // Floats past 1 (HDR) must survive.
            let img = image(23, 17, layout, sample, |i| ((i * 37) % 101) as f32 / if sample == SampleType::F32 { 25.0 } else { 100.0 });
            let d = round_trip(&img, true);
            assert_eq!((d.layout, d.sample, d.frames.len()), (layout, sample, 1), "{layout:?} {sample:?}");
            assert_eq!(d.frames[0].image.data(), img.data(), "{layout:?} {sample:?}");
        }
    }

    #[test]
    fn cmyk_round_trips_as_ink_with_its_profile() {
        let profile = photocraft_cms::synth::cmyk_profile(&Default::default()).to_bytes();
        let mut img = image(9, 7, ChannelLayout::CmykA, SampleType::U8, |i| ((i * 13) % 255) as f32 / 255.0);
        img.icc = Some(profile.to_vec());
        let d = round_trip(&img, true);
        assert_eq!(d.layout, ChannelLayout::CmykA);
        assert_eq!(d.frames[0].image.data(), img.data(), "ink amounts, alpha last");
        assert!(d.icc.is_some());
    }

    #[test]
    fn lossy_floats_with_nan_and_infinity_still_encode() {
        let img = image(32, 32, ChannelLayout::Rgb, SampleType::F32, |i| match i % 50 {
            0 => f32::NAN,
            1 => f32::INFINITY,
            2 => f32::NEG_INFINITY,
            _ => (i % 17) as f32 / 17.0,
        });
        let d = round_trip(&img, false);
        let px = d.frames[0].image.data().as_chunks::<4>().0.iter().map(|c| f32::from_ne_bytes(*c)).collect::<Vec<_>>();
        assert!(px.iter().all(|v| v.is_finite()));
    }

    #[test]
    fn layers_open_as_layers_in_place_with_their_names() {
        let canvas = image(40, 30, ChannelLayout::Rgba, SampleType::U8, |i| if i % 4 == 3 { 1.0 } else { 0.25 });
        let top = image(10, 6, ChannelLayout::Rgba, SampleType::U8, |i| {
            if i % 4 == 0 {
                1.0
            } else if i % 4 == 3 {
                0.5
            } else {
                0.0
            }
        });
        let file = encode_with_layers(
            &canvas,
            &[],
            &[(&canvas, 0, 0, "Paper"), (&top, 12, 9, "Red Note")],
            &EncodeOptions { lossless: true, quality: 100.0, effort: 3 },
        )
        .unwrap();
        let doc = open("layers.jxl", &file).unwrap();
        assert_eq!((doc.size.width, doc.size.height), (40, 30));
        assert_eq!(doc.layers.iter().map(|l| l.name.as_str()).collect::<Vec<_>>(), ["Paper", "Red Note"]);
        let LayerContent::Raster(s) = &doc.layers[1].content else { panic!("a pixel layer") };
        assert_eq!(s.content_bounds(), Rect::new(12, 9, 22, 15), "in place");
        assert_eq!(doc.layers[1].blend, BlendMode::Normal);
        // The composite matches libjxl's own blending.
        let ours = photocraft_compose::flatten_to_surface(&doc, PixelFormat::new(ColorMode::Rgb, photocraft_color::SampleType::F32, true), None)
            .read_region(doc.bounds());
        let at = |x: usize, y: usize| ours[(y * 40 + x) * 4..(y * 40 + x) * 4 + 4].to_vec();
        assert!((at(15, 10)[0] - (0.5 + 0.25 * 0.5)).abs() < 0.01, "red over the paper at half alpha: {:?}", at(15, 10));
        assert!((at(2, 2)[0] - 0.25).abs() < 0.01);
    }

    #[test]
    fn alpha_channels_save_and_open_as_named_channels() {
        let img = image(20, 10, ChannelLayout::Rgb, SampleType::U16, |i| (i % 9) as f32 / 9.0);
        let mask: Vec<f32> = (0..200).map(|i| if i % 20 < 10 { 1.0 } else { 0.0 }).collect();
        let file = encode(&img, &[("Sky".into(), mask.clone())], &EncodeOptions { lossless: true, quality: 100.0, effort: 3 }).unwrap();
        let doc = open("channels.jxl", &file).unwrap();
        assert_eq!(doc.channels.len(), 1);
        assert_eq!(doc.channels[0].name, "Sky");
        assert_eq!(doc.channels[0].surface.read_region(doc.bounds()), mask, "the mask's values");
        assert!(alpha_channels(&doc) == vec![("Sky".to_string(), mask)]);
    }

    #[test]
    fn exif_and_xmp_come_back() {
        let mut img = image(8, 8, ChannelLayout::Rgb, SampleType::U8, |_| 0.5);
        let exif = b"MM\0*\0\0\0\x08\0\0\0\0\0\0".to_vec();
        img.meta.exif = Some(exif.clone());
        img.meta.xmp = Some("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".into());
        let d = round_trip(&img, false);
        assert_eq!(d.frames[0].image.meta.exif.as_deref(), Some(&exif[..]));
        assert_eq!(d.frames[0].image.meta.xmp.as_deref(), img.meta.xmp.as_deref());
    }

    /// Every JPEG XL sample in corpus/formats (scripts/format_samples.py: our own and the JPEG XL
    /// conformance inputs) opened as a document and flattened, against djxl's decode. Skips
    /// without the corpus.
    #[test]
    fn opens_the_format_samples_like_djxl() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../corpus/formats");
        let Some(manifest) = std::fs::read(dir.join("manifest.json")).ok().and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok()) else {
            eprintln!("corpus/formats is missing: run `python3 -I scripts/format_samples.py`");
            return;
        };
        let samples: Vec<serde_json::Value> = manifest["samples"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|s| s["format"].as_str().is_some_and(|f| f.starts_with("jxl")))
            .collect();
        assert!(!samples.is_empty());
        let mut failed = Vec::new();
        for s in samples {
            let name = format!("{}/{}", s["format"].as_str().unwrap_or("?"), s["option"].as_str().unwrap_or("?"));
            let bytes = std::fs::read(dir.join(s["file"].as_str().unwrap_or_default())).unwrap();
            let doc = match open("sample.jxl", &bytes) {
                Ok(d) => d,
                Err(e) => {
                    println!("{name}: ERROR {e}");
                    failed.push(name);
                    continue;
                }
            };
            let (w, h) = (s["width"].as_u64().unwrap_or(0) as u32, s["height"].as_u64().unwrap_or(0) as u32);
            if (doc.size.width, doc.size.height) != (w, h) {
                println!("{name}: size {}×{}, expected {w}×{h}", doc.size.width, doc.size.height);
                failed.push(name);
                continue;
            }
            // Official renderings are sRGB: compare the document as shown in sRGB.
            let ours: Vec<f32> = if s["srgb"].as_bool() == Some(true) {
                photocraft_engine::display_color::srgb_thumbnail(&doc, w.max(h)).unwrap().pixels.iter().map(|&v| f32::from(v) / 255.0).collect()
            } else {
                photocraft_compose::flatten_to_surface(&doc, PixelFormat::new(ColorMode::Rgb, photocraft_color::SampleType::F32, true), None)
                    .read_region(doc.bounds())
            };
            let reference: Vec<f32> =
                std::fs::read(dir.join(s["reference"].as_str().unwrap())).unwrap().as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes(*c)).collect();
            let (mut max, mut sum) = (0f32, 0f64);
            for (o, r) in ours.as_chunks::<4>().0.iter().zip(reference.as_chunks::<4>().0) {
                for k in 0..4 {
                    // Colour counts as much as it shows; HDR values relative to their size.
                    let shows = if k < 3 { r[3].clamp(0.0, 1.0) } else { 1.0 };
                    let d = (o[k] - r[k]).abs() / r[k].abs().max(1.0) * shows;
                    max = max.max(d);
                    sum += f64::from(d);
                }
            }
            let mean = sum / (w as f64 * h as f64 * 4.0);
            let (max_ok, mean_ok) = if s["tolerance"] == "exact" { (0.51 / 255.0, 0.002) } else { (0.25, 0.006) };
            let ok = max <= max_ok && mean <= mean_ok;
            println!(
                "{name}: {} {:?} {} layer(s){}, max {max:.4} mean {mean:.5}",
                if ok { "PASS" } else { "FAIL" },
                doc.mode,
                doc.layers.len(),
                if doc.animation.is_some() { " (animation)" } else { "" }
            );
            if !ok {
                failed.push(name);
            }
        }
        assert!(failed.is_empty(), "{failed:?}");
    }
}

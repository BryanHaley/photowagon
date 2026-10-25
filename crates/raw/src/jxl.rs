//! JPEG XL-compressed DNG tiles and strips (Adobe DNG Specification 1.7, Compression 52546).
//!
//! Each strip or tile holds one JPEG XL codestream (bare or in the ISO/IEC 18181-2 container)
//! whose image is the segment's samples: one channel for CFA data, three for LinearRaw. Samsung
//! Expert RAW writes LinearRaw this way. Decoding is done by `jxl-oxide`, a pure-Rust decoder;
//! like heic-rs in `photocraft-heif`, every call into it runs under `catch_unwind` so a decoder
//! panic on a malformed file becomes [`RawError::Malformed`].
//!
//! The browser build (wasm32) leaves the decoder out: jxl-oxide added 0.88 MB to a wasm that
//! must stay under the per-file cap of static hosts (packaging/web/package.sh), for a format only
//! a few phones write. There, these segments are [`RawError::Unsupported`] with a clear message.

#[cfg(not(target_arch = "wasm32"))]
use jxl_oxide::color::{ColourEncoding, ColourSpace, Primaries, TransferFunction, WhitePoint};
#[cfg(not(target_arch = "wasm32"))]
use jxl_oxide::{AllocTracker, EnumColourEncoding, JxlImage, RenderingIntent};

use crate::Limits;
use crate::error::{RawError, Result};

/// The browser build has no JPEG XL decoder (see the module docs).
#[cfg(target_arch = "wasm32")]
pub(crate) fn decode(_src: &[u8], _w: usize, _h: usize, _samples: usize, _limits: &Limits) -> Result<Vec<u16>> {
    Err(RawError::unsupported("JPEG XL-compressed DNG (DNG 1.7) can't be opened in the browser version of PhotoCraft; open it in the desktop app"))
}

/// Decodes one segment into `w * h * samples` interleaved samples, as the codestream stores them.
#[cfg(not(target_arch = "wasm32"))]
pub(crate) fn decode(src: &[u8], w: usize, h: usize, samples: usize, limits: &Limits) -> Result<Vec<u16>> {
    limits.check(w as u64, h as u64, samples as u64 * 2)?;
    // jxl-oxide decodes into wide f32/i32 planes with scratch per group: allow a generous multiple
    // of the output size, and never more than the caller's per-buffer limit.
    let budget = (w as u64).saturating_mul(h as u64).saturating_mul(samples as u64).saturating_mul(64).min(limits.max_alloc);
    let budget = usize::try_from(budget).unwrap_or(usize::MAX);
    guarded(|| {
        // Narrow buffers fail on some Adobe-written tiles whose header claims 16-bit buffers suffice.
        let mut image = JxlImage::builder()
            .alloc_tracker(AllocTracker::with_limit(budget))
            .force_wide_buffers(true)
            .read(src)
            .map_err(|e| RawError::malformed(format!("JPEG XL raw data: {e}")))?;
        let (jw, jh) = (image.width() as usize, image.height() as usize);
        if (jw, jh) != (w, h) {
            return Err(RawError::malformed(format!("JPEG XL raw tile is {jw}x{jh}, expected {w}x{h}")));
        }
        let meta = &image.image_header().metadata;
        let coded = meta.bit_depth.bits_per_sample();
        let lossy = if meta.xyb_encoded { Some(xyb_output(&meta.colour_encoding)?) } else { None };
        if lossy.is_some() {
            // XYB decodes to linear sRGB primaries with no colour conversion (and no gamut mapping,
            // which would pull camera colours towards neutral). Grey stays one channel.
            let mut linear = EnumColourEncoding::srgb_linear(RenderingIntent::Relative);
            if let ColourEncoding::Enum(e) = &meta.colour_encoding {
                linear.colour_space = e.colour_space;
            }
            image.request_color_encoding(linear);
        }
        let render = image.render_frame(0).map_err(|e| RawError::malformed(format!("JPEG XL raw data: {e}")))?;
        let mut stream = render.stream_no_alpha();
        let channels = stream.channels() as usize;
        if channels != samples {
            return Err(RawError::unsupported(format!("JPEG XL raw tile with {channels} channels for {samples} samples per pixel")));
        }
        // Orientation is applied by the stream; DNG tiles are stored upright, so anything else
        // would not fit the tile grid.
        if (stream.width() as usize, stream.height() as usize) != (w, h) {
            return Err(RawError::unsupported("rotated JPEG XL raw tile"));
        }
        let n = w.checked_mul(h).and_then(|p| p.checked_mul(samples)).ok_or_else(|| RawError::malformed("JPEG XL raw tile is too large"))?;
        let max = f32::from(u16::try_from((1u32 << coded.min(16)) - 1).unwrap_or(u16::MAX));
        if let Some(out) = lossy {
            let mut f = vec![0f32; n];
            if stream.write_to_buffer(&mut f) != n {
                return Err(RawError::malformed("JPEG XL raw data is truncated"));
            }
            return Ok(out.samples(&f, samples, max));
        }
        let mut out = vec![0u16; n];
        if stream.write_to_buffer(&mut out) != n {
            return Err(RawError::malformed("JPEG XL raw data is truncated"));
        }
        // Samples come back scaled to 0..=65535 from the codestream's own depth, which can differ
        // from the TIFF's: Apple ProRAW stores 10-bit values in a 16-bit codestream.
        if coded < 16 {
            for v in &mut out {
                *v = (f32::from(*v) * max / 65535.0).round() as u16;
            }
        }
        Ok(out)
    })
}

/// How a lossy (XYB) codestream's linear sRGB output becomes the stored samples: to the declared
/// primaries by a plain matrix, then through the declared curve.
#[cfg(not(target_arch = "wasm32"))]
struct XybOutput {
    to_primaries: Option<[[f32; 3]; 3]>,
    srgb_curve: bool,
}

#[cfg(not(target_arch = "wasm32"))]
fn xyb_output(encoding: &ColourEncoding) -> Result<XybOutput> {
    let unsupported = || RawError::unsupported("lossy JPEG XL raw data in this color encoding");
    let ColourEncoding::Enum(e) = encoding else { return Err(unsupported()) };
    if e.colour_space != ColourSpace::Rgb && e.colour_space != ColourSpace::Grey || e.white_point != WhitePoint::D65 {
        return Err(unsupported());
    }
    // Linear sRGB to linear BT.2020 and to linear Display P3 (ITU-R BT.2087, SMPTE EG 432-1).
    let to_primaries = match e.primaries {
        _ if e.colour_space == ColourSpace::Grey => None,
        Primaries::Srgb => None,
        Primaries::Bt2100 => Some([[0.627_404, 0.329_283, 0.043_313], [0.069_097, 0.919_541, 0.011_362], [0.016_392, 0.088_013, 0.895_595]]),
        Primaries::P3 => Some([[0.822_462, 0.177_538, 0.0], [0.033_194, 0.966_806, 0.0], [0.017_083, 0.072_397, 0.910_520]]),
        Primaries::Custom { .. } => return Err(unsupported()),
    };
    let srgb_curve = match e.tf {
        TransferFunction::Linear => false,
        TransferFunction::Srgb => true,
        _ => return Err(unsupported()),
    };
    Ok(XybOutput { to_primaries, srgb_curve })
}

#[cfg(not(target_arch = "wasm32"))]
impl XybOutput {
    fn samples(&self, f: &[f32], samples: usize, max: f32) -> Vec<u16> {
        let encode = |v: f32| {
            let v = if v.is_finite() { v.clamp(0.0, 1.0) } else { 0.0 };
            let v = if !self.srgb_curve {
                v
            } else if v <= 0.003_130_8 {
                v * 12.92
            } else {
                1.055 * v.powf(1.0 / 2.4) - 0.055
            };
            (v * max).round() as u16
        };
        match (self.to_primaries, samples) {
            (Some(m), 3) => f.as_chunks::<3>().0.iter().flat_map(|p| m.map(|r| encode(r[0] * p[0] + r[1] * p[1] + r[2] * p[2]))).collect(),
            _ => f.iter().map(|&v| encode(v)).collect(),
        }
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn guarded<T>(f: impl FnOnce() -> Result<T>) -> Result<T> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or_else(|_| Err(RawError::malformed("the JPEG XL decoder failed on this file")))
}

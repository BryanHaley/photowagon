//! Colour bitmap glyphs: emoji fonts that store images instead of outlines (Apple Color
//! Emoji's `sbix`, Noto Color Emoji's `CBDT`). Each image is placed on its glyph box and
//! composited in its own colours, never tinted by the text colour. PNG and BGRA images are
//! decoded here; other image formats (iOS stores its emoji in Apple's own `emjc`) are drawn by
//! the app through [`set_color_glyph_source`].

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError, RwLock};

use photocraft_color::{Color, PixelFormat};
use skrifa::bitmap::{BitmapData, BitmapFormat, BitmapGlyph, BitmapStrikes, Origin};
use skrifa::instance::{LocationRef, Size};
use skrifa::raw::TableProvider;
use skrifa::string::StringId;
use skrifa::{FontRef, GlyphId, MetadataProvider};

use crate::raster::Xform;

/// Largest image side we decode (Apple's biggest strike is 160 px; the cap guards hostile data).
const MAX_SIDE: u32 = 2048;
/// Largest size we ask the app to draw a glyph at.
const MAX_REQUEST_PX: f32 = 512.0;

/// A glyph the app is asked to draw (see [`set_color_glyph_source`]).
#[derive(Clone, Debug, PartialEq)]
pub struct ColorGlyphRequest {
    pub postscript_name: String,
    pub family: String,
    pub glyph_id: u32,
    /// Pixels per em.
    pub size_px: f32,
}

/// A glyph image drawn by the app.
#[derive(Clone, Debug, PartialEq)]
pub struct ColorGlyphImage {
    pub width: u32,
    pub height: u32,
    /// Premultiplied RGBA8 (sRGB), rows from the top.
    pub rgba: Vec<u8>,
    /// The image's top-left corner relative to the pen position on the baseline, in pixels at
    /// the requested size: `left` to the right, `top` upwards.
    pub left: f32,
    pub top: f32,
}

/// Draws a colour glyph for [`set_color_glyph_source`].
pub type ColorGlyphSource = Arc<dyn Fn(&ColorGlyphRequest) -> Option<ColorGlyphImage> + Send + Sync>;

static SOURCE: RwLock<Option<ColorGlyphSource>> = RwLock::new(None);
/// Drawn glyphs by PostScript name, glyph id and size.
type Cache = HashMap<(String, u32, u32), Option<Arc<Hosted>>>;
static CACHE: Mutex<Option<Cache>> = Mutex::new(None);
const CACHE_MAX: usize = 1024;

/// Sets (or with `None`, removes) the drawer of colour glyphs whose images aren't PNG.
pub fn set_color_glyph_source(source: Option<ColorGlyphSource>) {
    *SOURCE.write().unwrap_or_else(PoisonError::into_inner) = source;
    *CACHE.lock().unwrap_or_else(PoisonError::into_inner) = None;
}

struct Hosted {
    image: Arc<Image>,
    left: f32,
    top: f32,
    size_px: f32,
}

fn hosted(font: &FontRef, id: u32, ppem: f32) -> Option<Arc<Hosted>> {
    let source = SOURCE.read().unwrap_or_else(PoisonError::into_inner).clone()?;
    let size_px = if ppem.is_finite() { ppem.ceil().clamp(1.0, MAX_REQUEST_PX) } else { 64.0 };
    let name = |id| font.localized_strings(id).english_or_first().map(|s| s.to_string()).unwrap_or_default();
    let postscript_name = name(StringId::POSTSCRIPT_NAME);
    let key = (postscript_name.clone(), id, size_px as u32);
    if let Some(hit) = CACHE.lock().unwrap_or_else(PoisonError::into_inner).as_ref().and_then(|c| c.get(&key)) {
        return hit.clone();
    }
    let req = ColorGlyphRequest { postscript_name, family: name(StringId::FAMILY_NAME), glyph_id: id, size_px };
    let made = source(&req).and_then(|img| {
        let image = Arc::new(from_premultiplied(img.width, img.height, &img.rgba)?);
        (img.left.is_finite() && img.top.is_finite()).then_some(Arc::new(Hosted { image, left: img.left, top: img.top, size_px }))
    });
    let mut cache = CACHE.lock().unwrap_or_else(PoisonError::into_inner);
    let cache = cache.get_or_insert_with(HashMap::new);
    if cache.len() >= CACHE_MAX {
        cache.clear();
    }
    cache.insert(key, made.clone());
    made
}

/// Whether the face stores glyph `id` as an image in its `sbix` table (in any format).
fn in_sbix(font: &FontRef, id: u32) -> bool {
    let Ok(sbix) = font.sbix() else { return false };
    sbix.strikes().iter().any(|s| s.ok().and_then(|s| s.glyph_data(GlyphId::new(id)).ok().flatten()).is_some())
}

/// The colour bitmap for glyph `id` at about `ppem` device pixels per em, if the face has one.
fn glyph<'a>(font: &FontRef<'a>, id: u32, ppem: f32) -> Option<BitmapGlyph<'a>> {
    let strikes = BitmapStrikes::with_format(font, BitmapFormat::Sbix).or_else(|| BitmapStrikes::with_format(font, BitmapFormat::Cbdt))?;
    let size = if ppem.is_finite() && ppem > 0.0 { Size::new(ppem) } else { Size::unscaled() };
    let g = strikes.glyph_for_size(size, GlyphId::new(id))?;
    let ok = matches!(g.data, BitmapData::Png(_) | BitmapData::Bgra(_)) && g.width > 0 && g.height > 0 && g.ppem_x > 0.0 && g.ppem_y > 0.0;
    ok.then_some(g)
}

/// Whether glyph `id` is drawn as a colour image rather than an outline.
pub(crate) fn is_color(font: &FontRef, id: u32, ppem: f32) -> bool {
    glyph(font, id, ppem).is_some() || (SOURCE.read().unwrap_or_else(PoisonError::into_inner).is_some() && in_sbix(font, id))
}

/// A colour glyph image placed in glyph space (font units scaled to the face size, y up).
pub(crate) struct Placed<'a> {
    source: ImageFrom<'a>,
    /// x0, y0 (bottom), x1, y1 (top).
    pub rect: [f64; 4],
    /// The image size the rectangle stands for.
    pub width: u32,
    pub height: u32,
}

enum ImageFrom<'a> {
    Font(BitmapGlyph<'a>),
    App(Arc<Hosted>),
}

impl Placed<'_> {
    /// The decoded image; `None` when it is malformed.
    pub fn image(&self) -> Option<Arc<Image>> {
        match &self.source {
            ImageFrom::Font(g) => decode(g).map(Arc::new),
            ImageFrom::App(h) => Some(h.image.clone()),
        }
    }
}

/// The colour image of glyph `id` for a face of `size_px` drawn at about `ppem` device pixels per em.
pub(crate) fn find<'a>(font: &FontRef<'a>, id: u32, size_px: f32, ppem: f32) -> Option<Placed<'a>> {
    if let Some(g) = glyph(font, id, ppem) {
        let rect = rect(font, &g, size_px)?;
        let (width, height) = (g.width, g.height);
        return Some(Placed { source: ImageFrom::Font(g), rect, width, height });
    }
    if !in_sbix(font, id) {
        return None;
    }
    let h = hosted(font, id, ppem)?;
    let s = f64::from(size_px / h.size_px);
    let (w, ht) = (h.image.width as f64 * s, h.image.height as f64 * s);
    let (x0, y1) = (f64::from(h.left) * s, f64::from(h.top) * s);
    let rect = [x0, y1 - ht, x0 + w, y1];
    let (width, height) = (u32::try_from(h.image.width).ok()?, u32::try_from(h.image.height).ok()?);
    rect.iter().all(|v| v.is_finite()).then_some(Placed { source: ImageFrom::App(h), rect, width, height })
}

/// The image's rectangle in glyph space (font units scaled to `size_px`, y up): x0, y0 (bottom), x1, y1 (top).
fn rect(font: &FontRef, g: &BitmapGlyph, size_px: f32) -> Option<[f64; 4]> {
    let upem = f32::from(font.metrics(Size::unscaled(), LocationRef::default()).units_per_em);
    if upem <= 0.0 {
        return None;
    }
    let fu = size_px / upem;
    let (sx, sy) = (size_px / g.ppem_x, size_px / g.ppem_y);
    let x0 = g.bearing_x * fu + g.inner_bearing_x * sx;
    let edge = g.bearing_y * fu + g.inner_bearing_y * sy;
    let h = g.height as f32 * sy;
    let (y0, y1) = match g.placement_origin {
        Origin::BottomLeft => (edge, edge + h),
        Origin::TopLeft => (edge - h, edge),
    };
    let r = [x0, y0, x0 + g.width as f32 * sx, y1].map(f64::from);
    r.iter().all(|v| v.is_finite()).then_some(r)
}

/// A decoded image: straight RGBA8, row-major from the top.
pub(crate) struct Image {
    pub width: usize,
    pub height: usize,
    pub rgba: Vec<u8>,
}

/// Decodes the glyph's image; `None` for anything malformed or too large.
fn decode(g: &BitmapGlyph) -> Option<Image> {
    if g.width > MAX_SIDE || g.height > MAX_SIDE {
        return None;
    }
    match g.data {
        BitmapData::Png(data) => decode_png(data),
        BitmapData::Bgra(data) => {
            let bgra = from_premultiplied(g.width, g.height, data)?;
            let mut rgba = bgra.rgba;
            for p in rgba.as_chunks_mut::<4>().0 {
                p.swap(0, 2);
            }
            Some(Image { rgba, ..bgra })
        }
        BitmapData::Mask(_) => None,
    }
}

/// Straightens premultiplied 4-channel pixels (channel order kept).
fn from_premultiplied(width: u32, height: u32, data: &[u8]) -> Option<Image> {
    if width == 0 || height == 0 || width > MAX_SIDE || height > MAX_SIDE {
        return None;
    }
    let (w, h) = (width as usize, height as usize);
    let px = data.get(..w.checked_mul(h)?.checked_mul(4)?)?;
    let mut rgba = Vec::with_capacity(px.len());
    for &[r, g, b, a] in px.as_chunks::<4>().0 {
        let un = |v: u8| if a == 0 { 0 } else { ((u32::from(v) * 255 + u32::from(a) / 2) / u32::from(a)).min(255) as u8 };
        rgba.extend_from_slice(&[un(r), un(g), un(b), a]);
    }
    Some(Image { width: w, height: h, rgba })
}

fn decode_png(data: &[u8]) -> Option<Image> {
    let limits = png::Limits { bytes: (MAX_SIDE * MAX_SIDE * 4) as usize };
    let mut dec = png::Decoder::new_with_limits(std::io::Cursor::new(data), limits);
    dec.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = dec.read_info().ok()?;
    let mut buf = vec![0; reader.output_buffer_size()?];
    let info = reader.next_frame(&mut buf).ok()?;
    let (w, h) = (info.width as usize, info.height as usize);
    if w == 0 || h == 0 || info.width > MAX_SIDE || info.height > MAX_SIDE || info.bit_depth != png::BitDepth::Eight {
        return None;
    }
    let ch = match info.color_type {
        png::ColorType::Grayscale => 1,
        png::ColorType::GrayscaleAlpha => 2,
        png::ColorType::Rgb => 3,
        png::ColorType::Rgba => 4,
        png::ColorType::Indexed => return None,
    };
    let mut rgba = Vec::with_capacity(w * h * 4);
    for y in 0..h {
        let row = buf.get(y * info.line_size..)?.get(..w * ch)?;
        for p in row.chunks_exact(ch) {
            rgba.extend_from_slice(&match *p {
                [g] => [g, g, g, 255],
                [g, a] => [g, g, g, a],
                [r, g, b] => [r, g, b, 255],
                [r, g, b, a] => [r, g, b, a],
                _ => return None,
            });
        }
    }
    Some(Image { width: w, height: h, rgba })
}

/// Composites `img` over the premultiplied buffer `acc` (`w × h` pixels, `n` colour channels plus
/// alpha), with `map` taking image pixels (y down from the top) to buffer pixels.
pub(crate) fn composite(acc: &mut [f32], w: usize, h: usize, format: &PixelFormat, img: &Image, map: &Xform) {
    let n = format.mode.color_channels();
    let stride = n + 1;
    let Some(inv) = map.invert() else { return };
    // Premultiplied image in the buffer's colour model.
    let mut src = Vec::with_capacity(img.width * img.height * stride);
    for &[r, g, b, a] in img.rgba.as_chunks::<4>().0 {
        let a = f32::from(a) / 255.0;
        let c = crate::render::color_in(format, &Color::rgb(f32::from(r) / 255.0, f32::from(g) / 255.0, f32::from(b) / 255.0));
        src.extend((0..n).map(|j| c.get(j).copied().unwrap_or(0.0) * a));
        src.push(a);
    }
    let corners = [(0.0, 0.0), (img.width as f64, 0.0), (0.0, img.height as f64), (img.width as f64, img.height as f64)].map(|(x, y)| map.apply(x, y));
    let lo = |f: fn(&(f64, f64)) -> f64, max: usize| corners.iter().map(f).fold(f64::INFINITY, f64::min).floor().clamp(0.0, max as f64) as usize;
    let hi = |f: fn(&(f64, f64)) -> f64, max: usize| corners.iter().map(f).fold(f64::NEG_INFINITY, f64::max).ceil().clamp(0.0, max as f64) as usize;
    let (x0, x1, y0, y1) = (lo(|p| p.0, w), hi(|p| p.0, w), lo(|p| p.1, h), hi(|p| p.1, h));
    // Several samples per pixel when the image shrinks, so it doesn't alias.
    let scale = map.det().abs().sqrt();
    let k = if scale > 0.0 { (1.0 / scale).ceil().clamp(1.0, 8.0) as usize } else { 1 };
    let mut s = vec![0.0f32; stride];
    let mut sum = vec![0.0f32; stride];
    for y in y0..y1 {
        for x in x0..x1 {
            sum.iter_mut().for_each(|v| *v = 0.0);
            for j in 0..k {
                for i in 0..k {
                    let (px, py) = (x as f64 + (i as f64 + 0.5) / k as f64, y as f64 + (j as f64 + 0.5) / k as f64);
                    let (u, v) = inv.apply(px, py);
                    bilinear(&src, img.width, img.height, stride, u, v, &mut s);
                    sum.iter_mut().zip(&s).for_each(|(a, b)| *a += b);
                }
            }
            let a = sum[n] / (k * k) as f32;
            if a <= 0.0 {
                continue;
            }
            let Some(dst) = acc.get_mut((y * w + x) * stride..(y * w + x + 1) * stride) else { continue };
            let keep = 1.0 - a.min(1.0);
            for (d, v) in dst.iter_mut().zip(&sum) {
                *d = v / (k * k) as f32 + *d * keep;
            }
        }
    }
}

/// Bilinear sample at image coordinates (`u`, `v`), transparent outside.
fn bilinear(src: &[f32], w: usize, h: usize, stride: usize, u: f64, v: f64, out: &mut [f32]) {
    out.iter_mut().for_each(|o| *o = 0.0);
    let (fx, fy) = (u - 0.5, v - 0.5);
    let (ix, iy) = (fx.floor(), fy.floor());
    let (tx, ty) = ((fx - ix) as f32, (fy - iy) as f32);
    for (dy, wy) in [(0.0, 1.0 - ty), (1.0, ty)] {
        for (dx, wx) in [(0.0, 1.0 - tx), (1.0, tx)] {
            let (sx, sy) = (ix + dx, iy + dy);
            if sx < 0.0 || sy < 0.0 || sx >= w as f64 || sy >= h as f64 {
                continue;
            }
            let i = (sy as usize * w + sx as usize) * stride;
            let Some(p) = src.get(i..i + stride) else { continue };
            for (o, c) in out.iter_mut().zip(p) {
                *o += c * wx * wy;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use photocraft_color::{ColorMode, SampleType};
    use photocraft_doc::TextLayer;
    use photocraft_doc::text::{CharStyle, TextRun};

    const APPLE_EMOJI: &[&str] = &["/System/Library/Fonts/Apple Color Emoji.ttc", "/System/Library/Fonts/CoreAddition/AppleColorEmoji-160px.ttc"];

    fn emoji_engine() -> Option<crate::TextEngine> {
        let path = APPLE_EMOJI.iter().find(|p| std::path::Path::new(p).exists())?;
        let mut e = crate::TextEngine::new();
        e.fonts.load_font_files([std::path::PathBuf::from(path)]);
        Some(e)
    }

    #[test]
    fn emoji_render_in_colour_at_every_depth() {
        let Some(mut e) = emoji_engine() else {
            eprintln!("skipped: Apple Color Emoji isn't installed");
            return;
        };
        let text = "A😀";
        let style = CharStyle { size_pt: 48.0, color: Color::rgb(0.0, 0.0, 0.0), ..Default::default() };
        let layer = TextLayer { runs: vec![TextRun { len: text.len(), style }], text: text.into(), ..Default::default() };
        let layout = e.layout(&layer, 72.0);
        let emoji = layout.glyphs.iter().find(|g| g.x > 0.0).unwrap();
        let font = &layout.faces[emoji.face as usize].font;
        let font = FontRef::from_index(font.data.as_ref(), font.index).unwrap();
        assert!(glyph(&font, emoji.id, 48.0).is_some(), "the emoji should fall back to Apple Color Emoji");

        for format in [PixelFormat::RGBA8, PixelFormat::RGBA16, PixelFormat::RGBA32F, PixelFormat::new(ColorMode::Cmyk, SampleType::U8, true)] {
            let (_, r) = e.render(&layer, 72.0, format);
            let mut rgba = vec![[0u8; 4]; (r.rect.width() * r.rect.height()) as usize];
            r.surface.read_rgba8_into(r.rect, &mut rgba);
            // The grinning face is yellow: bright, saturated pixels that black text colour didn't tint.
            let yellow = rgba.iter().filter(|p| p[3] > 200 && p[0] > 180 && p[1] > 120 && p[2] < 100).count();
            assert!(yellow > 200, "{format:?}: {yellow}");
            // The layer bounds reach past the "A" to cover the emoji's width.
            assert!(r.rect.width() as f32 > 48.0 * 1.4, "{:?}", r.rect);
        }
    }

    #[test]
    fn app_draws_emoji_the_font_stores_in_another_format() {
        // The iOS emoji font from an installed simulator runtime: its images are `emjc`.
        let Some(path) = std::fs::read_dir("/Library/Developer/CoreSimulator/Volumes").ok().and_then(|vols| {
            vols.flatten().find_map(|v| {
                let runtimes = v.path().join("Library/Developer/CoreSimulator/Profiles/Runtimes");
                std::fs::read_dir(runtimes).ok()?.flatten().find_map(|r| {
                    let f = r.path().join("Contents/Resources/RuntimeRoot/System/Library/Fonts/CoreAddition/AppleColorEmoji-160px.ttc");
                    f.exists().then_some(f)
                })
            })
        }) else {
            eprintln!("skipped: no iOS simulator runtime with its emoji font");
            return;
        };
        let mut e = crate::TextEngine::new();
        e.fonts.load_font_files([path]);
        let text = "A😀";
        let style = CharStyle { size_pt: 48.0, color: Color::rgb(0.0, 0.0, 0.0), ..Default::default() };
        let layer = TextLayer { runs: vec![TextRun { len: text.len(), style }], text: text.into(), ..Default::default() };
        let asked = Arc::new(Mutex::new(Vec::new()));
        let log = asked.clone();
        set_color_glyph_source(Some(Arc::new(move |r: &ColorGlyphRequest| {
            log.lock().unwrap().push(r.clone());
            // A half-transparent red square, one em wide, sitting on the baseline.
            let n = r.size_px as u32;
            Some(ColorGlyphImage { width: n, height: n, rgba: [128, 0, 0, 128].repeat((n * n) as usize), left: 0.0, top: r.size_px })
        })));
        let (layout, r) = e.render(&layer, 72.0, PixelFormat::RGBA8);
        set_color_glyph_source(None);
        let asked = asked.lock().unwrap();
        assert!(asked.iter().any(|r| r.family == "Apple Color Emoji" && r.size_px == 48.0), "{asked:?}");
        let (x, y) = (layout.glyphs[1].x as i32 + 24, layout.glyphs[1].y as i32 - 24);
        let mut px = [[0u8; 4]];
        r.surface.read_rgba8_into(photocraft_geom::Rect::new(x, y, x + 1, y + 1), &mut px);
        assert!(px[0][0] > 240 && px[0][1] < 10 && (120..=136).contains(&px[0][3]), "{px:?}");
    }

    fn bitmap(data: BitmapData<'_>, width: u32, height: u32) -> BitmapGlyph<'_> {
        BitmapGlyph {
            data,
            bearing_x: 0.0,
            bearing_y: 0.0,
            inner_bearing_x: 0.0,
            inner_bearing_y: 0.0,
            ppem_x: 20.0,
            ppem_y: 20.0,
            advance: None,
            width,
            height,
            placement_origin: Origin::BottomLeft,
        }
    }

    #[test]
    fn malformed_bitmaps_are_skipped() {
        let png_header = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR\0\0\0\x10\0\0\0\x10\x08\x06\0\0\0";
        for data in [&b""[..], b"not a png", &png_header[..], &png_header[..12]] {
            assert!(decode(&bitmap(BitmapData::Png(data), 16, 16)).is_none());
        }
        assert!(decode(&bitmap(BitmapData::Bgra(&[0; 8]), 16, 16)).is_none());
        assert!(decode(&bitmap(BitmapData::Bgra(&[0; 16]), u32::MAX, u32::MAX)).is_none());
        let px = decode(&bitmap(BitmapData::Bgra(&[0, 0, 128, 128]), 1, 1)).unwrap();
        assert_eq!(px.rgba, [255, 0, 0, 128]);
        // A degenerate placement draws nothing.
        let mut acc = vec![0.0; 4 * 4 * 4];
        composite(&mut acc, 4, 4, &PixelFormat::RGBA8, &px, &Xform([0.0; 6]));
        composite(&mut acc, 4, 4, &PixelFormat::RGBA8, &px, &Xform([f64::NAN, 0.0, 0.0, 1.0, 0.0, 0.0]));
        assert!(acc.iter().all(|v| *v == 0.0));
    }
}

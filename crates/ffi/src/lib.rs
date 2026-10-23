//! The PhotoCraft engine as a Swift API for the iOS app (UniFFI).
//!
//! Most actions go through [`Editor::execute`] with a command id and JSON params, as every other
//! frontend does. The canvas, live strokes, files and a few panel reads have their own calls.
//! Every call returns an error instead of panicking; a panic that escapes anyway is caught and
//! reported, and the document is kept.

#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

mod canvas;
mod jxl;
mod libraw;
mod params;
mod stroke;

pub use params::{FieldKind, ParamField};

use std::panic::AssertUnwindSafe;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use photocraft_doc::{DocId, Document, LayerId};
use photocraft_engine::Session;
use photocraft_engine::print_cmds::Spooler;
use photocraft_geom::Rect;
use photocraft_gpu::viewport::View;
use serde_json::json;

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiError {
    #[error("{message}")]
    Failed { message: String },
    /// The file opened only as a stand-in picture (a camera raw's embedded preview).
    #[error("{message}")]
    PreviewOnly { message: String },
}

impl FfiError {
    fn new(message: impl std::fmt::Display) -> Self {
        Self::Failed { message: message.to_string() }
    }
}

type Result<T> = std::result::Result<T, FfiError>;

/// What the app does for the engine.
#[uniffi::export(with_foreign)]
pub trait Host: Send + Sync {
    /// Show the system print dialog for a print-ready PDF; returns where the job went.
    fn print(&self, pdf: Vec<u8>, title: String) -> String;
}

#[derive(uniffi::Record)]
pub struct DocInfo {
    /// Stays the same for the document's life.
    pub id: u64,
    pub name: String,
    pub width: u32,
    pub height: u32,
    /// Moves on every change.
    pub revision: u64,
    pub can_undo: bool,
    pub can_redo: bool,
    pub has_selection: bool,
}

/// Where the document sits on screen, in screen pixels.
#[derive(uniffi::Record, Clone, Copy)]
pub struct ViewState {
    pub width: u32,
    pub height: u32,
    /// Screen pixels per document pixel.
    pub zoom: f32,
    /// Document point at the centre of the screen.
    pub center_x: f32,
    pub center_y: f32,
    /// Radians, clockwise.
    pub rotation: f32,
    /// Screen pixels per point.
    pub pixels_per_point: f32,
}

impl From<ViewState> for View {
    fn from(v: ViewState) -> Self {
        View { screen: [v.width, v.height], zoom: v.zoom, center: [v.center_x, v.center_y], rotation: v.rotation, pixels_per_point: v.pixels_per_point }
    }
}

#[derive(uniffi::Record, Clone, Copy)]
pub struct Point {
    pub x: f32,
    pub y: f32,
}

/// A touch or pen sample in document pixels.
#[derive(uniffi::Record, Clone, Copy)]
pub struct StrokePoint {
    pub x: f64,
    pub y: f64,
    /// 0..1 (1 for a finger).
    pub pressure: f32,
    /// Degrees -90..90.
    pub tilt_x: f32,
    pub tilt_y: f32,
    /// Barrel rotation in degrees.
    pub rotation: f32,
    pub time_ms: f64,
}

impl From<StrokePoint> for photocraft_paint::StrokePoint {
    fn from(p: StrokePoint) -> Self {
        let mut q = photocraft_paint::StrokePoint::new(p.x, p.y, p.pressure.clamp(0.0, 1.0));
        (q.tilt_x, q.tilt_y, q.rotation, q.time) = (p.tilt_x, p.tilt_y, p.rotation, p.time_ms);
        q
    }
}

/// Stroke points with the pen pressure through Preferences › `tools.pressureCurve`.
fn shaped(s: &Session, points: Vec<StrokePoint>) -> Vec<photocraft_paint::StrokePoint> {
    let curve = photocraft_engine::prefs::PressureCurve::new(&s.prefs().tools.pressure_curve);
    points
        .into_iter()
        .map(|p| {
            let mut q: photocraft_paint::StrokePoint = p.into();
            if !curve.is_linear() {
                q.pressure = curve.eval(q.pressure).clamp(0.0, 1.0);
            }
            q
        })
        .collect()
}

/// An engine command, for the command search.
#[derive(uniffi::Record)]
pub struct CommandInfo {
    pub id: String,
    pub label: String,
    /// Menu path, `File > Export`; empty when the command has no menu item.
    pub menu: String,
    /// Can run now.
    pub enabled: bool,
    /// Why it can't, when it can't.
    pub reason: Option<String>,
    /// What it takes (the engine's params doc).
    pub params: String,
}

/// A key in effect for a command, tool or held tool: the engine's defaults (Photoshop's) with
/// the user's Edit › Keyboard Shortcuts changes.
#[derive(uniffi::Record)]
pub struct KeyBinding {
    pub id: String,
    pub label: String,
    /// `Cmd+Shift+N` notation (`Cmd`, `Ctrl`, `Alt`, `Shift`, then the key).
    pub shortcut: String,
    /// `command` (run it with `execute`), `shell` (the app carries it out), `tool` or `hold`.
    pub kind: String,
}

/// The current brush and colours.
#[derive(uniffi::Record)]
pub struct ToolSettings {
    pub size: f32,
    pub hardness: f32,
    pub opacity: f32,
    /// RGBA 0..1.
    pub foreground: Vec<f32>,
    pub background: Vec<f32>,
    pub flow: f32,
    /// Smoothing 0..1.
    pub smoothing: f32,
    /// The brush's blend mode, as the engine names it (`Normal`, `Difference`…).
    pub mode: String,
    /// The bar's pressure buttons: pressure sets the size, the opacity.
    pub pressure_size: bool,
    pub pressure_opacity: bool,
    /// Painting erases (the brush as an eraser).
    pub erase: bool,
    /// The front document's painting symmetry (`vertical`, `horizontal`, `dual`, `diagonal`,
    /// `path`), empty when off.
    pub symmetry: String,
    /// Its axes in document pixels, `[x0, y0, x1, y1, …]`.
    pub symmetry_lines: Vec<f64>,
}

/// Screen position of document point (`x`, `y`) in `view`.
/// Longest side [`Editor::render_region`] renders.
pub const MAX_REGION_SIDE: u32 = 512;

#[uniffi::export]
pub fn doc_to_screen(view: ViewState, x: f32, y: f32) -> Point {
    let [x, y] = View::from(view).doc_to_screen([x, y]);
    Point { x, y }
}

/// Document point under screen position (`x`, `y`) in `view`.
#[uniffi::export]
pub fn screen_to_doc(view: ViewState, x: f32, y: f32) -> Point {
    let [x, y] = View::from(view).screen_to_doc([x, y]);
    Point { x, y }
}

/// Adds installed font files (the app lists them; the engine can't scan iOS's font folders).
/// Returns how many were new.
/// The thumbnail stored in a `.pcraft` file (PNG), for file lists.
#[uniffi::export]
pub fn pcraft_thumbnail(bytes: Vec<u8>) -> Option<Vec<u8>> {
    photocraft_format::read_thumbnail(&bytes).ok().flatten()
}

/// Largest file [`unzip`] writes.
const MAX_UNZIP_ENTRY: usize = 1 << 30;

/// Unpacks the zip file at `zip` into the folder `dest` (a downloaded AI model). A name that
/// would land outside `dest` is refused.
#[uniffi::export]
pub fn unzip(zip: String, dest: String) -> Result<()> {
    use std::path::{Component, Path};
    let bytes = std::fs::read(&zip).map_err(FfiError::new)?;
    let reader = photocraft_format::zip::ZipReader::new(&bytes).map_err(FfiError::new)?;
    for e in &reader.entries {
        let rel = Path::new(&e.name);
        if !rel.components().all(|c| matches!(c, Component::Normal(_))) {
            return Err(FfiError::new(format!("`{}` leaves the folder", e.name)));
        }
        let out = Path::new(&dest).join(rel);
        if e.name.ends_with('/') {
            std::fs::create_dir_all(&out).map_err(FfiError::new)?;
            continue;
        }
        if let Some(dir) = out.parent() {
            std::fs::create_dir_all(dir).map_err(FfiError::new)?;
        }
        std::fs::write(&out, reader.read(e, MAX_UNZIP_ENTRY).map_err(FfiError::new)?).map_err(FfiError::new)?;
    }
    Ok(())
}

#[uniffi::export]
pub fn add_fonts(paths: Vec<String>) -> u32 {
    let mut eng = photocraft_text::shared().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    eng.fonts.load_font_files(paths.into_iter().map(std::path::PathBuf::from)) as u32
}

#[derive(uniffi::Object)]
pub struct Editor {
    inner: Mutex<Inner>,
}

struct Inner {
    session: Session,
    canvas: Option<canvas::Canvas>,
    stroke: Option<stroke::Live>,
    preview: Option<Preview>,
    /// Moves when a preview starts or ends, so a late one is dropped.
    preview_gen: u64,
    /// Kept for a canvas made later.
    canvas_color: Vec<f32>,
    /// The document and revision the canvas shows.
    shown: Option<(DocId, u64)>,
    /// The canvas needs a refresh: of `damage`, or everything when that is `None`.
    dirty: bool,
    damage: Option<Rect>,
    /// Selection outline cache: (key, segments in document pixels).
    outline: Option<(u64, Arc<Vec<photocraft_engine::outline::Segment>>)>,
    /// View Mask: the document, revision and layer whose mask the canvas shows, as a picture.
    mask_view: Option<((DocId, u64, LayerId), Arc<Document>)>,
}

/// `doc` with layer `layer`'s mask as its only layer, in gray (what View Mask shows).
fn mask_picture(doc: &Document, layer: LayerId) -> Option<Document> {
    let mask = doc.layer(layer)?.mask.as_ref()?;
    let mut out = doc.clone();
    let mut l = photocraft_doc::Layer::raster("Mask", out.pixel_format());
    *l.surface_mut()? = mask.surface.convert(out.pixel_format());
    out.layers = vec![l];
    Some(out)
}

/// A document shown in place of the real one (Free Transform's live result).
struct Preview {
    doc: Arc<Document>,
    /// Where it differs from the document.
    area: Rect,
    /// Not drawn yet.
    damage: Option<Rect>,
}

#[uniffi::export]
impl Editor {
    #[uniffi::constructor]
    pub fn new(host: Arc<dyn Host>) -> Arc<Self> {
        let mut session = Session::new();
        let run: photocraft_engine::print_cmds::SpoolFn =
            Arc::new(move |job: &photocraft_engine::print_cmds::PrintJob| Ok(host.print(job.pdf.clone(), job.title.clone())));
        session.print_spooler = Some(Spooler { name: "ios", preferred: true, run });
        Arc::new(Self {
            inner: Mutex::new(Inner {
                session,
                canvas: None,
                stroke: None,
                preview: None,
                preview_gen: 0,
                canvas_color: Vec::new(),
                shown: None,
                damage: None,
                dirty: true,
                outline: None,
                mask_view: None,
            }),
        })
    }

    /// Keep user and imported brush presets in `dir` across launches. Returns load warnings.
    pub fn open_presets(&self, dir: String) -> Vec<String> {
        let opened = photocraft_engine::preset_store::open_dir(dir);
        self.lock().session.attach_preset_store(opened)
    }

    /// Run engine command `id` with JSON `params` (empty means `{}`); returns its JSON result.
    pub fn execute(&self, id: String, params: String) -> Result<String> {
        self.with(|inner| {
            let p = if params.trim().is_empty() {
                json!({})
            } else {
                serde_json::from_str(&params).map_err(|e| FfiError::new(format!("params aren't JSON: {e}")))?
            };
            let before = inner.revision();
            let result = inner.session.execute(&id, p).map_err(FfiError::new);
            inner.note_changes(before);
            Ok(result?.to_string())
        })
    }

    /// Open a file's bytes as the document (closing the one open). Unless `allow_preview`, a
    /// file that opens only as a stand-in (a camera raw's embedded preview) fails with
    /// `PreviewOnly`, so the app can try other decoders first.
    pub fn open(&self, name: String, bytes: Vec<u8>, allow_preview: bool) -> Result<DocInfo> {
        self.with(|inner| {
            // An animated GIF opens with its frames (one layer each), ready to play.
            if photocraft_codecs::detect(&bytes) == Some(photocraft_codecs::Format::Gif)
                && let Some(doc) = photocraft_engine::anim_cmds::document_from_gif(&name, &bytes).map_err(FfiError::new)?
            {
                return inner.load(doc);
            }
            // JPEG XL through libjxl: the engine's own decoders don't read it.
            if jxl::is_jxl(&bytes) {
                return inner.load(jxl::open(&name, &bytes).map_err(|e| FfiError::new(format!("JPEG XL: {e}")))?);
            }
            let imported = photocraft_io::import(&name, &bytes).map_err(FfiError::new)?;
            if imported.preview_only && !allow_preview {
                return Err(FfiError::PreviewOnly { message: imported.warnings.first().cloned().unwrap_or_default() });
            }
            inner.load(imported.document)
        })
    }

    /// Open an image another decoder (Core Image, ImageIO) wrote as a TIFF, named after the
    /// original file.
    pub fn open_decoded(&self, name: String, tiff: Vec<u8>) -> Result<DocInfo> {
        self.with(|inner| {
            let mut imported = photocraft_io::import("decoded.tiff", &tiff).map_err(FfiError::new)?;
            imported.document.name = name;
            inner.load(imported.document)
        })
    }

    /// Open a camera raw with LibRaw.
    pub fn open_libraw(&self, name: String, bytes: Vec<u8>) -> Result<DocInfo> {
        self.with(|inner| {
            let dev = libraw::develop(&bytes).map_err(|e| FfiError::new(format!("LibRaw: {e}")))?;
            let from = if dev.camera.is_empty() { String::new() } else { format!(" from {}", dev.camera) };
            let note = format!("developed by LibRaw{from} into 16-bit ProPhoto RGB");
            let imported = photocraft_io::raw::import_developed(&name, dev.width, dev.height, &dev.rgb, &note).map_err(FfiError::new)?;
            inner.load(imported.document)
        })
    }

    /// A new blank document, added to the open ones.
    pub fn new_document(&self, width: u32, height: u32) -> Result<DocInfo> {
        self.with(|inner| {
            inner.stroke = None;
            inner.session.execute("file.new", json!({"width": width, "height": height, "background": "white"})).map_err(FfiError::new)?;
            inner.mark_all_dirty();
            inner.info().ok_or_else(|| FfiError::new("no document"))
        })
    }

    /// The open documents, in tab order.
    pub fn documents(&self) -> Vec<DocInfo> {
        self.with(|inner| {
            let active = inner.session.active_index();
            let mut out = Vec::new();
            for i in 0..inner.session.documents().len() {
                inner.session.set_active(i);
                out.extend(inner.info());
            }
            if let Some(a) = active {
                inner.session.set_active(a);
            }
            Ok(out)
        })
        .unwrap_or_default()
    }

    /// Show open document `index`.
    pub fn activate(&self, index: u32) -> Result<DocInfo> {
        self.with(|inner| {
            inner.end_live_work();
            if !inner.session.set_active(index as usize) {
                return Err(FfiError::new(format!("no document {index}")));
            }
            inner.mark_all_dirty();
            inner.info().ok_or_else(|| FfiError::new("no document"))
        })
    }

    /// Close open document `index` (unsaved changes are lost).
    pub fn close(&self, index: u32) {
        let _ = self.with(|inner| {
            inner.end_live_work();
            inner.session.close(index as usize);
            inner.mark_all_dirty();
            Ok(())
        });
    }

    /// The colour around the image on the canvas, RGB 0..1.
    pub fn set_canvas_color(&self, rgb: Vec<f32>) {
        let _ = self.with(|inner| {
            if let (Some(c), [r, g, b, ..]) = (&mut inner.canvas, rgb.as_slice()) {
                c.background = wgpu::Color { r: f64::from(*r), g: f64::from(*g), b: f64::from(*b), a: 1.0 };
            }
            inner.canvas_color = rgb.clone();
            Ok(())
        });
    }

    /// Name the open document after the file it was saved as (the tab shows it).
    pub fn rename_document(&self, name: String) {
        let _ = self.with(|inner| {
            if let Some(d) = inner.session.active_mut() {
                std::sync::Arc::make_mut(&mut d.doc).name = name;
            }
            Ok(())
        });
    }

    /// The document encoded as `format` (`png`, `jpg`, `psd`, `pcraft`, …); `quality` is JPEG
    /// quality on Photoshop's 0–12 scale.
    pub fn export(&self, format: String, quality: Option<u8>) -> Result<Vec<u8>> {
        self.with(|inner| {
            let doc = inner.doc().ok_or_else(|| FfiError::new("no document is open"))?;
            let ext = format.trim_start_matches('.').to_ascii_lowercase();
            if ext == photocraft_format::EXTENSION {
                let previews = photocraft_format::SaveOptions {
                    thumbnail: Some(photocraft_compose::thumbnail(&doc, 256)),
                    composite: Some(photocraft_compose::thumbnail(&doc, 1024)),
                };
                return photocraft_format::save_to_bytes(&doc, &previews).map_err(FfiError::new);
            }
            if ext == "jxl" {
                return export_jxl(&doc, &jxl::EncodeOptions { lossless: true, quality: 90.0, effort: 7 }, None, false, true);
            }
            let mut opts = photocraft_io::ExportOptions::default();
            if let Some(q) = quality {
                opts.encode.jpeg_quality = (10.0 + f32::from(q.min(12)) * 7.5).round() as u8;
            }
            photocraft_io::export(&doc, &ext, &opts).map(|r| r.bytes).map_err(FfiError::new)
        })
    }

    /// The document as a JPEG XL file: lossless, or lossy at `quality` (0–100), at `effort`
    /// (1–10). For Export As: `width` resizes the copy, `srgb` converts it to sRGB, and without
    /// `transparency` it is composited over white.
    pub fn export_jxl(&self, lossless: bool, quality: u8, effort: u8, width: Option<u32>, srgb: bool, transparency: bool) -> Result<Vec<u8>> {
        self.with(|inner| {
            let doc = inner.doc().ok_or_else(|| FfiError::new("no document is open"))?;
            let opts = jxl::EncodeOptions { lossless, quality: f32::from(quality.min(100)), effort: u32::from(effort) };
            export_jxl(&doc, &opts, width, srgb, transparency)
        })
    }

    pub fn document(&self) -> Option<DocInfo> {
        self.with(|inner| Ok(inner.info())).ok().flatten()
    }

    /// A PNG of layer `layer` alone, at most `max_side` pixels on its long side.
    pub fn layer_thumbnail(&self, layer: u64, max_side: u32) -> Result<Vec<u8>> {
        self.with(|inner| {
            let doc = inner.doc().ok_or_else(|| FfiError::new("no document is open"))?;
            let mut l = doc.layer(LayerId(layer)).ok_or_else(|| FfiError::new(format!("no layer {layer}")))?.clone();
            (l.visible, l.clipped, l.opacity) = (true, false, 1.0);
            let mut alone = (*doc).clone();
            alone.layers = vec![l];
            let img = photocraft_compose::thumbnail(&alone, max_side.clamp(1, 1024));
            let image = photocraft_codecs::Image::from_u8(img.width, img.height, photocraft_codecs::ChannelLayout::Rgba, img.pixels).map_err(FfiError::new)?;
            photocraft_codecs::encode(&image, photocraft_codecs::Format::Png, &Default::default()).map_err(FfiError::new)
        })
    }

    /// A PNG of layer `layer`'s pixel mask over the canvas (white shows, black hides), at most
    /// `max_side` pixels on its long side.
    pub fn layer_mask_thumbnail(&self, layer: u64, max_side: u32) -> Result<Vec<u8>> {
        self.with(|inner| {
            let doc = inner.doc().ok_or_else(|| FfiError::new("no document is open"))?;
            let l = doc.layer(LayerId(layer)).ok_or_else(|| FfiError::new(format!("no layer {layer}")))?;
            let mask = l.mask.as_ref().ok_or_else(|| FfiError::new("the layer has no mask"))?;
            let (cw, ch) = (doc.size.width.max(1), doc.size.height.max(1));
            let scale = (max_side.clamp(1, 1024) as f64 / cw.max(ch) as f64).min(1.0);
            let (w, h) = (((cw as f64 * scale).round() as u32).max(1), ((ch as f64 * scale).round() as u32).max(1));
            let mut pixels = Vec::with_capacity(w as usize * h as usize * 4);
            for y in 0..h {
                for x in 0..w {
                    let (sx, sy) = (((x as f64 + 0.5) / scale) as i32, ((y as f64 + 0.5) / scale) as i32);
                    let v = (mask.surface.sample_channel(sx, sy, 0).clamp(0.0, 1.0) * 255.0).round() as u8;
                    pixels.extend_from_slice(&[v, v, v, 255]);
                }
            }
            let image = photocraft_codecs::Image::from_u8(w, h, photocraft_codecs::ChannelLayout::Rgba, pixels).map_err(FfiError::new)?;
            photocraft_codecs::encode(&image, photocraft_codecs::Format::Png, &Default::default()).map_err(FfiError::new)
        })
    }

    /// The image at most `max_side` pixels on its longer side, in sRGB, as PNG: what a preview
    /// shows (`analysis_image` keeps the document's own colours).
    pub fn preview_image(&self, max_side: u32) -> Result<Vec<u8>> {
        self.with(|inner| {
            let doc = inner.doc().ok_or_else(|| FfiError::new("no document is open"))?;
            let img = photocraft_engine::display_color::srgb_thumbnail(&doc, max_side.clamp(1, 4096)).map_err(FfiError::new)?;
            let image = photocraft_codecs::Image::from_u8(img.width, img.height, photocraft_codecs::ChannelLayout::Rgba, img.pixels).map_err(FfiError::new)?;
            photocraft_codecs::encode(&image, photocraft_codecs::Format::Png, &Default::default()).map_err(FfiError::new)
        })
    }

    /// The image (one layer alone, or every visible layer) at most `max_side` pixels on its
    /// longer side, as PNG, for on-device analysis such as Vision's object masks.
    pub fn analysis_image(&self, layer: Option<u64>, max_side: u32) -> Result<Vec<u8>> {
        self.with(|inner| {
            let doc = inner.doc().ok_or_else(|| FfiError::new("no document is open"))?;
            let mut alone = (*doc).clone();
            if let Some(id) = layer {
                let mut l = doc.layer(LayerId(id)).ok_or_else(|| FfiError::new(format!("no layer {id}")))?.clone();
                (l.visible, l.clipped) = (true, false);
                alone.layers = vec![l];
            }
            let img = photocraft_compose::thumbnail(&alone, max_side.clamp(1, 4096));
            let image = photocraft_codecs::Image::from_u8(img.width, img.height, photocraft_codecs::ChannelLayout::Rgba, img.pixels).map_err(FfiError::new)?;
            photocraft_codecs::encode(&image, photocraft_codecs::Format::Png, &Default::default()).map_err(FfiError::new)
        })
    }

    /// The current brush painting an S across `width`×`height`, pressure rising then falling and
    /// the pen tilting, white on transparent with the brush fitted to the height (Brush Settings'
    /// preview), as a PNG.
    pub fn brush_preview(&self, width: u32, height: u32) -> Result<Vec<u8>> {
        let (w, h) = (width.clamp(16, 2048), height.clamp(16, 1024));
        let mut brush = self.with(|inner| Ok(inner.session.tools.brush.clone()))?;
        brush.size = brush.size.min(h as f32 * 0.4);
        (brush.color, brush.color_cmyk, brush.erase, brush.mode) = ([1.0; 4], None, false, photocraft_color::BlendMode::Normal);
        let n = 120;
        let pts: Vec<_> = (0..=n)
            .map(|i| {
                let t = f64::from(i) / f64::from(n);
                let (x, y) = (f64::from(w) * (0.08 + 0.84 * t), f64::from(h) * (0.5 - 0.28 * (t * std::f64::consts::TAU).sin()));
                let mut p = photocraft_paint::StrokePoint::new(x, y, (t * std::f64::consts::PI).sin() as f32);
                (p.time, p.tilt_x) = (t * 600.0, (t * 60.0 - 30.0) as f32);
                p
            })
            .collect();
        let mut surf = photocraft_raster::Surface::new(photocraft_color::PixelFormat::RGBA8);
        photocraft_paint::render_stroke(&mut surf, &brush, &pts, None, false, 1.0);
        let mut px = vec![[0u8; 4]; (w * h) as usize];
        surf.read_rgba8_into(Rect::from_xywh(0, 0, w, h), &mut px);
        let image = photocraft_codecs::Image::from_u8(w, h, photocraft_codecs::ChannelLayout::Rgba, px.into_iter().flatten().collect()).map_err(FfiError::new)?;
        photocraft_codecs::encode(&image, photocraft_codecs::Format::Png, &Default::default()).map_err(FfiError::new)
    }

    /// The image with layer `hidden` hidden (what an adjustment layer adjusts), as for
    /// [`Self::analysis_image`].
    pub fn analysis_image_below(&self, hidden: u64, max_side: u32) -> Result<Vec<u8>> {
        self.with(|inner| {
            let doc = inner.doc().ok_or_else(|| FfiError::new("no document is open"))?;
            let mut below = (*doc).clone();
            below.layer_mut(LayerId(hidden)).ok_or_else(|| FfiError::new(format!("no layer {hidden}")))?.visible = false;
            let img = photocraft_compose::thumbnail(&below, max_side.clamp(1, 4096));
            let image = photocraft_codecs::Image::from_u8(img.width, img.height, photocraft_codecs::ChannelLayout::Rgba, img.pixels).map_err(FfiError::new)?;
            photocraft_codecs::encode(&image, photocraft_codecs::Format::Png, &Default::default()).map_err(FfiError::new)
        })
    }

    /// Frame `frame` of the frame animation as a PNG at most `max_side` pixels on its longer side
    /// (the Timeline's thumbnails).
    pub fn animation_thumbnail(&self, frame: u32, max_side: u32) -> Result<Vec<u8>> {
        self.with(|inner| {
            let doc = inner.doc().ok_or_else(|| FfiError::new("no document is open"))?;
            let shown = photocraft_engine::anim_cmds::frame_document(&doc, frame as usize).map_err(FfiError::new)?;
            let img = photocraft_compose::thumbnail(&shown, max_side.clamp(1, 4096));
            let image = photocraft_codecs::Image::from_u8(img.width, img.height, photocraft_codecs::ChannelLayout::Rgba, img.pixels).map_err(FfiError::new)?;
            photocraft_codecs::encode(&image, photocraft_codecs::Format::Png, &Default::default()).map_err(FfiError::new)
        })
    }

    /// The selection as a gray PNG (white = selected) the size of [`Self::analysis_image`];
    /// `None` without a selection.
    pub fn selection_image(&self, max_side: u32) -> Result<Option<Vec<u8>>> {
        self.with(|inner| {
            let doc = inner.doc().ok_or_else(|| FfiError::new("no document is open"))?;
            let Some(sel) = doc.selection.as_ref() else { return Ok(None) };
            let (w, h) = photocraft_compose::thumbnail_size(&doc, max_side.clamp(1, 4096));
            let (dw, dh) = (u64::from(doc.size.width), u64::from(doc.size.height));
            let mut px = Vec::with_capacity(w as usize * h as usize);
            for y in 0..h {
                let sy = (u64::from(y) * dh / u64::from(h)) as i32;
                for x in 0..w {
                    let sx = (u64::from(x) * dw / u64::from(w)) as i32;
                    px.push((sel.sample_channel(sx, sy, 0).clamp(0.0, 1.0) * 255.0).round() as u8);
                }
            }
            let image = photocraft_codecs::Image::from_u8(w, h, photocraft_codecs::ChannelLayout::Gray, px).map_err(FfiError::new)?;
            photocraft_codecs::encode(&image, photocraft_codecs::Format::Png, &Default::default()).map(Some).map_err(FfiError::new)
        })
    }

    /// The composite over the document rect `x, y, w, h` as RGBA8, `w`×`h` pixels row by row
    /// (sides capped at [`MAX_REGION_SIDE`]); pixels past the canvas are transparent. For the
    /// canvas loupe.
    pub fn render_region(&self, x: i32, y: i32, w: u32, h: u32) -> Result<Vec<u8>> {
        self.with(|inner| {
            let doc = inner.doc().ok_or_else(|| FfiError::new("no document is open"))?;
            let (w, h) = (w.min(MAX_REGION_SIDE), h.min(MAX_REGION_SIDE));
            let want = Rect::from_xywh(x, y, w, h);
            let mut out = vec![0u8; w as usize * h as usize * 4];
            let r = want.intersect(&doc.bounds());
            if r.is_empty() {
                return Ok(out);
            }
            let img = photocraft_compose::render(&doc, r).to_rgba8();
            let row = r.width() as usize * 4;
            for (i, src) in img.pixels.chunks_exact(row).enumerate() {
                let (dx, dy) = (r.x0.abs_diff(want.x0) as usize, r.y0.abs_diff(want.y0) as usize + i);
                let at = (dy * w as usize + dx) * 4;
                if let Some(dst) = out.get_mut(at..at + row) {
                    dst.copy_from_slice(src);
                }
            }
            Ok(out)
        })
    }

    /// Draw into the `CAMetalLayer` at address `layer`, `width`×`height` pixels. The caller
    /// keeps the layer alive until [`Editor::detach`].
    pub fn attach(&self, layer: u64, width: u32, height: u32) -> Result<()> {
        self.with(|inner| {
            inner.canvas = None;
            let mut canvas = canvas::Canvas::new(layer, width, height).map_err(FfiError::new)?;
            if let [r, g, b, ..] = inner.canvas_color.as_slice() {
                canvas.background = wgpu::Color { r: f64::from(*r), g: f64::from(*g), b: f64::from(*b), a: 1.0 };
            }
            inner.canvas = Some(canvas);
            inner.mark_all_dirty();
            Ok(())
        })
    }

    pub fn resize(&self, width: u32, height: u32) {
        let _ = self.with(|inner| {
            if let Some(c) = &mut inner.canvas {
                c.resize(width, height);
            }
            Ok(())
        });
    }

    pub fn detach(&self) {
        let _ = self.with(|inner| {
            inner.canvas = None;
            Ok(())
        });
    }

    /// Bring the canvas up to date and draw a frame (call once per display refresh).
    pub fn draw(&self, view: ViewState) {
        let _ = self.with(|inner| {
            let before = inner.revision();
            inner.session.poll_jobs();
            inner.note_changes(before);
            inner.refresh_canvas();
            if let Some(c) = &mut inner.canvas {
                c.draw(&view.into());
            }
            Ok(())
        });
    }

    /// Start a stroke of command `command` (`paint.stroke`, `paint.cloneStamp`,
    /// `paint.healingBrush`, `paint.spotHealing`, `select.quick`, …) with JSON `params` minus
    /// its points.
    pub fn stroke_begin(&self, command: String, params: String, points: Vec<StrokePoint>) -> Result<()> {
        self.with(|inner| {
            let p = if params.trim().is_empty() {
                json!({})
            } else {
                serde_json::from_str(&params).map_err(|e| FfiError::new(format!("params aren't JSON: {e}")))?
            };
            let pts = shaped(&inner.session, points);
            if pts.is_empty() {
                return Err(FfiError::new("a stroke needs a first point"));
            }
            inner.stroke = Some(stroke::Live::begin(&inner.session, &command, p, &pts).map_err(FfiError::new)?);
            Ok(())
        })
    }

    pub fn stroke_push(&self, points: Vec<StrokePoint>) -> Result<()> {
        self.with(|inner| {
            let pts = shaped(&inner.session, points);
            let live = inner.stroke.as_mut().ok_or_else(|| FfiError::new("no stroke in progress"))?;
            live.push(&pts).map_err(FfiError::new)
        })
    }

    /// Finish the stroke: run its command with every point. Returns the command's JSON result.
    pub fn stroke_end(&self) -> Result<String> {
        self.with(|inner| {
            let live = inner.stroke.take().ok_or_else(|| FfiError::new("no stroke in progress"))?;
            let bounds = live.bounds();
            let before = inner.revision();
            let result = live.commit(&mut inner.session);
            inner.note_changes(before);
            if let Some(b) = bounds {
                // The canvas shows the preview: put back the document where it drew.
                inner.add_damage(Some(b));
            }
            Ok(result.map_err(FfiError::new)?.to_string())
        })
    }

    pub fn stroke_cancel(&self) {
        let _ = self.with(|inner| {
            if let Some(b) = inner.stroke.take().and_then(|l| l.bounds()) {
                inner.add_damage(Some(b));
            }
            Ok(())
        });
    }

    /// Show `edit.transform` with JSON `params` on the canvas without changing the document.
    /// Slow for a big layer: call it off the main thread. Ended by [`Editor::end_preview`].
    pub fn preview_transform(&self, params: String) -> Result<()> {
        let p = serde_json::from_str(&params).map_err(|e| FfiError::new(format!("params aren't JSON: {e}")))?;
        let (job, generation) =
            self.with(|inner| Ok((photocraft_engine::transform_cmds::preview(&inner.session, &p).map_err(FfiError::new)?, inner.preview_gen)))?;
        let area = job.area();
        // Rendered without the lock, so the canvas keeps drawing.
        let doc = std::panic::catch_unwind(AssertUnwindSafe(|| job.render()))
            .map_err(|_| FfiError::new("internal error: the preview was stopped"))?
            .map_err(FfiError::new)?;
        self.with(|inner| {
            if inner.preview_gen == generation {
                let old = inner.preview.take().map(|p| p.area);
                let damage = old.map_or(area, |o| o.union(&area));
                inner.preview = Some(Preview { doc: Arc::new(doc), area, damage: Some(damage) });
            }
            Ok(())
        })
    }

    /// Show Edit › Puppet Warp with JSON `params` (`edit.puppetWarp`'s) on the canvas without
    /// changing the document; returns the mesh's edges where they end up, `[x0, y0, x1, y1, …]`
    /// in document pixels. Slow for a big layer: call it off the main thread. Ended by
    /// [`Editor::end_preview`].
    pub fn preview_puppet(&self, params: String) -> Result<Vec<f32>> {
        let p = serde_json::from_str(&params).map_err(|e| FfiError::new(format!("params aren't JSON: {e}")))?;
        let (job, generation, area) = self.with(|inner| {
            let job = photocraft_engine::distort_cmds::puppet_preview(&inner.session, &p).map_err(FfiError::new)?;
            let area = inner.session.active().map(|d| d.doc.bounds()).unwrap_or_default();
            Ok((job, inner.preview_gen, area))
        })?;
        let (doc, edges) = std::panic::catch_unwind(AssertUnwindSafe(|| job.render()))
            .map_err(|_| FfiError::new("internal error: the preview was stopped"))?
            .map_err(FfiError::new)?;
        self.with(|inner| {
            if inner.preview_gen == generation {
                let old = inner.preview.take().map(|p| p.area);
                let damage = old.map_or(area, |o| o.union(&area));
                inner.preview = Some(Preview { doc: Arc::new(doc), area, damage: Some(damage) });
            }
            Ok(())
        })?;
        Ok(edges)
    }

    /// Show Filter › Fluid Warp with JSON `params` (`filter.liquify`'s) on the canvas without
    /// changing the document. Slow for a big layer: call it off the main thread. Ended by
    /// [`Editor::end_preview`].
    pub fn preview_liquify(&self, params: String) -> Result<()> {
        let p = serde_json::from_str(&params).map_err(|e| FfiError::new(format!("params aren't JSON: {e}")))?;
        let (job, generation, area) = self.with(|inner| {
            let job = photocraft_engine::distort_cmds::liquify_preview(&inner.session, &p).map_err(FfiError::new)?;
            let area = inner.session.active().map(|d| d.doc.bounds()).unwrap_or_default();
            Ok((job, inner.preview_gen, area))
        })?;
        let doc = std::panic::catch_unwind(AssertUnwindSafe(|| job.render()))
            .map_err(|_| FfiError::new("internal error: the preview was stopped"))?
            .map_err(FfiError::new)?;
        self.with(|inner| {
            if inner.preview_gen == generation {
                let old = inner.preview.take().map(|p| p.area);
                let damage = old.map_or(area, |o| o.union(&area));
                inner.preview = Some(Preview { doc: Arc::new(doc), area, damage: Some(damage) });
            }
            Ok(())
        })
    }

    /// Show the document again after [`Editor::preview_transform`].
    pub fn end_preview(&self) {
        let _ = self.with(|inner| {
            inner.preview_gen += 1;
            if let Some(p) = inner.preview.take() {
                inner.add_damage(Some(p.area));
            }
            Ok(())
        });
    }

    /// What Free Transform frames on the active layer, `[x0, y0, x1, y1]`; `None` when nothing.
    /// `mask`: the layer's mask is targeted (an unlinked or selected mask transforms alone).
    pub fn transform_bounds(&self, mask: bool) -> Option<Vec<i32>> {
        self.with(|inner| {
            use photocraft_engine::transform_cmds as t;
            let st = inner.session.active().ok_or_else(|| FfiError::new("no document"))?;
            let l = st.active_layer.and_then(|id| st.doc.layer(id)).ok_or_else(|| FfiError::new("no layer"))?;
            let lone = if mask { t::lone_target(&st.doc, st.active_layer, &serde_json::json!({"target": "mask"})).map_err(FfiError::new)? } else { None };
            let b = match lone {
                Some(surface) => t::target_bounds(&st.doc, surface),
                None => t::transform_bounds(&st.doc, l),
            };
            Ok((!b.is_empty()).then(|| vec![b.x0, b.y0, b.x1, b.y1]))
        })
        .ok()
        .flatten()
    }

    /// Whether command `id` can run now (in this document, with this layer).
    pub fn command_enabled(&self, id: String) -> bool {
        self.with(|inner| Ok(inner.session.disabled_reason(&id).is_none())).unwrap_or(false)
    }

    /// The settings command `id` takes that the app can ask for.
    pub fn command_fields(&self, id: String) -> Vec<ParamField> {
        photocraft_engine::commands::find(&id).map(|c| params::fields(c.params)).unwrap_or_default()
    }

    /// Every command with a menu item.
    pub fn commands(&self) -> Vec<CommandInfo> {
        self.with(|inner| {
            Ok(photocraft_engine::commands::command_specs()
                .iter()
                .filter(|c| !c.menu.is_empty())
                .map(|c| {
                    let reason = inner.session.disabled_reason(c.id);
                    CommandInfo { id: c.id.into(), label: c.label.into(), menu: c.menu.join(" > "), enabled: reason.is_none(), reason, params: c.params.into() }
                })
                .collect())
        })
        .unwrap_or_default()
    }

    /// Every key binding in effect.
    pub fn key_bindings(&self) -> Vec<KeyBinding> {
        use photocraft_engine::prefs::{BindKind, bindable_items, normalize_shortcut};
        self.with(|inner| {
            let prefs = inner.session.prefs();
            let mut out = Vec::new();
            for (id, label, _, default, kind) in bindable_items() {
                let main = prefs.shortcut(id, default);
                let kind = match kind {
                    BindKind::Command if photocraft_engine::commands::find(id).is_some() => "command",
                    BindKind::Command => "shell",
                    BindKind::Tool => "tool",
                    BindKind::Hold => "hold",
                };
                for key in main.and_then(normalize_shortcut).into_iter().chain(prefs.alternates(id, main)) {
                    out.push(KeyBinding { id: id.into(), label: label.into(), shortcut: key, kind: kind.into() });
                }
            }
            Ok(out)
        })
        .unwrap_or_default()
    }

    pub fn tool_settings(&self) -> ToolSettings {
        let inner = self.lock();
        let t = &inner.session.tools;
        let doc = inner.session.active();
        let sym = doc.and_then(|d| d.symmetry.as_ref());
        let lines = match (sym.and_then(|s| s.preset()), doc) {
            (Some(p), Some(d)) => p.segments([f64::from(d.doc.size.width), f64::from(d.doc.size.height)]).into_iter().flatten().flatten().collect(),
            _ => Vec::new(),
        };
        ToolSettings {
            size: t.brush.size,
            hardness: t.brush.hardness,
            opacity: t.brush.opacity,
            foreground: t.foreground.to_vec(),
            background: t.background.to_vec(),
            flow: t.brush.flow,
            smoothing: t.brush.smoothing.amount,
            mode: serde_json::to_value(t.brush.mode).ok().and_then(|v| v.as_str().map(String::from)).unwrap_or_default(),
            pressure_size: t.brush.pressure_size,
            pressure_opacity: t.brush.pressure_opacity,
            erase: t.brush.erase,
            symmetry: sym.map(|s| s.inspect()["mode"].as_str().unwrap_or_default().to_string()).unwrap_or_default(),
            symmetry_lines: lines,
        }
    }

    /// The selection outline as screen-pixel line segments, `[x0, y0, x1, y1, …]`.
    pub fn selection_outline(&self, view: ViewState) -> Vec<f32> {
        self.with(|inner| Ok(inner.outline(&view.into()))).unwrap_or_default()
    }
}

impl Editor {
    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Run `f` on the editor state; a panic becomes an error.
    fn with<T>(&self, f: impl FnOnce(&mut Inner) -> Result<T>) -> Result<T> {
        let mut inner = self.lock();
        std::panic::catch_unwind(AssertUnwindSafe(|| f(&mut inner))).unwrap_or_else(|_| {
            inner.mark_all_dirty();
            Err(FfiError::new("internal error: the operation was stopped, and the document is kept"))
        })
    }
}

impl Inner {
    fn doc(&self) -> Option<Arc<Document>> {
        self.session.active().map(|st| st.doc.clone())
    }

    fn revision(&self) -> Option<(DocId, u64)> {
        self.session.active().map(|st| (st.doc.id, st.revision))
    }

    fn info(&self) -> Option<DocInfo> {
        let st = self.session.active()?;
        Some(DocInfo {
            id: st.doc.id.0,
            name: st.doc.name.clone(),
            width: st.doc.size.width,
            height: st.doc.size.height,
            revision: st.revision,
            can_undo: st.history.can_undo(),
            can_redo: st.history.can_redo(),
            has_selection: st.doc.selection.is_some(),
        })
    }

    /// Add `doc` to the open documents and show it.
    fn load(&mut self, doc: Document) -> Result<DocInfo> {
        self.end_live_work();
        self.session.open_document(doc, None);
        self.mark_all_dirty();
        self.info().ok_or_else(|| FfiError::new("the file opened without a document"))
    }

    /// Drop a stroke or preview in progress (the document is changing).
    fn end_live_work(&mut self) {
        self.stroke = None;
        self.preview = None;
        self.preview_gen += 1;
    }

    fn mark_all_dirty(&mut self) {
        self.dirty = true;
        self.damage = None;
    }

    /// Add `r` to what the canvas must refresh (`None`: everything).
    fn add_damage(&mut self, r: Option<Rect>) {
        match r {
            None => self.mark_all_dirty(),
            Some(_) if self.dirty && self.damage.is_none() => {}
            Some(r) => {
                self.damage = Some(self.damage.map_or(r, |d| d.union(&r)));
                self.dirty = true;
            }
        }
    }

    /// Record what changed since `before`: one step reports its damage, more (or another
    /// document) mean everything.
    fn note_changes(&mut self, before: Option<(DocId, u64)>) {
        let after = self.revision();
        if after == before {
            return;
        }
        match (before, after, self.session.active()) {
            (Some((a, r0)), Some((b, r1)), Some(st)) if a == b && r1 == r0 + 1 => {
                let reach = st.last_damage;
                self.add_damage(reach);
            }
            _ => self.mark_all_dirty(),
        }
    }

    fn refresh_canvas(&mut self) {
        let Some(st) = self.session.active() else { return };
        let Some(canvas) = &mut self.canvas else { return };
        // View Mask: the active layer's mask in gray instead of the image.
        let viewing = photocraft_engine::mask_view_cmds::current(st)
            .filter(|v| v.mode == photocraft_engine::mask_view_cmds::MaskViewMode::Gray)
            .map(|v| (st.doc.id, st.revision, v.layer));
        if viewing != self.mask_view.as_ref().map(|(k, _)| *k) {
            self.mask_view = viewing.and_then(|k| mask_picture(&st.doc, k.2).map(|d| (k, Arc::new(d))));
            self.damage = None;
            self.dirty = true;
        }
        let base = self.mask_view.as_ref().map_or_else(|| st.doc.clone(), |(_, d)| d.clone());
        let now = (base.id, st.revision);
        // A changed document or revision this frame didn't hear about: redraw it all.
        if self.shown.is_some_and(|s| s != now) && !self.dirty {
            self.damage = None;
            self.dirty = true;
        }
        if !canvas.holds(&base) {
            self.damage = None;
            self.dirty = true;
        }
        if self.dirty {
            canvas.refresh(&self.session, &base, self.damage);
            self.dirty = false;
            self.damage = None;
            // That drew over the preview.
            if let Some(p) = &mut self.preview {
                p.damage = Some(p.area);
            }
        }
        if let Some(p) = &mut self.preview
            && let Some(d) = p.damage.take()
        {
            canvas.refresh(&self.session, &p.doc, Some(d));
        }
        // A stroke on the mask shows when it ends.
        if let Some(live) = &mut self.stroke
            && self.mask_view.is_none()
            && let Some(doc) = live.doc().cloned()
            && let Some(d) = live.damage.take()
        {
            canvas.refresh(&self.session, &doc, Some(d));
        }
        self.shown = Some(now);
    }

    fn outline(&mut self, view: &View) -> Vec<f32> {
        let Some(st) = self.session.active() else { return Vec::new() };
        let Some(sel) = &st.doc.selection else { return Vec::new() };
        let zoom = if view.zoom.is_finite() && view.zoom > 0.0 { view.zoom } else { 1.0 };
        let bounds = sel.content_bounds();
        let step = photocraft_engine::outline::bounded_step(bounds, (1.0 / zoom).floor().clamp(1.0, 256.0) as u32);
        let key = st.doc.id.0.rotate_left(17) ^ st.revision.rotate_left(29) ^ u64::from(step);
        let segs = match &self.outline {
            Some((k, segs)) if *k == key => segs.clone(),
            _ => {
                let segs = Arc::new(photocraft_engine::outline::outline_scaled(sel, bounds, step));
                self.outline = Some((key, segs.clone()));
                segs
            }
        };
        let mut out = Vec::with_capacity(segs.len() * 4);
        for (a, b) in segs.iter() {
            let p = view.doc_to_screen([a[0] as f32, a[1] as f32]);
            let q = view.doc_to_screen([b[0] as f32, b[1] as f32]);
            out.extend_from_slice(&[p[0], p[1], q[0], q[1]]);
        }
        out
    }
}

#[cfg(test)]
mod tests;

/// `doc` as a JPEG XL file (see [`Editor::export_jxl`]).
fn export_jxl(doc: &photocraft_doc::Document, opts: &jxl::EncodeOptions, width: Option<u32>, srgb: bool, transparency: bool) -> Result<Vec<u8>> {
    let resized;
    let doc = if width.is_some() || srgb {
        let size = width.map_or(serde_json::json!({}), |w| serde_json::json!({ "width": w }));
        let st = photocraft_engine::web_cmds::WebSettings { convert_to_srgb: srgb, ..Default::default() };
        resized = photocraft_engine::web_cmds::web_document(doc, &size, &st).map_err(FfiError::new)?.0;
        &resized
    } else {
        doc
    };
    let (img, _) = photocraft_io::image_for_export(doc, transparency).map_err(FfiError::new)?;
    jxl::encode(&img, &jxl::alpha_channels(doc), opts).map_err(|e| FfiError::new(format!("JPEG XL: {e}")))
}

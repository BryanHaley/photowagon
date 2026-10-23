//! Smart selection commands: Quick Selection, Object Selection, Select Subject, Select and Mask
//! (Refine Edge) and Focus Area. The algorithms live in `photocraft_algo::segment` and
//! `photocraft_algo::matting`; these commands pick the pixels to analyse (active layer or
//! composite), run them, and store the result as the selection (or a mask / new layer).

use photocraft_algo::matting::{self, RefineParams};
use photocraft_algo::segment::{Sampler, SurfaceSampler, focus, grabcut, quick, subject};
use photocraft_algo::selection::{Region, SelectionMode, combine_region};
use photocraft_doc::{Document, Layer, LayerContent, LayerId, LayerMask};
use photocraft_geom::Rect;
use serde_json::{Value, json};

use crate::commands::CommandSpec;
use crate::{EngineError, Result, Session};

fn has_doc(s: &Session) -> std::result::Result<(), String> {
    s.active().map(|_| ()).ok_or_else(|| "no document open".into())
}
fn has_selection_or_mask(s: &Session) -> std::result::Result<(), String> {
    let d = s.active().ok_or_else(|| "no document open".to_string())?;
    if d.doc.selection.is_some() {
        return Ok(());
    }
    if let Some(l) = d.active_layer.and_then(|id| d.doc.layer(id))
        && l.mask.is_some()
    {
        return Ok(());
    }
    Err("no selection or layer mask".into())
}

fn f(p: &Value, k: &str, d: f32) -> f32 {
    p.get(k).and_then(Value::as_f64).map_or(d, |v| v as f32)
}
fn b(p: &Value, k: &str, d: bool) -> bool {
    p.get(k).and_then(Value::as_bool).unwrap_or(d)
}
fn mode(p: &Value, default: &str) -> SelectionMode {
    let m = p.get("mode").and_then(Value::as_str).unwrap_or(default);
    SelectionMode::parse(if m == "new" { "replace" } else { m })
}
fn bad(cmd: &str, msg: &str) -> EngineError {
    EngineError::BadParams { cmd: cmd.into(), msg: msg.into() }
}

/// Composite of all visible layers.
struct CompositeSampler<'a>(&'a Document);

impl Sampler for CompositeSampler<'_> {
    fn rgba(&self, r: Rect) -> Vec<[f32; 4]> {
        photocraft_compose::render(self.0, r).px
    }
}

/// Runs `f` with a sampler over the active layer (or the composite with `all_layers`, or when the
/// active layer has no pixels).
fn with_sampler<R>(s: &Session, all_layers: bool, f: impl FnOnce(&dyn Sampler, &Document) -> R) -> Result<R> {
    let d = s.active().ok_or(EngineError::NoDocument)?;
    Ok(with_doc_sampler(&d.doc, d.active_layer, all_layers, f))
}

/// Runs `f` with a sampler over `layer`'s pixels in `doc` (or the composite with `all_layers`, or
/// when the layer has no pixels).
pub(crate) fn with_doc_sampler<R>(doc: &Document, layer: Option<LayerId>, all_layers: bool, f: impl FnOnce(&dyn Sampler, &Document) -> R) -> R {
    match (all_layers, layer.and_then(|id| doc.layer(id)).and_then(Layer::surface)) {
        (false, Some(surf)) => f(&SurfaceSampler(surf), doc),
        _ => f(&CompositeSampler(doc), doc),
    }
}

/// Stores `region` combined with the current selection by `m` as one history step.
/// Finding nothing never destroys work: the selection (and history) is left alone and the
/// caller gets `changed: false`, whatever the mode. (Select Subject and Object Selection run
/// heuristics that often find nothing on busy photos; clearing the selection then looks like
/// a dead button.)
fn apply(s: &mut Session, label: &str, region: Option<&Region>, m: SelectionMode) -> Result<Value> {
    if region.is_none() {
        // Nothing found: leave the selection (and history) alone.
        let selected = s.active().ok_or(EngineError::NoDocument)?.doc.selection.is_some();
        return Ok(json!({ "selected": selected, "changed": false }));
    }
    let bbox = region.map(|r| r.bbox);
    let selected = s.edit(label, |doc, _| {
        doc.selection = combine_region(doc.selection.as_ref(), region, m);
        Ok(doc.selection.is_some())
    })?;
    Ok(json!({ "selected": selected, "changed": true, "bounds": bbox.map(|r| [r.x0, r.y0, r.width() as i32, r.height() as i32]) }))
}

fn points(p: &Value) -> Vec<(f32, f32)> {
    p.get("points")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|q| Some((q.get(0)?.as_f64()? as f32, q.get(1)?.as_f64()? as f32))).collect())
        .unwrap_or_default()
}

/// Auto-Enhance for Quick Selection: a light edge refinement that flows the edge towards image
/// edges and removes blockiness.
const ENHANCE: RefineParams = RefineParams { radius: 4.0, smart_radius: true, smooth: 15.0, feather: 0.0, contrast: 25.0, shift_edge: 0.0 };

fn quick_selection(s: &mut Session, p: &Value) -> Result<Value> {
    let pts = points(p);
    if pts.is_empty() {
        return Err(bad("select.quick", "needs at least one point"));
    }
    let size = f(p, "size", 30.0).clamp(1.0, 5000.0);
    let m = match p.get("mode").and_then(Value::as_str).unwrap_or("add") {
        "subtract" => SelectionMode::Subtract,
        "replace" | "new" => SelectionMode::Replace,
        _ => SelectionMode::Add,
    };
    let enhance = b(p, "enhanceEdge", false);
    let region = with_sampler(s, b(p, "sampleAllLayers", false), |smp, doc| {
        let canvas = doc.bounds();
        let r = quick::quick_select(smp, canvas, &pts, size)?;
        if enhance { matting::refine_mask(smp, &matting::region_reader(&r), r.bbox, canvas, &ENHANCE) } else { Some(r) }
    })?;
    apply(s, "Quick Selection", region.as_ref(), m)
}

fn rect_param(p: &Value) -> Option<Rect> {
    let a = p.get("rect")?.as_array()?;
    let v: Vec<f64> = a.iter().filter_map(Value::as_f64).collect();
    if v.len() < 4 {
        return None;
    }
    // Negative sizes (dragging up/left) are normalised.
    let (x0, x1) = (v[0].min(v[0] + v[2]), v[0].max(v[0] + v[2]));
    let (y0, y1) = (v[1].min(v[1] + v[3]), v[1].max(v[1] + v[3]));
    Some(Rect::new(x0.floor() as i32, y0.floor() as i32, x1.ceil() as i32, y1.ceil() as i32))
}

fn point_param(p: &Value) -> Option<(f32, f32)> {
    let a = p.get("point")?.as_array()?;
    let (x, y) = (a.first()?.as_f64()? as f32, a.get(1)?.as_f64()? as f32);
    (x.is_finite() && y.is_finite()).then_some((x, y))
}

/// The layer [`with_doc_sampler`] samples for `layer` / `all_layers`: `None` = the composite.
pub fn sampled_target(doc: &Document, layer: Option<LayerId>, all_layers: bool) -> Option<LayerId> {
    layer.filter(|id| !all_layers && doc.layer(*id).and_then(Layer::surface).is_some())
}

/// Object Finder (#4087): the object Object Selection would select at document point `(x, y)`,
/// sampling `layer` (or the composite). Pure, so the UI can run it on a worker thread while the
/// pointer hovers; `select.object` with `"point"` commits the same result.
pub fn find_object(doc: &Document, layer: Option<LayerId>, all_layers: bool, x: f32, y: f32) -> Option<Region> {
    with_doc_sampler(doc, layer, all_layers, |smp, doc| {
        let (px, py) = (x.floor() as i32, y.floor() as i32);
        let b = doc.bounds();
        // The subject of a window around the point, the window growing until the object fits
        // inside it: a small figure stands out against the sand and sea around it, a big one
        // against the whole frame. Of that subject, the connected part under the point (a head
        // and the body below it are one object, whatever their colours), split from touching
        // neighbours.
        let side = b.width().max(b.height()) as i32;
        for frac in [16, 8, 4, 2, 1] {
            let half = side / frac / 2;
            let window = if frac == 1 { b } else { Rect::new(px - half, py - half, px + half, py + half).intersect(&b) };
            let Some(part) = subject::select_subject(smp, window).and_then(|sub| sub.component_at(px, py)).map(|c| c.split_at(px, py)) else { continue };
            let r = part.bbox;
            // Cut off by the window (not by the frame): the object is bigger; look wider.
            let cut = (r.x0 <= window.x0 + 2 && window.x0 > b.x0) || (r.x1 >= window.x1 - 2 && window.x1 < b.x1)
                || (r.y0 <= window.y0 + 2 && window.y0 > b.y0) || (r.y1 >= window.y1 - 2 && window.y1 < b.y1);
            // Spanning the frame (sea, sky, a wall): the backdrop, not an object.
            let spans = (r.x0 <= b.x0 + 2 && r.x1 >= b.x1 - 2) || (r.y0 <= b.y0 + 2 && r.y1 >= b.y1 - 2);
            if !cut && !spans {
                return Some(part);
            }
        }
        grabcut::object_at(smp, b, x, y, grabcut::OBJECT_AT_WORK_PX)
    })
}

/// Most objects remembered by [`ObjectFinderCache`].
pub const OBJECT_FINDER_ENTRIES: usize = 12;

/// Object Finder results for one document's pixels (#4087): hovering over an object already
/// found, or clicking it, answers at once. Keyed like [`SubjectCache`] (valid while the pixels
/// are the same, the document held weakly) plus the sampled layer; a lookup hits any cached
/// object that covers the point, so one computation serves the whole object.
#[derive(Debug, Default)]
pub struct ObjectFinderCache {
    doc: std::sync::Weak<Document>,
    doc_id: Option<photocraft_doc::DocId>,
    target: Option<LayerId>,
    regions: Vec<std::sync::Arc<Region>>,
}

impl ObjectFinderCache {
    fn valid(&self, doc: &Document, target: Option<LayerId>) -> bool {
        self.doc_id == Some(doc.id) && self.target == target && self.doc.upgrade().is_some_and(|old| crate::layer_multi_cmds::same_pixels(&old, doc))
    }

    /// A cached object of `doc` (sampling `target`) covering `(x, y)`.
    pub fn lookup(&self, doc: &Document, target: Option<LayerId>, x: f32, y: f32) -> Option<std::sync::Arc<Region>> {
        if !x.is_finite() || !y.is_finite() || !self.valid(doc, target) {
            return None;
        }
        let (px, py) = (x.floor() as i32, y.floor() as i32);
        self.regions.iter().find(|r| r.at(px, py) >= 0.5).cloned()
    }

    /// Remembers `region`, found in `doc` sampling `target`. A different document or pixels
    /// start over; the oldest object is dropped beyond [`OBJECT_FINDER_ENTRIES`].
    pub fn insert(&mut self, doc: &std::sync::Arc<Document>, target: Option<LayerId>, region: std::sync::Arc<Region>) {
        if !self.valid(doc, target) {
            self.regions.clear();
        }
        self.doc = std::sync::Arc::downgrade(doc);
        self.doc_id = Some(doc.id);
        self.target = target;
        if self.regions.len() >= OBJECT_FINDER_ENTRIES {
            self.regions.remove(0);
        }
        self.regions.push(region);
    }

    /// Number of remembered objects.
    pub fn len(&self) -> usize {
        self.regions.len()
    }

    /// Whether nothing is remembered.
    pub fn is_empty(&self) -> bool {
        self.regions.is_empty()
    }

    /// Forget the results if they were computed from the document `id` (it is closing).
    pub(crate) fn forget_doc(&mut self, id: photocraft_doc::DocId) {
        if self.doc_id == Some(id) {
            *self = Self::default();
        }
    }

    /// Follows `doc` past a selection-only edit (same pixels), so the next lookup still hits.
    fn follow(&mut self, doc: &std::sync::Arc<Document>) {
        if self.doc_id == Some(doc.id) && self.doc.upgrade().is_some_and(|old| crate::layer_multi_cmds::same_pixels(&old, doc)) {
            self.doc = std::sync::Arc::downgrade(doc);
        }
    }
}

/// Object Selection samples only the active layer by default: when that layer has no pixels in
/// `area`, say so instead of quietly finding nothing (#5246; scripts often add an empty layer
/// above the photo first).
fn check_sampled_pixels(doc: &Document, layer: Option<LayerId>, all_layers: bool, area: Rect) -> Result<()> {
    let Some(surf) = sampled_target(doc, layer, all_layers).and_then(|id| doc.layer(id)).and_then(Layer::surface) else { return Ok(()) };
    if surf.content_bounds().intersect(&area).is_empty() {
        let msg = if surf.content_bounds().is_empty() { "the active layer is empty" } else { "the active layer has no pixels in that area" };
        return Err(bad("select.object", &format!("{msg}; set \"sampleAllLayers\": true or select a layer with pixels")));
    }
    Ok(())
}

/// The Object Finder's object under the point (cached).
fn object_region(s: &mut Session, p: &Value, (x, y): (f32, f32)) -> Result<Option<std::sync::Arc<Region>>> {
    let all_layers = b(p, "sampleAllLayers", false);
    let d = s.active().ok_or(EngineError::NoDocument)?;
    check_sampled_pixels(&d.doc, d.active_layer, all_layers, Rect::from_xywh(x.floor() as i32, y.floor() as i32, 1, 1))?;
    let target = sampled_target(&d.doc, d.active_layer, all_layers);
    if let Some(r) = s.object_finder.lookup(&d.doc, target, x, y) {
        return Ok(Some(r));
    }
    let doc = std::sync::Arc::clone(&d.doc);
    let found = find_object(&doc, d.active_layer, all_layers, x, y).map(std::sync::Arc::new);
    if let Some(r) = &found {
        s.object_finder.insert(&doc, target, std::sync::Arc::clone(r));
    }
    Ok(found)
}

/// Longest side of a `select.objectPreview` mask.
const PREVIEW_SIDE: usize = 768;

/// The object `select.object` would take at the point, as a small mask, leaving the selection alone.
fn object_preview(s: &mut Session, p: &Value) -> Result<Value> {
    let pt = point_param(p).ok_or_else(|| bad("select.objectPreview", "needs \"point\": [x, y]"))?;
    let Some(r) = object_region(s, p, pt)? else { return Ok(json!({"found": false})) };
    let (w, h) = (r.bbox.width().max(1) as usize, r.bbox.height().max(1) as usize);
    let step = w.max(h).div_ceil(PREVIEW_SIDE).max(1);
    let (tw, th) = (w.div_ceil(step), h.div_ceil(step));
    let mut data = Vec::with_capacity(tw * th);
    for ty in 0..th {
        for tx in 0..tw {
            let c = r.at(r.bbox.x0 + (tx * step) as i32, r.bbox.y0 + (ty * step) as i32);
            data.push((c * 255.0).round() as u8);
        }
    }
    Ok(json!({
        "found": true,
        "rect": [r.bbox.x0, r.bbox.y0, r.bbox.x1, r.bbox.y1],
        "width": tw,
        "height": th,
        "data": photocraft_paint::tile::b64_encode(&data),
    }))
}

/// `select.object` with `"point"`: the Object Finder's object under the point (cached).
fn object_at_point(s: &mut Session, p: &Value, pt: (f32, f32)) -> Result<Value> {
    let region = object_region(s, p, pt)?;
    let out = apply(s, "Object Selection", region.as_deref(), mode(p, "replace"))?;
    if let Some(d) = s.active() {
        let doc = std::sync::Arc::clone(&d.doc);
        s.object_finder.follow(&doc);
    }
    Ok(out)
}

fn object_selection(s: &mut Session, p: &Value) -> Result<Value> {
    if p.get("rect").is_none()
        && let Some(pt) = point_param(p)
    {
        return object_at_point(s, p, pt);
    }
    let rect = rect_param(p).ok_or_else(|| bad("select.object", "needs \"rect\": [x, y, w, h] or \"point\": [x, y]"))?;
    let all_layers = b(p, "sampleAllLayers", false);
    let d = s.active().ok_or(EngineError::NoDocument)?;
    check_sampled_pixels(&d.doc, d.active_layer, all_layers, rect)?;
    let region = with_sampler(s, all_layers, |smp, doc| grabcut::object_select(smp, doc.bounds(), rect, 160_000))?;
    apply(s, "Object Selection", region.as_ref(), mode(p, "replace"))
}

/// Select Subject's last result (#2865), so running it again on unchanged pixels answers at
/// once instead of recomputing superpixels, saliency and GrabCut (P29). Keyed by the pixels it
/// was computed from: valid while [`same_pixels`](crate::layer_multi_cmds::same_pixels) (a
/// tile-pointer comparison) holds against that document, so selection-only edits such as
/// Deselect keep it. One entry per session; the document is held weakly, so the cache never
/// keeps a closed or edited document's tiles alive (the session also drops it on pixel edits
/// and when its document closes). Its memory is the mask: one byte per pixel of its bounds.
#[derive(Debug, Default)]
pub struct SubjectCache {
    doc: std::sync::Weak<Document>,
    doc_id: Option<photocraft_doc::DocId>,
    /// The sampled layer; `None` = the composite.
    target: Option<LayerId>,
    region: Option<std::sync::Arc<Region>>,
}

impl SubjectCache {
    /// Forget the result if it was computed from the document `id` (it is closing).
    pub(crate) fn forget_doc(&mut self, id: photocraft_doc::DocId) {
        if self.doc_id == Some(id) {
            *self = Self::default();
        }
    }
}

fn select_subject(s: &mut Session, p: &Value) -> Result<Value> {
    let all_layers = b(p, "sampleAllLayers", true);
    let d = s.active().ok_or(EngineError::NoDocument)?;
    // What `with_doc_sampler` samples: the active layer's pixels, else the composite.
    let target = d.active_layer.filter(|id| !all_layers && d.doc.layer(*id).and_then(Layer::surface).is_some());
    let c = &s.subject_cache;
    let hit = c.target == target && c.doc.upgrade().is_some_and(|old| crate::layer_multi_cmds::same_pixels(&old, &d.doc));
    let region = if hit {
        c.region.clone()
    } else {
        let doc = std::sync::Arc::clone(&d.doc);
        let region = with_doc_sampler(&doc, d.active_layer, all_layers, |smp, doc| subject::select_subject(smp, doc.bounds())).map(std::sync::Arc::new);
        s.subject_cache = SubjectCache { doc: std::sync::Arc::downgrade(&doc), doc_id: Some(doc.id), target, region: region.clone() };
        region
    };
    let out = apply(s, "Select Subject", region.as_deref(), mode(p, "replace"))?;
    // Follow the document past the selection edit just made (same pixels), so a short history
    // dropping the older state doesn't turn the next repeat into a miss.
    if let Some(d) = s.active()
        && s.subject_cache.doc_id == Some(d.doc.id)
        && s.subject_cache.doc.upgrade().is_some_and(|old| crate::layer_multi_cmds::same_pixels(&old, &d.doc))
    {
        s.subject_cache.doc = std::sync::Arc::downgrade(&d.doc);
    }
    Ok(out)
}

fn focus_area(s: &mut Session, p: &Value) -> Result<Value> {
    let (range, noise) = (f(p, "range", 0.5).clamp(0.0, 1.0), f(p, "noise", 0.0).clamp(0.0, 1.0));
    let region = with_sampler(s, b(p, "sampleAllLayers", true), |smp, doc| focus::focus_area(smp, doc.bounds(), range, noise))?;
    apply(s, "Focus Area", region.as_ref(), mode(p, "replace"))
}

fn refine_params(p: &Value) -> RefineParams {
    RefineParams {
        radius: f(p, "radius", 0.0).clamp(0.0, 250.0),
        smart_radius: b(p, "smartRadius", false),
        smooth: f(p, "smooth", 0.0).clamp(0.0, 100.0),
        feather: f(p, "feather", 0.0).clamp(0.0, 1000.0),
        contrast: f(p, "contrast", 0.0).clamp(0.0, 100.0),
        shift_edge: f(p, "shiftEdge", 0.0).clamp(-100.0, 100.0),
    }
}

/// Select and Mask: refines the selection edge, then outputs to the selection, a layer mask on
/// the active layer, a new layer or a new document (each with or without a mask).
/// Decontaminating colours needs new pixels, so it upgrades `selection` / `layerMask` output to
/// `newLayerWithMask` (as Photoshop does). New-layer outputs hide the source layer; new-document
/// outputs leave the source document untouched.
fn refine_edge(s: &mut Session, p: &Value) -> Result<Value> {
    let params = refine_params(p);
    if p.get("refineStrokes").is_some_and(|v| !v.is_null()) {
        return Err(bad("select.refineEdge", "refineStrokes is not supported: the Refine Edge Brush was removed"));
    }
    let decontaminate = b(p, "decontaminate", false);
    let amount = f(p, "amount", 100.0).clamp(0.0, 100.0);
    let d = s.active().ok_or(EngineError::NoDocument)?;
    let active = d.active_layer.filter(|id| d.doc.layer(*id).is_some());
    let default_output =
        if d.doc.selection.is_none() && active.and_then(|id| d.doc.layer(id)).and_then(|l| l.mask.as_ref()).is_some() { "layerMask" } else { "selection" };
    let mut output = p.get("output").and_then(Value::as_str).unwrap_or(default_output).to_string();
    if !matches!(output.as_str(), "selection" | "layerMask" | "newLayer" | "newLayerWithMask" | "newDocument" | "newDocumentWithMask") {
        return Err(bad("select.refineEdge", "output must be selection|layerMask|newLayer|newLayerWithMask|newDocument|newDocumentWithMask"));
    }
    if decontaminate && matches!(output.as_str(), "selection" | "layerMask") {
        output = "newLayerWithMask".into();
    }
    let region = with_sampler(s, b(p, "sampleAllLayers", false), |smp, doc| {
        let mask_surf = active.and_then(|id| doc.layer(id)).and_then(|l| l.mask.as_ref()).map(|m| &m.surface);
        let target_mask = p.get("target").and_then(Value::as_str) == Some("mask");
        let sel = if target_mask { mask_surf.or(doc.selection.as_ref()) } else { doc.selection.as_ref().or(mask_surf) }?;
        matting::refine_mask(smp, &matting::surface_reader(sel), sel.content_bounds(), doc.bounds(), &params)
    })?;
    let d = s.active().ok_or(EngineError::NoDocument)?;
    let active = d.active_layer.filter(|id| d.doc.layer(*id).is_some());
    match output.as_str() {
        "selection" => {
            let selected = s.edit("Refine Selection", |doc, _| {
                doc.selection = region.as_ref().map(matting::region_surface);
                Ok(doc.selection.is_some())
            })?;
            Ok(json!({ "output": output, "selected": selected }))
        }
        "layerMask" => {
            let id = active.ok_or_else(|| EngineError::Other("no active layer".into()))?;
            s.edit("Refine Selection", |doc, _| {
                let surface =
                    region.as_ref().map(matting::region_surface).unwrap_or_else(|| photocraft_raster::Surface::new(photocraft_color::PixelFormat::GRAY8));
                crate::extra_cmds::background_to_layer_for_mask(doc, id);
                let existing = doc.layer(id).and_then(|l| l.mask.as_ref()).cloned().unwrap_or_else(LayerMask::reveal_all);
                doc.layer_mut(id).ok_or(EngineError::NoLayer(id))?.mask = Some(LayerMask { surface, ..existing });
                doc.selection = None;
                Ok(())
            })?;
            Ok(json!({ "output": output, "layer": id.0, "selected": false }))
        }
        _ => {
            let id = active.ok_or_else(|| EngineError::Other("no active layer".into()))?;
            let src_layer = d.doc.layer(id).ok_or(EngineError::NoLayer(id))?;
            let src = src_layer.surface().ok_or_else(|| {
                EngineError::Other(format!("the active layer is {} {} layer without pixels", src_layer.content.article(), src_layer.content.kind_name()))
            })?;
            let name = d.doc.copy_name(&src_layer.name);
            let empty = Region { bbox: Rect::EMPTY, mask: Vec::new() };
            let reg = region.as_ref().unwrap_or(&empty);
            let pixels = if decontaminate { matting::decontaminate(src, reg, params.radius, amount) } else { src.clone() };
            let with_mask = matches!(output.as_str(), "newLayerWithMask" | "newDocumentWithMask");
            let (content, mask) = if with_mask {
                (pixels, Some(LayerMask { surface: matting::region_surface(reg), ..LayerMask::reveal_all() }))
            } else {
                (matting::masked_copy(&pixels, reg), None)
            };
            if output.starts_with("newDocument") {
                // Same canvas, colour mode, depth and profile, so the pixels need no conversion.
                let mut doc = Document::new("Untitled", d.doc.size, d.doc.mode, d.doc.depth);
                doc.resolution_dpi = d.doc.resolution_dpi;
                doc.icc_profile = d.doc.icc_profile.clone();
                doc.color_table = d.doc.color_table.clone();
                doc.duotone = d.doc.duotone.clone();
                let mut layer = Layer::new(src_layer.name.clone(), LayerContent::Raster(content));
                layer.mask = mask;
                let layer_id = layer.id;
                doc.layers.push(layer);
                let i = s.add_document(doc, None);
                return Ok(json!({ "output": output, "document": i, "layer": layer_id.0, "selected": false }));
            }
            let new_id = s.edit("Refine Selection", |doc, act| {
                let mut layer = Layer::new(name, LayerContent::Raster(content));
                layer.mask = mask;
                let nid = doc.insert_above(Some(id), layer);
                if let Some(l) = doc.layer_mut(id) {
                    l.visible = false;
                }
                doc.selection = None;
                *act = Some(nid);
                Ok(nid)
            })?;
            Ok(json!({ "output": output, "layer": new_id.0, "selected": false }))
        }
    }
}

macro_rules! spec {
    ($id:literal, $label:literal, [$($m:literal),*], $params:literal, $en:expr, $run:expr) => {
        CommandSpec { id: $id, label: $label, menu: &[$($m),*], shortcut: None, params: $params, enabled: $en, run: $run, journal: true }
    };
}

/// Smart selection command specs.
/// Largest mask accepted by `select.fromMask`, in samples.
const MAX_MASK_SAMPLES: u64 = 64 << 20;

/// A mask computed elsewhere (the iOS app's Vision object masks) as a document region:
/// `{"width","height","data":base64 bytes,"rect":[x0,y0,x1,y1]?}`, stretched over `rect`
/// (default the document). `None` when nothing in it is covered.
pub(crate) fn decode_mask(m: &Value, bounds: Rect, cmd: &str) -> Result<Option<Region>> {
    let dim = |k: &str| m.get(k).and_then(Value::as_u64).filter(|v| *v > 0 && *v <= 65_536).ok_or_else(|| bad(cmd, &format!("`{k}` must be 1..65536")));
    let (w, h) = (dim("width")?, dim("height")?);
    if w * h > MAX_MASK_SAMPLES {
        return Err(bad(cmd, "the mask is too large"));
    }
    let data = m.get("data").and_then(Value::as_str).ok_or_else(|| bad(cmd, "`data` must be base64 bytes"))?;
    let bytes = photocraft_paint::tile::b64_decode(data).ok_or_else(|| bad(cmd, "`data` is not valid base64"))?;
    if bytes.len() as u64 != w * h {
        return Err(bad(cmd, &format!("`data` has {} bytes, not width × height = {}", bytes.len(), w * h)));
    }
    let rect = match m.get("rect") {
        None => bounds,
        Some(v) => {
            let a: Vec<i64> = v.as_array().map(|a| a.iter().filter_map(Value::as_i64).collect()).unwrap_or_default();
            if a.len() != 4 || a[2] <= a[0] || a[3] <= a[1] {
                return Err(bad(cmd, "`rect` must be [x0, y0, x1, y1] with x1 > x0 and y1 > y0"));
            }
            let c = |x: i64| x.clamp(-(1 << 30), 1 << 30) as i32;
            Rect::new(c(a[0]), c(a[1]), c(a[2]), c(a[3]))
        }
    };
    let bbox = rect.intersect(&bounds);
    let (fw, fh) = (f64::from(rect.width()) / w as f64, f64::from(rect.height()) / h as f64);
    let sample = |x: i32, y: i32| {
        let my = ((f64::from(y - rect.y0) + 0.5) / fh).floor().clamp(0.0, (h - 1) as f64) as u64;
        let mx = ((f64::from(x - rect.x0) + 0.5) / fw).floor().clamp(0.0, (w - 1) as f64) as u64;
        bytes.get((my * w + mx) as usize).copied().unwrap_or(0)
    };
    // The covered part only, so the region's box is the selection's.
    let (mut x0, mut y0, mut x1, mut y1) = (i32::MAX, i32::MAX, i32::MIN, i32::MIN);
    for y in bbox.y0..bbox.y1 {
        for x in bbox.x0..bbox.x1 {
            if sample(x, y) > 0 {
                (x0, y0, x1, y1) = (x0.min(x), y0.min(y), x1.max(x + 1), y1.max(y + 1));
            }
        }
    }
    if x0 >= x1 {
        return Ok(None);
    }
    let tight = Rect::new(x0, y0, x1, y1);
    let mask = (y0..y1).flat_map(|y| (x0..x1).map(move |x| (x, y))).map(|(x, y)| sample(x, y)).collect();
    Ok(Some(Region { bbox: tight, mask }))
}

/// Edge refinement for a mask computed at a lower resolution than the document.
const MASK_REFINE: RefineParams = RefineParams { radius: 2.0, smart_radius: true, smooth: 10.0, feather: 0.5, contrast: 10.0, shift_edge: 0.0 };

/// `select.fromMask`: a selection from a mask computed elsewhere.
fn select_from_mask(s: &mut Session, p: &Value) -> Result<Value> {
    let d = s.active().ok_or(EngineError::NoDocument)?;
    let mut region = decode_mask(p, d.doc.bounds(), "select.fromMask")?;
    if b(p, "refine", false)
        && let Some(r) = &region
    {
        let refined = with_doc_sampler(&d.doc, d.active_layer, b(p, "sampleAllLayers", false), |smp, doc| {
            matting::refine_mask(smp, &matting::region_reader(r), r.bbox, doc.bounds(), &MASK_REFINE)
        });
        region = refined.or(region);
    }
    if let Some(band) = p.get("band").filter(|v| !v.is_null()) {
        let band = band.as_f64().filter(|v| (1.0..=2048.0).contains(v)).ok_or_else(|| bad("select.fromMask", "`band` must be 1..2048 px"))?;
        let sel = d.doc.selection.as_ref().ok_or_else(|| EngineError::Other("Refine Hair needs a selection".into()))?;
        region = Some(edge_band(sel, region.as_ref(), band, d.doc.bounds()));
    }
    let label = p.get("label").and_then(Value::as_str).unwrap_or("Select from Mask").to_string();
    apply(s, &label, region.as_ref(), mode(p, "replace"))
}

/// The selection `sel` with `mask` taking over within `band` px of its edge (its 50% line).
fn edge_band(sel: &photocraft_raster::Surface, mask: Option<&Region>, band: f64, bounds: Rect) -> Region {
    let bbox = sel.content_bounds().inflate(band.ceil() as i32).intersect(&bounds);
    let (w, h) = (bbox.width() as usize, bbox.height() as usize);
    let at = |i: usize| (bbox.x0 + (i % w.max(1)) as i32, bbox.y0 + (i / w.max(1)) as i32);
    let cur: Vec<f32> = (0..w * h).map(|i| { let (x, y) = at(i); sel.sample_channel(x, y, 0) }).collect();
    let inside: Vec<bool> = cur.iter().map(|v| *v >= 0.5).collect();
    let outside: Vec<bool> = inside.iter().map(|v| !v).collect();
    // Distance to the other side of the edge.
    let (to_out, to_in) = (photocraft_algo::selection::edt(&outside, w, h), photocraft_algo::selection::edt(&inside, w, h));
    let near = |i: usize| {
        let d = if inside[i] { to_out.get(i) } else { to_in.get(i) };
        d.is_some_and(|d| f64::from(*d) <= band)
    };
    let out = (0..w * h)
        .map(|i| {
            let (x, y) = at(i);
            let v = if near(i) { mask.map_or(0.0, |m| m.at(x, y)) } else { cur[i] };
            (v.clamp(0.0, 1.0) * 255.0).round() as u8
        })
        .collect();
    Region { bbox, mask: out }
}

pub fn specs() -> Vec<CommandSpec> {
    vec![
        spec!(
            "select.fromMask",
            "Select from Mask",
            [],
            r##"{"width":1..65536,"height":1..65536,"data":base64 (width × height bytes, 0 = out, 255 = in),"rect":[x0,y0,x1,y1]?=document (where the mask goes; it is stretched to fit),"mode":"replace|add|subtract|intersect"="replace","refine":bool=false (refine the edge against the image, for a lower-resolution mask),"sampleAllLayers":bool=false (refine against all layers),"band":px? (keep the current selection and take the mask only within this distance of its edge: Refine Hair),"label":str?="Select from Mask" (history name)}"##,
            has_doc,
            select_from_mask
        ),
        spec!(
            "select.quick",
            "Quick Selection",
            [],
            r##"{"points":[[x,y],…],"size":px=30,"mode":"add|subtract|replace"="add","sampleAllLayers":bool=false,"enhanceEdge":bool=false}"##,
            has_doc,
            quick_selection
        ),
        spec!(
            "select.object",
            "Object Selection",
            [],
            r##"{"rect":[x,y,w,h] | "point":[x,y],"mode":"replace|add|subtract|intersect"="replace","sampleAllLayers":bool=false} (point: the Object Finder's object under the point, as hovering previews it)"##,
            has_doc,
            object_selection
        ),
        CommandSpec {
            id: "select.objectPreview",
            label: "Object Finder Preview",
            menu: &[],
            shortcut: None,
            params: r##"{"point":[x,y],"sampleAllLayers":bool=false} → {found, rect:[x0,y0,x1,y1], width, height, data: base64 bytes (0–255 coverage, at most 768 on a side)}: the object `select.object` would take there; the selection is left alone"##,
            enabled: has_doc,
            run: object_preview,
            journal: false,
        },
        spec!(
            "select.subject",
            "Subject",
            ["Select"],
            r##"{"sampleAllLayers":bool=true,"mode":"replace|add|subtract|intersect"="replace"}"##,
            has_doc,
            select_subject
        ),
        spec!(
            "select.refineEdge",
            "Refine Selection…",
            ["Select"],
            r##"{"radius":px=0,"smartRadius":bool=false,"smooth":0..100=0,"feather":px=0,"contrast":0..100=0,"shiftEdge":-100..100=0,"decontaminate":bool=false,"amount":0..100=100,"output":"selection|layerMask|newLayer|newLayerWithMask|newDocument|newDocumentWithMask"="selection","sampleAllLayers":bool=false}"##,
            has_selection_or_mask,
            refine_edge
        ),
        spec!(
            "select.focusArea",
            "Focus Area…",
            ["Select"],
            r##"{"range":0..1=0.5,"noise":0..1=0,"sampleAllLayers":bool=true,"mode":"replace|add|subtract|intersect"="replace"}"##,
            has_doc,
            focus_area
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use photocraft_algo::segment::Rng;

    /// A document whose background shows `px(x, y)` (RGB, 0–1), at the given depth.
    fn session_with(w: u32, h: u32, depth: u32, px: impl Fn(u32, u32) -> [f32; 3]) -> Session {
        let mut s = Session::new();
        s.execute("file.new", json!({"width": w, "height": h, "depth": depth})).unwrap();
        s.edit("paint", |doc, _| {
            let bg = doc.layers[0].surface_mut().unwrap();
            let n = bg.channels();
            let mut data = Vec::with_capacity((w * h) as usize * n);
            for y in 0..h {
                for x in 0..w {
                    let c = px(x, y);
                    data.extend_from_slice(&c[..n.min(3)]);
                    if n == 4 {
                        data.push(1.0);
                    }
                }
            }
            bg.write_region(Rect::new(0, 0, w as i32, h as i32), &data);
            Ok(())
        })
        .unwrap();
        s
    }

    fn noise_field(w: u32, h: u32, seed: u64) -> Vec<f32> {
        let mut rng = Rng::new(seed);
        (0..w * h).map(|_| rng.normal()).collect()
    }

    /// Warm textured left part (x < 60), cool right part.
    fn two_regions(depth: u32) -> Session {
        let nz = noise_field(140, 100, 1);
        session_with(140, 100, depth, move |x, y| {
            let n = 0.04 * nz[(y * 140 + x) as usize];
            if x < 60 { [0.8 + n, 0.5 + n, 0.3] } else { [0.2, 0.35 + n, 0.6 + n] }.map(|v| v.clamp(0.0, 1.0))
        })
    }

    /// Textured disc (centre (100, 80), radius 45) on a noisy background.
    fn disc(depth: u32) -> (Session, impl Fn(i32, i32) -> bool) {
        let nz = noise_field(200, 160, 2);
        let inside = |x: i32, y: i32| {
            let (dx, dy) = (x as f32 + 0.5 - 100.0, y as f32 + 0.5 - 80.0);
            dx * dx + dy * dy <= 45.0 * 45.0
        };
        let s = session_with(200, 160, depth, move |x, y| {
            let n = 0.05 * nz[(y * 200 + x) as usize];
            if inside(x as i32, y as i32) {
                let t = ((x + y) as f32 * 0.35).sin() * 0.5 + 0.5;
                [0.85 + 0.05 * t + n, 0.2 + 0.3 * t + n, 0.15 + n]
            } else {
                [0.25 + n, 0.45 + n, 0.7 + n]
            }
            .map(|v| v.clamp(0.0, 1.0))
        });
        (s, inside)
    }

    fn cov(s: &Session, x: i32, y: i32) -> f32 {
        s.active().unwrap().doc.selection.as_ref().map_or(0.0, |m| m.sample_channel(x, y, 0))
    }

    fn sel_iou(s: &Session, w: i32, h: i32, truth: impl Fn(i32, i32) -> bool) -> f32 {
        let (mut i, mut u) = (0, 0);
        for y in 0..h {
            for x in 0..w {
                let (a, b) = (cov(s, x, y) >= 0.5, truth(x, y));
                i += (a && b) as i32;
                u += (a || b) as i32;
            }
        }
        i as f32 / u.max(1) as f32
    }

    #[test]
    fn quick_selection_add_subtract_undo() {
        for depth in [8, 16] {
            let mut s = two_regions(depth);
            let r = s.execute("select.quick", json!({"points": [[20, 50], [35, 50]], "size": 8})).unwrap();
            assert_eq!(r["selected"], true);
            for y in (0..100).step_by(7) {
                for x in (0..140).step_by(3) {
                    let c = cov(&s, x, y);
                    if x < 57 {
                        assert!(c >= 0.5, "depth {depth}: ({x},{y}) not selected");
                    } else if x > 62 {
                        assert!(c < 0.5, "depth {depth}: leaked to ({x},{y})");
                    }
                }
            }
            // A second stroke on the right adds it.
            s.execute("select.quick", json!({"points": [[100, 50]], "size": 8})).unwrap();
            assert!(cov(&s, 130, 90) >= 0.5 && cov(&s, 10, 10) >= 0.5);
            // Subtract the left region again.
            s.execute("select.quick", json!({"points": [[20, 50]], "size": 8, "mode": "subtract"})).unwrap();
            assert!(cov(&s, 10, 10) < 0.5 && cov(&s, 130, 90) >= 0.5);
            s.execute("edit.undo", json!({})).unwrap();
            assert!(cov(&s, 10, 10) >= 0.5);
            assert!(s.execute("select.quick", json!({"points": []})).is_err());
        }
    }

    #[test]
    fn quick_selection_subtract_from_select_all_and_enhance() {
        let mut s = two_regions(8);
        s.execute("select.all", json!({})).unwrap();
        s.execute("select.quick", json!({"points": [[100, 30], [110, 70]], "size": 10, "mode": "subtract"})).unwrap();
        assert!(cov(&s, 10, 50) >= 0.99);
        assert!(cov(&s, 120, 20) < 0.01 && cov(&s, 70, 90) < 0.01);
        s.execute("select.deselect", json!({})).unwrap();
        s.execute("select.quick", json!({"points": [[20, 50]], "size": 8, "enhanceEdge": true})).unwrap();
        assert!(cov(&s, 10, 10) >= 0.5 && cov(&s, 100, 50) < 0.5);
    }

    #[test]
    fn empty_result_keeps_the_selection_in_every_mode() {
        // Finding nothing must never wipe the selection, whatever the mode: Select Subject
        // and Object Selection run heuristics that often miss on busy photos, and a missed
        // Quick Selection dab must not destroy the work either.
        for m in ["add", "subtract", "replace"] {
            let mut s = two_regions(8);
            s.execute("select.all", json!({})).unwrap();
            let r = s.execute("select.quick", json!({"points": [[-5000, -5000]], "size": 8, "mode": m})).unwrap();
            assert_eq!(r["changed"], false, "mode {m}");
            assert_eq!(r["selected"], true, "mode {m}");
            assert!(cov(&s, 10, 50) >= 0.99, "mode {m}: Select All survived an empty result");
        }
        // Select Subject on a flat field finds nothing and keeps the selection too.
        let mut s = session_with(140, 100, 8, |_, _| [0.5, 0.5, 0.5]);
        s.execute("select.all", json!({})).unwrap();
        let r = s.execute("select.subject", json!({})).unwrap();
        assert_eq!(r["changed"], false);
        assert!(cov(&s, 10, 10) >= 0.99);
    }

    #[test]
    fn object_selection_point_selects_the_object_under_it() {
        for depth in [8, 16, 32] {
            let (mut s, inside) = disc(depth);
            let r = s.execute("select.object", json!({"point": [100, 80]})).unwrap();
            assert_eq!(r["changed"], true, "depth {depth}");
            let v = sel_iou(&s, 200, 160, &inside);
            assert!(v > 0.9, "depth {depth}: IoU {v}");
        }
        // The background is no object: nothing changes.
        let (mut s, _) = disc(8);
        let r = s.execute("select.object", json!({"point": [3, 3]})).unwrap();
        assert_eq!(r["changed"], false);
        assert!(s.active().unwrap().doc.selection.is_none());
        assert!(s.execute("select.object", json!({"point": ["a", 1]})).is_err());
    }

    #[test]
    fn object_preview_shows_the_object_without_selecting_it() {
        let (mut s, inside) = disc(8);
        let r = s.execute("select.objectPreview", json!({"point": [100, 80]})).unwrap();
        assert_eq!(r["found"], true);
        assert!(s.active().unwrap().doc.selection.is_none());
        let rect: Vec<i64> = r["rect"].as_array().unwrap().iter().map(|v| v.as_i64().unwrap()).collect();
        let (w, h) = (r["width"].as_u64().unwrap() as usize, r["height"].as_u64().unwrap() as usize);
        assert_eq!((w as i64, h as i64), (rect[2] - rect[0], rect[3] - rect[1]));
        let data = photocraft_paint::tile::b64_decode(r["data"].as_str().unwrap()).unwrap();
        let on = |x: i64, y: i64| data[((y - rect[1]) as usize) * w + (x - rect[0]) as usize] > 127;
        assert!(on(100, 80) && inside(100, 80) && !on(rect[0], rect[1]));
        assert_eq!(s.execute("select.objectPreview", json!({"point": [3, 3]})).unwrap()["found"], false);
        assert!(s.execute("select.objectPreview", json!({})).is_err());
    }

    #[test]
    fn object_selection_point_honours_the_modes() {
        let (mut s, _) = disc(8);
        s.execute("select.all", json!({})).unwrap();
        s.execute("select.object", json!({"point": [100, 80], "mode": "subtract"})).unwrap();
        assert!(cov(&s, 100, 80) < 0.5 && cov(&s, 3, 3) >= 0.5);
        s.execute("select.object", json!({"point": [100, 80], "mode": "add"})).unwrap();
        assert!(cov(&s, 100, 80) >= 0.5 && cov(&s, 3, 3) >= 0.5);
        s.execute("select.object", json!({"point": [100, 80], "mode": "intersect"})).unwrap();
        assert!(cov(&s, 100, 80) >= 0.5 && cov(&s, 3, 3) < 0.5);
    }

    #[test]
    fn object_finder_cache_serves_the_whole_object_until_pixels_change() {
        let (mut s, _) = disc(8);
        let d = s.active().unwrap();
        let doc = std::sync::Arc::clone(&d.doc);
        let target = sampled_target(&doc, d.active_layer, false);
        assert!(s.object_finder.lookup(&doc, target, 100.0, 80.0).is_none());
        let r = std::sync::Arc::new(find_object(&doc, d.active_layer, false, 100.0, 80.0).unwrap());
        s.object_finder.insert(&doc, target, std::sync::Arc::clone(&r));
        // Any point on the object hits; the background and another target miss.
        assert!(std::sync::Arc::ptr_eq(&s.object_finder.lookup(&doc, target, 120.0, 90.0).unwrap(), &r));
        assert!(s.object_finder.lookup(&doc, target, 3.0, 3.0).is_none());
        assert!(s.object_finder.lookup(&doc, Some(LayerId(u64::MAX)), 100.0, 80.0).is_none());
        // The click reuses it, and a selection-only edit keeps it.
        s.execute("select.object", json!({"point": [110, 70]})).unwrap();
        assert_eq!(s.object_finder.len(), 1);
        s.execute("select.deselect", json!({})).unwrap();
        let d = s.active().unwrap();
        assert!(s.object_finder.lookup(&std::sync::Arc::clone(&d.doc), target, 100.0, 80.0).is_some());
        // A pixel edit drops it.
        s.execute("paint.pencil", json!({"points": [[5, 5], [30, 5]], "size": 4, "color": "#000000"})).unwrap();
        assert!(s.object_finder.is_empty());
    }

    #[test]
    fn object_selection_disc() {
        for depth in [8, 16, 32] {
            let (mut s, inside) = disc(depth);
            s.execute("select.object", json!({"rect": [40, 20, 120, 120]})).unwrap();
            let v = sel_iou(&s, 200, 160, &inside);
            assert!(v > 0.95, "depth {depth}: IoU {v}");
        }
        let (mut s, _) = disc(8);
        assert!(s.execute("select.object", json!({"rect": [1, 2]})).is_err());
        // Negative width/height (drag up-left) work too.
        s.execute("select.object", json!({"rect": [160, 140, -120, -120]})).unwrap();
        assert!(cov(&s, 100, 80) >= 0.5);
    }

    #[test]
    fn object_selection_on_an_empty_active_layer_says_so() {
        // #5246: an empty layer above the photo used to find nothing without a word.
        let (mut s, inside) = disc(8);
        s.execute("layer.new.layer", json!({})).unwrap();
        for p in [json!({"rect": [40, 20, 120, 120]}), json!({"point": [100, 80]})] {
            let e = s.execute("select.object", p.clone()).unwrap_err().to_string();
            assert!(e.contains("active layer is empty") && e.contains("sampleAllLayers"), "{p}: {e}");
            assert!(s.active().unwrap().doc.selection.is_none());
        }
        // Sampling all layers finds the disc below.
        s.execute("select.object", json!({"rect": [40, 20, 120, 120], "sampleAllLayers": true})).unwrap();
        assert!(sel_iou(&s, 200, 160, &inside) > 0.95);
        // A layer with pixels elsewhere: the rectangle holds none of them.
        s.execute("select.deselect", json!({})).unwrap();
        s.execute("paint.pencil", json!({"points": [[5, 5], [10, 5]], "size": 2, "color": "#000000"})).unwrap();
        let e = s.execute("select.object", json!({"rect": [60, 60, 100, 80]})).unwrap_err().to_string();
        assert!(e.contains("no pixels in that area"), "{e}");
    }

    #[test]
    fn select_subject_centred_object() {
        let (mut s, inside) = disc(8);
        assert!(s.is_enabled("select.subject"));
        s.execute("select.subject", json!({})).unwrap();
        let v = sel_iou(&s, 200, 160, inside);
        assert!(v > 0.9, "IoU {v}");
        s.execute("edit.undo", json!({})).unwrap();
        assert!(s.active().unwrap().doc.selection.is_none());
    }

    /// #2865: a repeat on unchanged pixels reuses the last mask (an identical selection, even
    /// after Deselect); sampling something else or a pixel edit computes it again.
    #[test]
    fn select_subject_repeat_reuses_the_mask_until_pixels_change() {
        let (mut s, _) = disc(8);
        let sel = |s: &Session| {
            let mut v = Vec::new();
            s.active().unwrap().doc.selection.as_ref().unwrap().read_region_into(Rect::new(0, 0, 200, 160), &mut v);
            v
        };
        let cached = |s: &Session| s.subject_cache.region.clone().unwrap();
        s.execute("select.subject", json!({})).unwrap();
        let (first, mask) = (sel(&s), cached(&s));
        s.execute("select.deselect", json!({})).unwrap();
        s.execute("select.subject", json!({})).unwrap();
        assert!(std::sync::Arc::ptr_eq(&mask, &cached(&s)), "the repeat recomputed the mask");
        assert_eq!(sel(&s), first);
        // Another sampled target (the layer rather than the composite) is a miss.
        s.execute("select.subject", json!({"sampleAllLayers": false})).unwrap();
        assert!(!std::sync::Arc::ptr_eq(&mask, &cached(&s)));
        // A pixel edit drops the entry; the next run recomputes it.
        s.edit("paint", |doc, _| {
            let bg = doc.layers[0].surface_mut().unwrap();
            let n = bg.channels();
            bg.write_region(Rect::new(0, 0, 1, 1), &vec![1.0; n]);
            Ok(())
        })
        .unwrap();
        assert!(s.subject_cache.region.is_none());
        s.execute("select.subject", json!({})).unwrap();
        assert_eq!(sel(&s), first);
    }

    /// A vertical Gaussian-blurred edge at x = 40 (warm left, cool right) with the left half selected.
    fn blurred_edge_selected() -> Session {
        blurred_edge_selected_at(8)
    }

    fn blurred_edge_selected_at(depth: u32) -> Session {
        let mut s = session_with(80, 40, depth, |x, _| {
            let t = 1.0 / (1.0 + ((x as f32 + 0.5 - 40.0) / 1.8).exp());
            [0.9 * t + 0.1 * (1.0 - t), 0.8 * t + 0.2 * (1.0 - t), 0.2 * t + 0.6 * (1.0 - t)]
        });
        s.execute("select.rect", json!({"x": 0, "y": 0, "width": 40, "height": 40})).unwrap();
        s
    }

    fn soft_count(s: &photocraft_raster::Surface, y: i32) -> usize {
        (0..80)
            .filter(|x| {
                let v = s.sample_channel(*x, y, 0);
                v > 0.05 && v < 0.95
            })
            .count()
    }

    #[test]
    fn refine_edge_outputs_and_undo() {
        // Selection output: the hard edge becomes a soft matte following the blur.
        let mut s = blurred_edge_selected();
        assert!(s.is_enabled("select.refineEdge"));
        s.execute("select.refineEdge", json!({"radius": 8})).unwrap();
        let sel = s.active().unwrap().doc.selection.clone().unwrap();
        assert!(soft_count(&sel, 20) >= 4, "selection edge not soft");
        assert!(sel.sample_channel(5, 20, 0) > 0.99 && sel.sample_channel(75, 20, 0) < 0.01);
        s.execute("edit.undo", json!({})).unwrap();
        assert_eq!(soft_count(s.active().unwrap().doc.selection.as_ref().unwrap(), 20), 0);

        // Layer mask output.
        let layers_before = s.active().unwrap().doc.layer_count();
        let r = s.execute("select.refineEdge", json!({"radius": 8, "output": "layerMask"})).unwrap();
        let d = s.active().unwrap();
        let l = d.doc.layer(photocraft_doc::LayerId(r["layer"].as_u64().unwrap())).unwrap();
        let m = l.mask.as_ref().unwrap();
        assert!(soft_count(&m.surface, 20) >= 4);
        assert!(m.value(5, 20) > 0.99 && m.value(75, 20) < 0.01);
        assert!(d.doc.selection.is_none());
        assert_eq!(d.doc.layer_count(), layers_before);
        s.execute("edit.undo", json!({})).unwrap();
        assert!(s.active().unwrap().doc.layers[0].mask.is_none());
        assert!(s.active().unwrap().doc.selection.is_some());

        // Existing mask settings (density, feather, linked) are preserved
        s.edit("set mask", |doc, _| {
            doc.layers[0].mask = Some(photocraft_doc::LayerMask {
                surface: photocraft_raster::Surface::new(photocraft_color::PixelFormat::GRAY8),
                density: 0.75,
                feather: 3.5,
                linked: false,
                enabled: true,
            });
            Ok(())
        })
        .unwrap();
        let r = s.execute("select.refineEdge", json!({"radius": 8, "output": "layerMask"})).unwrap();
        let l = s.active().unwrap().doc.layer(photocraft_doc::LayerId(r["layer"].as_u64().unwrap())).unwrap();
        let m = l.mask.as_ref().unwrap();
        assert_eq!(m.density, 0.75);
        assert_eq!(m.feather, 3.5);
        assert!(!m.linked);
        s.execute("edit.undo", json!({})).unwrap();
        s.edit("clear mask", |doc, _| {
            doc.layers[0].mask = None;
            Ok(())
        })
        .unwrap();

        // New layer: pixels with the refined alpha; the source is hidden.
        let r = s.execute("select.refineEdge", json!({"radius": 8, "feather": 1, "output": "newLayer"})).unwrap();
        let d = s.active().unwrap();
        let nid = photocraft_doc::LayerId(r["layer"].as_u64().unwrap());
        assert_eq!(d.active_layer, Some(nid));
        assert_eq!(d.doc.layer_count(), layers_before + 1);
        let nl = d.doc.layer(nid).unwrap();
        let surf = nl.surface().unwrap();
        assert!(surf.format().alpha);
        let a = |x: i32| surf.pixel(x, 20)[3];
        assert!(a(5) > 0.99 && a(75) == 0.0 && a(40) > 0.05 && a(40) < 0.95);
        assert!(!d.doc.layers[0].visible);
        s.execute("edit.undo", json!({})).unwrap();
        assert_eq!(s.active().unwrap().doc.layer_count(), layers_before);
        assert!(s.active().unwrap().doc.layers[0].visible);

        // New layer with mask + decontamination (selection output upgrades to it).
        let r = s.execute("select.refineEdge", json!({"radius": 8, "decontaminate": true, "amount": 100})).unwrap();
        assert_eq!(r["output"], "newLayerWithMask");
        let d = s.active().unwrap();
        let nl = d.doc.layer(photocraft_doc::LayerId(r["layer"].as_u64().unwrap())).unwrap();
        assert!(nl.mask.is_some());
        let px = nl.surface().unwrap().pixel(41, 20);
        let orig = d.doc.layers[0].surface().unwrap().pixel(41, 20);
        // The fringe colour moved towards the warm foreground (more red, less blue).
        assert!(px[0] > orig[0] + 0.05 && px[2] < orig[2] - 0.05, "{px:?} vs {orig:?}");
        s.execute("edit.undo", json!({})).unwrap();
        assert!(s.execute("select.refineEdge", json!({"output": "bogus"})).is_err());
        s.execute("select.deselect", json!({})).unwrap();
        assert!(!s.is_enabled("select.refineEdge"));
    }

    /// Output To New Document (with or without a layer mask) opens a document like the source,
    /// at every depth, and leaves the source document as it was.
    #[test]
    fn refine_edge_outputs_to_a_new_document() {
        for depth in [8, 16, 32] {
            let mut s = blurred_edge_selected_at(depth);
            s.edit("profile", |doc, _| {
                doc.resolution_dpi = 300.0;
                Ok(())
            })
            .unwrap();
            let before = s.active().unwrap().doc.clone();
            let r = s.execute("select.refineEdge", json!({"radius": 8, "output": "newDocument"})).unwrap();
            assert_eq!((r["output"].as_str(), r["document"].as_u64()), (Some("newDocument"), Some(1)), "depth {depth}");
            assert_eq!(s.active_index(), Some(1));
            let nd = &s.active().unwrap().doc;
            assert_eq!((nd.size, nd.mode, nd.depth, nd.resolution_dpi), (before.size, before.mode, before.depth, 300.0));
            assert_eq!(nd.layers.len(), 1);
            assert!(nd.selection.is_none() && nd.layers[0].mask.is_none());
            let surf = nd.layers[0].surface().unwrap();
            let a = |x: i32| surf.pixel(x, 20)[3];
            assert!(a(5) > 0.99 && a(75) == 0.0 && a(40) > 0.05 && a(40) < 0.95, "depth {depth}: {} {} {}", a(5), a(40), a(75));
            // The source is untouched: same layers, still visible, selection kept, no history step.
            let src = &s.documents()[0];
            assert_eq!(src.doc.layers, before.layers);
            assert_eq!(src.doc.selection, before.selection);
            assert_eq!(src.history.undo_label(), Some("profile"));

            // With a layer mask: full pixels, the refined matte as the mask.
            s.execute("file.close", json!({"document": 1})).unwrap();
            let r = s.execute("select.refineEdge", json!({"radius": 8, "output": "newDocumentWithMask"})).unwrap();
            assert_eq!(r["output"], "newDocumentWithMask");
            let nd = &s.active().unwrap().doc;
            let l = &nd.layers[0];
            assert_eq!(l.surface().unwrap().pixel(75, 20), before.layers[0].surface().unwrap().pixel(75, 20), "depth {depth}");
            let m = l.mask.as_ref().unwrap();
            assert!(soft_count(&m.surface, 20) >= 4, "depth {depth}");
            assert!(m.value(5, 20) > 0.99 && m.value(75, 20) < 0.01, "depth {depth}");
        }
    }

    #[test]
    fn refine_edge_shift_and_contrast() {
        let mut s = blurred_edge_selected();
        s.execute("select.refineEdge", json!({"shiftEdge": 100})).unwrap();
        assert!(cov(&s, 42, 20) > 0.99);
        s.execute("edit.undo", json!({})).unwrap();
        s.execute("select.refineEdge", json!({"feather": 8, "contrast": 100})).unwrap();
        assert!(cov(&s, 38, 20) == 1.0 && cov(&s, 42, 20) == 0.0);
    }

    #[test]
    fn refine_edge_rejects_brush_strokes() {
        let mut s = blurred_edge_selected();
        let stroke = json!([{"points": [[70, 5], [70, 35]], "size": 30}]);
        assert!(s.execute("select.refineEdge", json!({"radius": 4, "refineStrokes": stroke})).is_err());
    }

    #[test]
    fn refine_edge_works_on_layer_mask_without_selection() {
        let mut s = blurred_edge_selected();
        s.execute("layer.layerMask.revealSelection", json!({})).unwrap();
        assert!(s.active().unwrap().doc.selection.is_none());
        assert!(s.active().unwrap().doc.layers[0].mask.is_some());
        assert!(s.is_enabled("select.refineEdge"));

        let r = s.execute("select.refineEdge", json!({"radius": 8})).unwrap();
        assert_eq!(r["output"], "layerMask");
        let d = s.active().unwrap();
        let m = d.doc.layers[0].mask.as_ref().unwrap();
        assert!(soft_count(&m.surface, 20) >= 4);
    }

    #[test]
    fn focus_area_command() {
        let nz = noise_field(160, 100, 3);
        let mut blurred = vec![0.0f32; nz.len()];
        for y in 0..100i32 {
            for x in 0..160i32 {
                let mut a = 0.0;
                for dy in -4..=4 {
                    for dx in -4..=4 {
                        a += nz[((y + dy).clamp(0, 99) * 160 + (x + dx).clamp(0, 159)) as usize];
                    }
                }
                blurred[(y * 160 + x) as usize] = a / 81.0;
            }
        }
        let mut s = session_with(160, 100, 8, move |x, y| {
            let i = (y * 160 + x) as usize;
            let v = 0.5 + 0.15 * if x < 80 { nz[i] } else { blurred[i] * 3.0 };
            [v, v, v].map(|c| c.clamp(0.0, 1.0))
        });
        s.execute("select.focusArea", json!({})).unwrap();
        assert!(cov(&s, 30, 50) >= 0.5 && cov(&s, 130, 50) < 0.5);
    }
    #[test]
    fn a_mask_from_elsewhere_becomes_the_selection() {
        let mut s = Session::new();
        s.execute("file.new", json!({"width": 40, "height": 20})).unwrap();
        // 4 × 2 mask, left half in, stretched over the document.
        let data = photocraft_paint::tile::b64_encode(&[255, 255, 0, 0, 255, 255, 0, 0]);
        let r = s.execute("select.fromMask", json!({"width": 4, "height": 2, "data": data, "label": "Object Selection"})).unwrap();
        assert_eq!(r["bounds"], json!([0, 0, 20, 20]));
        let d = s.active().unwrap();
        assert_eq!(d.history.entries().last().map(String::as_str), Some("Object Selection"));
        let r = s
            .execute(
                "select.fromMask",
                json!({"width": 1, "height": 1, "data": photocraft_paint::tile::b64_encode(&[255]), "rect": [30, 0, 40, 10], "mode": "add"}),
            )
            .unwrap();
        assert_eq!(r["selected"], true);
        assert_eq!(s.active().unwrap().doc.selection.as_ref().unwrap().content_bounds().width(), 40);
        for bad in [
            json!({}),
            json!({"width": 2, "height": 2, "data": "AA=="}),
            json!({"width": 0, "height": 1, "data": ""}),
            json!({"width": 1, "height": 1, "data": "AA==", "rect": [5, 5, 1, 1]}),
        ] {
            assert!(s.execute("select.fromMask", bad.clone()).is_err(), "{bad}");
        }
    }

    #[test]
    fn refine_hair_takes_the_mask_only_near_the_edge() {
        let mut s = Session::new();
        s.execute("file.new", json!({"width": 60, "height": 20})).unwrap();
        let all = photocraft_paint::tile::b64_encode(&[255]);
        let p = json!({"width": 1, "height": 1, "data": all, "band": 4});
        assert!(s.execute("select.fromMask", p.clone()).is_err(), "needs a selection");
        s.execute("select.rect", json!({"x": 20, "y": 0, "width": 20, "height": 20})).unwrap();
        s.execute("select.fromMask", p).unwrap();
        let sel = s.active().unwrap().doc.selection.clone().unwrap();
        // The mask (everything) is taken within 4 px of the edge; farther out stays unselected.
        assert!(sel.sample_channel(17, 10, 0) > 0.99 && sel.sample_channel(30, 10, 0) > 0.99);
        assert!(sel.sample_channel(10, 10, 0) < 0.01);
        assert!(s.execute("select.fromMask", json!({"width": 1, "height": 1, "data": photocraft_paint::tile::b64_encode(&[255]), "band": 0})).is_err());
    }

    #[test]
    fn object_selection_takes_the_whole_figure_not_one_colour() {
        // A brown head on a blue body, on a beige backdrop: tapping the body takes the head too.
        let mut s = Session::new();
        s.execute("file.new", json!({"width": 300, "height": 200, "background": "#f4e6c8"})).unwrap();
        s.execute("select.rect", json!({"x": 125, "y": 40, "width": 50, "height": 50})).unwrap();
        s.execute("edit.fill", json!({"color": "#5c3a2c"})).unwrap();
        s.execute("select.rect", json!({"x": 100, "y": 90, "width": 100, "height": 110})).unwrap();
        s.execute("edit.fill", json!({"color": "#244678"})).unwrap();
        s.execute("select.deselect", json!({})).unwrap();
        let r = s.execute("select.object", json!({"point": [150, 150]})).unwrap();
        let b = s.active().unwrap().doc.selection.as_ref().unwrap().content_bounds();
        assert!(b.y0 <= 45 && b.y1 >= 195 && b.x0 >= 90 && b.x1 <= 210, "{b:?} {r}");
    }
}

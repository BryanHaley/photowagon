//! The Remove Tool as a command: paint over something and it is replaced by its surroundings.
//!
//! The stroke's footprint is the hole. A stroke that closes around an object also removes what it
//! encloses (`closeLoops`), and the hole grows by [`GROW`] pixels so the object's soft edge and
//! halo go with it. The hole is completed from a window around the stroke by the exemplar
//! fill (`photocraft_algo::remove`). The
//! selection, when there is one, limits what changes. Large holes take seconds, so the command
//! runs as a background job (#210): with progress, cancellable, and the document unchanged until
//! it applies, in one undo step.
//!
//! Several strokes can go in one removal (`strokes`): Photoshop's *Remove after each stroke*
//! off, where the strokes collect and are applied together, so the fill sees every hole at once
//! instead of sampling from an area the next stroke is about to remove. With `newLayer` the fill
//! lands on a new layer above the target, only where the hole is, and the target stays as it was
//! (Photoshop's *Create a new layer*; with Sample All Layers it fills from the composite).
//!
//! AI Remove fills the hole with an on-device model the app runs: `paint.removeAI` hands it a
//! fixed square cut from the image at full size, and `paint.remove` with `ai.fill` pastes the
//! model's square back, only where the hole is. Nothing is scaled, so the hole must fit the square.

use super::content_aware_move::{Target, replace};
use super::patch::coverage;
use super::*;
use photocraft_doc::Layer;

const CMD: &str = "paint.remove";
pub(super) const AI_CMD: &str = "paint.removeAI";

/// Largest stroke, in pixels of its bounding box (as the Patch Tool's and Content-Aware Move's).
/// Checked before the stroke's coverage is rendered, which allocates its whole bounding box, also
/// where it leaves the canvas.
const MAX_PIXELS: u64 = 16 << 20;

/// Cap on the sampling margin around the stroke (the window grows with the stroke).
const MAX_MARGIN: i32 = 512;

/// How far the hole grows beyond the stroke, in pixels.
const GROW: usize = 2;

/// How far a selection's hole grows: selections (Vision's especially) sit a little inside the
/// object's edge, and a hole the object's exact shape makes the model draw it again. 2% of the
/// image's longer side, 4 to 24 pixels.
fn selection_grow(canvas: Rect) -> usize {
    (canvas.width().max(canvas.height()) as usize / 50).clamp(4, 24)
}

/// How far an AI Remove stroke's hole grows: a little background round what was painted, for
/// matching the colour and fading the fill in.
const AI_GROW: usize = 4;

/// Seed of the completion, so a removal is reproducible.
const SEED: u64 = 0x0052_e30e;

/// AI Remove: context kept round the hole, where the canvas allows. When the hole and this
/// margin don't fit the model's square at full size, they're scaled down to fit.
const AI_MARGIN: i32 = 128;

/// The model's square side by default (`ai.side`), and its limits.
const AI_SIDE: u32 = 800;
const AI_SIDES: std::ops::RangeInclusive<u32> = 64..=2048;

/// AI Remove's request: the model's square and, to apply, what it filled the square with (RGB8).
struct Ai {
    side: u32,
    fill: Option<Vec<u8>>,
    /// The window's size in the square: 1 at full size, less when it's scaled down to fit.
    scale: f64,
    /// Blend the fill in so it takes the colour round the hole (`ai.matchColor`).
    match_color: bool,
}

fn parse_ai(cmd: &str, a: &Value) -> Result<Ai> {
    let side = match a.get("side") {
        None => AI_SIDE,
        Some(v) => v.as_u64().and_then(|v| u32::try_from(v).ok()).filter(|v| AI_SIDES.contains(v)).ok_or_else(|| bad(cmd, "`ai.side` is 64..2048"))?,
    };
    let fill = match a.get("fill") {
        None | Some(Value::Null) => None,
        Some(v) => {
            let bytes = v.as_str().and_then(photocraft_paint::tile::b64_decode).ok_or_else(|| bad(cmd, "`ai.fill` must be base64 bytes"))?;
            let want = side as usize * side as usize * 3;
            if bytes.len() != want {
                return Err(bad(cmd, format!("`ai.fill` has {} bytes, not {want} (side × side RGB)", bytes.len())));
            }
            Some(bytes)
        }
    };
    let match_color = a.get("matchColor").and_then(Value::as_bool).unwrap_or(true);
    Ok(Ai { side, fill, scale: 1.0, match_color })
}

/// The window the model fills and its scale in the square: `side` (or the canvas, if smaller)
/// centred on the stroke at full size; a hole too big for that is the stroke plus a margin,
/// scaled down to fit, keeping its shape.
fn ai_window(area: Rect, canvas: Rect, side: u32) -> (Rect, f64) {
    let (w, h) = (side.min(canvas.width()), side.min(canvas.height()));
    let need = area.inflate(AI_MARGIN).intersect(&canvas);
    if need.width() > w || need.height() > h {
        return (need, f64::from(side) / f64::from(need.width().max(need.height()).max(1)));
    }
    let at = |lo: i32, len: u32, min: i32, max: i32, span: u32| {
        let start = lo.saturating_add(len as i32 / 2).saturating_sub(span as i32 / 2);
        start.clamp(min, max.saturating_sub(span as i32).max(min))
    };
    let x = at(need.x0, need.width(), canvas.x0, canvas.x1, w);
    let y = at(need.y0, need.height(), canvas.y0, canvas.y1, h);
    (Rect::from_xywh(x, y, w, h), 1.0)
}

/// `img` (`w` × `h`, `n` bytes a pixel) shrunk to `sw` × `sh` by averaging, or with `max`, by
/// the largest value under each pixel (so a mask's hole is never lost).
fn shrink(img: &[u8], w: usize, h: usize, n: usize, sw: usize, sh: usize, max: bool) -> Vec<u8> {
    let mut out = vec![0u8; sw * sh * n];
    for dy in 0..sh {
        let (y0, y1) = (dy * h / sh, ((dy + 1) * h / sh).max(dy * h / sh + 1).min(h));
        for dx in 0..sw {
            let (x0, x1) = (dx * w / sw, ((dx + 1) * w / sw).max(dx * w / sw + 1).min(w));
            for c in 0..n {
                let (mut sum, mut top, mut count) = (0u32, 0u8, 0u32);
                for y in y0..y1 {
                    for x in x0..x1 {
                        let v = img.get((y * w + x) * n + c).copied().unwrap_or(0);
                        (sum, top, count) = (sum + u32::from(v), top.max(v), count + 1);
                    }
                }
                if let Some(o) = out.get_mut((dy * sw + dx) * n + c) {
                    *o = if max { top } else { (sum / count.max(1)) as u8 };
                }
            }
        }
    }
    out
}

/// How many colour channels the model's RGB maps to: 3 for RGB, 1 for Grayscale (and masks).
fn ai_colours(cmd: &str, fmt: &PixelFormat) -> Result<usize> {
    match fmt.mode {
        photocraft_color::ColorMode::Rgb => Ok(3),
        photocraft_color::ColorMode::Grayscale => Ok(1),
        _ => Err(bad(cmd, "AI Remove works on RGB and Grayscale images (Image › Mode › RGB Color first)")),
    }
}

/// The sampling margin around the stroke: three quarters of its larger side, at least 32 pixels
/// (in u64, so a huge extent can't overflow; a margin beyond i32 saturates).
fn sampling_margin(area: Rect) -> i32 {
    let ext = u64::from(area.width().max(area.height()));
    i32::try_from(ext * 3 / 4).unwrap_or(i32::MAX).max(32)
}

/// What a removal does, checked before any work starts.
struct Plan {
    id: Option<LayerId>,
    /// One stroke (`points`), or several applied together (`strokes`).
    strokes: Vec<Stroke>,
    /// Where the fill samples from: the strokes plus a margin, on the canvas.
    window: Rect,
    close_loops: bool,
    all_layers: bool,
    /// The fill goes to a new layer above the target instead of into it.
    new_layer: bool,
    /// AI Remove: the window is the model's square.
    ai: Option<Ai>,
    /// The hole is the selection (no strokes).
    from_selection: bool,
    /// How far the hole grows past the strokes or the selection.
    grow: usize,
}

/// The stroke's bounding box (points ± the brush radius), before any coverage is rendered.
fn stroke_bounds(stroke: &Stroke) -> Rect {
    let r = f64::from(stroke.brush.size) / 2.0 + 2.0;
    let (mut x0, mut y0, mut x1, mut y1) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
    for q in &stroke.points {
        (x0, y0, x1, y1) = (x0.min(q.x), y0.min(q.y), x1.max(q.x), y1.max(q.y));
    }
    // `check_coords` keeps points within ±MAX_COORD and sizes are capped, so these fit an i32.
    Rect::new((x0 - r).floor() as i32, (y0 - r).floor() as i32, (x1 + r).ceil() as i32, (y1 + r).ceil() as i32)
}

/// The strokes of the request: `strokes` (several, each a list of points, sharing the brush
/// and the target) or the one in `points`.
fn parse_strokes(s: &Session, p: &Value) -> Result<(Vec<Stroke>, Option<LayerId>)> {
    let Some(list) = p.get("strokes") else {
        let (stroke, id) = parse_brush(s, p, CMD)?;
        reject_huge_stroke(CMD, &stroke)?;
        return Ok((vec![stroke], id));
    };
    let list = list.as_array().ok_or_else(|| bad(CMD, "`strokes` is a list of point lists"))?;
    if list.is_empty() {
        return Err(bad(CMD, "`strokes` is empty"));
    }
    let mut strokes = Vec::with_capacity(list.len());
    let mut id = None;
    for points in list {
        let mut one = p.clone();
        if let Some(o) = one.as_object_mut() {
            o.remove("strokes");
            o.insert("points".into(), points.clone());
        }
        let (stroke, layer) = parse_brush(s, &one, CMD)?;
        reject_huge_stroke(CMD, &stroke)?;
        strokes.push(stroke);
        id = layer;
    }
    Ok((strokes, id))
}

fn plan(s: &Session, p: &Value, cmd: &str) -> Result<Plan> {
    let from_selection = flag(p, "selection", false);
    let (strokes, id) = if from_selection { (Vec::new(), super::patch::target_layer(s, p)?) } else { parse_strokes(s, p)? };
    let d = s.active().ok_or(EngineError::NoDocument)?;
    let canvas = d.doc.bounds();
    let grow = if from_selection {
        selection_grow(canvas)
    } else if p.get("ai").is_some_and(|a| !a.is_null()) {
        AI_GROW
    } else {
        GROW
    };
    let bounds = if from_selection {
        let sel = d.doc.selection.as_ref().ok_or_else(|| bad(cmd, "select what to remove first"))?;
        Some(sel.content_bounds().inflate(grow as i32)).filter(|r| !r.is_empty()).ok_or_else(|| bad(cmd, "the selection is empty"))?
    } else {
        strokes.iter().map(stroke_bounds).reduce(|a, b| a.union(&b)).ok_or_else(|| bad(CMD, "`strokes` is empty"))?
    };
    let pixels = u64::from(bounds.width()) * u64::from(bounds.height());
    if pixels > MAX_PIXELS {
        return Err(bad(CMD, format!("the stroke is too large to remove ({pixels} pixels, at most {MAX_PIXELS})")));
    }
    let area = bounds.intersect(&canvas);
    if area.is_empty() {
        return Err(bad(CMD, "the stroke is outside the canvas"));
    }
    let mut ai = match p.get("ai") {
        None | Some(Value::Null) => None,
        Some(a) => Some(parse_ai(cmd, a)?),
    };
    let window = match &mut ai {
        Some(ai) => {
            let (win, scale) = ai_window(area, canvas, ai.side);
            ai.scale = scale;
            win
        }
        None => area.inflate(sampling_margin(area).min(MAX_MARGIN)).intersect(&canvas),
    };
    let close_loops = flag(p, "closeLoops", true);
    let all_layers = flag(p, "sampleAllLayers", false) && targets_pixels(p);
    // A mask or channel has no "above": the fill goes where the stroke went.
    let new_layer = flag(p, "newLayer", false) && targets_pixels(p);
    Ok(Plan { id, strokes, window, close_loops, all_layers, new_layer, ai, from_selection, grow })
}

/// The hole over the plan's window: the strokes' footprints, their enclosed areas and a margin,
/// limited to the selection. Empty when nothing would change.
fn hole(plan: &Plan, sel: Option<&Surface>) -> Result<Vec<bool>> {
    let win = plan.window;
    let (w, h) = (win.width() as usize, win.height() as usize);
    let mut m = vec![false; w * h];
    for stroke in &plan.strokes {
        let (bounds, cov) = super::coverage(CMD, stroke)?;
        let bw = bounds.width() as usize;
        for (i, c) in cov.iter().enumerate() {
            let (x, y) = (bounds.x0 + (i % bw.max(1)) as i32, bounds.y0 + (i / bw.max(1)) as i32);
            if *c > 0.0 && win.contains(x, y) {
                let j = (y - win.y0) as usize * w + (x - win.x0) as usize;
                if let Some(v) = m.get_mut(j) {
                    *v = true;
                }
            }
        }
    }
    if plan.from_selection {
        let sel = sel.ok_or_else(|| bad(CMD, "select what to remove first"))?;
        // Every pixel the selection touches, even faintly at a soft edge.
        let m: Vec<bool> = coverage(sel, win).into_iter().map(|c| c > 0.05).collect();
        return Ok(photocraft_algo::remove::dilate(w, h, &m, plan.grow));
    }
    if plan.close_loops {
        m = photocraft_algo::remove::close_loops(w, h, &m);
    }
    m = photocraft_algo::remove::dilate(w, h, &m, plan.grow);
    if let Some(sel) = sel {
        for (v, c) in m.iter_mut().zip(coverage(sel, win)) {
            *v &= c > 0.0;
        }
    }
    Ok(m)
}

/// The hole over the plan's window, refused when nothing would change or nothing is left to fill
/// from.
fn checked_hole(plan: &Plan, doc: &Document) -> Result<Vec<bool>> {
    let hole = hole(plan, doc.selection.as_ref())?;
    if !hole.iter().any(|m| *m) {
        return Err(bad(CMD, "the stroke doesn't cover anything that can change (check the selection)"));
    }
    if hole.iter().all(|m| *m) {
        return Err(bad(CMD, "nothing is left around the stroke to fill it from"));
    }
    Ok(hole)
}

/// The window's pixels: the target's, or the composite with Sample All Layers.
fn window_image(doc: &mut Document, plan: &Plan, p: &Value) -> Result<(Region, PixelFormat)> {
    let win = plan.window;
    let (surf, _) = crate::channel_cmds::target_surface(doc, plan.id, p)?;
    let fmt = surf.format();
    let img = if plan.all_layers { composite_region(doc, None, SampleLayers::All, win, fmt) } else { Region::read(surf, win) };
    Ok((img, fmt))
}

/// The filled window and the hole it fills, computed on `doc` (a snapshot). `None` when the
/// layer's own window is fully transparent: nothing to remove and nothing to fill from.
fn run_remove(doc: &mut Document, plan: &Plan, p: &Value, ctx: &crate::jobs::JobCtx, label: &str) -> Result<Option<(Region, Vec<bool>)>> {
    let hole = checked_hole(plan, doc)?;
    ctx.check()?;
    let win = plan.window;
    let (img, fmt) = window_image(doc, plan, p)?;
    // A no-op without the fill or a history step, as the other retouch tools on an empty layer.
    if !plan.all_layers && alpha_index(&fmt).is_some_and(|a| img.data.chunks_exact(img.ch).all(|px| px.get(a).is_none_or(|v| *v <= 0.0))) {
        return Ok(None);
    }
    let (w, h) = (win.width() as usize, win.height() as usize);
    let mut data = match &plan.ai {
        Some(ai) => {
            let fill = ai.fill.as_deref().ok_or_else(|| bad(CMD, "`ai.fill` is missing: run paint.removeAI and the model first"))?;
            paste_ai(&img, &fmt, &hole, ai, fill, plan.grow)?
        }
        None => ctx
            .stage(0.0, 1.0, label, |ctl| photocraft_algo::remove::remove_with(w, h, img.ch, &img.data, &hole, SEED, ctl))
            .map_err(|_| EngineError::Cancelled)?,
    };
    // The fill's seam blending can step slightly past the storable range.
    clamp_samples(&fmt, &mut data);
    Ok(Some((Region { rect: win, ch: img.ch, data }, hole)))
}

/// The window's size inside the square.
fn scaled_size(w: usize, h: usize, ai: &Ai) -> (usize, usize) {
    let side = ai.side as usize;
    let at = |n: usize| ((n as f64 * ai.scale).round() as usize).clamp(1, side);
    if ai.scale >= 1.0 { (w.min(side), h.min(side)) } else { (at(w), at(h)) }
}

/// The window with the model's square (RGB8, the window at its top left, scaled back up when it
/// was scaled down) in the hole, fading in over the margin it grew by (`grow`). With Match Colour its levels are matched
/// to the pixels round the hole and it's cloned in seamlessly. Alpha and everything outside the
/// hole stay.
fn paste_ai(img: &Region, fmt: &PixelFormat, hole: &[bool], ai: &Ai, fill: &[u8], grow: usize) -> Result<Vec<f32>> {
    let colours = ai_colours(CMD, fmt)?;
    let (w, h, ch) = (img.rect.width() as usize, img.rect.height() as usize, img.ch);
    if w == 0 || h == 0 || hole.len() != w * h || img.data.len() != w * h * ch || ch < colours {
        return Err(EngineError::Other("internal error: the AI fill's window doesn't match".into()));
    }
    let side = ai.side as usize;
    let (sw, sh) = scaled_size(w, h, ai);
    let at = |x: usize, y: usize, c: usize| fill.get((y.min(sh - 1) * side + x.min(sw - 1)) * 3 + c).map_or(0.0, |v| f32::from(*v) / 255.0);
    let sample = |x: usize, y: usize| -> [f32; 3] {
        if (sw, sh) == (w, h) {
            return [at(x, y, 0), at(x, y, 1), at(x, y, 2)];
        }
        let u = ((x as f64 + 0.5) * sw as f64 / w as f64 - 0.5).max(0.0);
        let v = ((y as f64 + 0.5) * sh as f64 / h as f64 - 0.5).max(0.0);
        let (x0, y0) = (u as usize, v as usize);
        let (fx, fy) = ((u - x0 as f64) as f32, (v - y0 as f64) as f32);
        [0, 1, 2].map(|c| {
            let top = at(x0, y0, c) * (1.0 - fx) + at(x0 + 1, y0, c) * fx;
            let bottom = at(x0, y0 + 1, c) * (1.0 - fx) + at(x0 + 1, y0 + 1, c) * fx;
            top * (1.0 - fy) + bottom * fy
        })
    };
    // The model's picture over the whole window, so its colour drift shows at the hole's edge.
    let mut src = img.data.clone();
    for (i, px) in src.chunks_exact_mut(ch).enumerate() {
        let rgb = sample(i % w, i / w);
        if colours == 3 {
            px.iter_mut().zip(rgb).for_each(|(d, s)| *d = s);
        } else if let Some(g) = px.first_mut() {
            *g = rgb.iter().sum::<f32>() / 3.0;
        }
    }
    // A pixel in the square is 1 / scale pixels here.
    let per = 1.0 / ai.scale.min(1.0);
    let filled = if ai.match_color {
        let ring = (24.0 * per).round().clamp(8.0, 128.0) as u16;
        match_levels(w, h, ch, colours, &mut src, &img.data, hole, ring);
        // Matched against a ring inside the hole, half its growth in: background (the hole grew
        // past what's removed), and clear of the model's last pixels, which come out too bright or
        // dark, as does its redraw of the pixels outside the hole.
        let from = (grow / 2).max(3).min(usize::from(u16::MAX)) as u16;
        let inner: Vec<bool> = distance_inside(w, h, hole, from).into_iter().map(|d| d >= from).collect();
        spread_ring(w, h, ch, &mut src, &img.data, &inner);
        photocraft_algo::poisson::seamless_clone(w, h, ch, &src, &img.data, &inner)
    } else {
        src
    };
    // Fade in over the hole's edge, inside the hole only, and only over the outer half of what
    // it grew by: inside that is what's being removed, which would show through.
    let feather = (4.0 * per).ceil().min((grow / 2) as f64).clamp(1.0, 48.0) as u16;
    let depth = distance_inside(w, h, hole, feather);
    let mut out = img.data.clone();
    for (i, (o, f)) in out.chunks_exact_mut(ch).zip(filled.chunks_exact(ch)).enumerate() {
        let k = depth.get(i).map_or(0.0, |d| f32::from(*d) / f32::from(feather));
        if k > 0.0 {
            o.iter_mut().zip(f).take(colours).for_each(|(o, f)| *o += (*f - *o) * k);
        }
    }
    Ok(out)
}

/// Shifts and scales each colour channel of `src` so the hole's average and contrast match those
/// of `img` in a ring `ring` pixels wide round the hole (the model's overall cast and haze).
#[allow(clippy::too_many_arguments)]
fn match_levels(w: usize, h: usize, ch: usize, colours: usize, src: &mut [f32], img: &[f32], hole: &[bool], ring: u16) {
    let outside: Vec<bool> = hole.iter().map(|m| !m).collect();
    let near = distance_inside(w, h, &outside, ring);
    let stats = |data: &[f32], c: usize, pick: &dyn Fn(usize) -> bool| {
        let (mut n, mut sum, mut sq) = (0f64, 0f64, 0f64);
        for (i, px) in data.chunks_exact(ch).enumerate() {
            if pick(i) {
                let v = f64::from(px.get(c).copied().unwrap_or(0.0));
                (n, sum, sq) = (n + 1.0, sum + v, sq + v * v);
            }
        }
        let mean = sum / n.max(1.0);
        (n, mean, (sq / n.max(1.0) - mean * mean).max(0.0).sqrt())
    };
    for c in 0..colours {
        let (nr, mr, sr) = stats(img, c, &|i| near.get(i).is_some_and(|d| *d > 0 && *d < ring));
        let (nh, mh, sh) = stats(src, c, &|i| hole.get(i) == Some(&true));
        if nr < 16.0 || nh < 1.0 {
            return;
        }
        let gain = if sh > 1e-4 { (sr / sh).clamp(0.75, 1.5) } else { 1.0 };
        for px in src.chunks_exact_mut(ch) {
            if let Some(v) = px.get_mut(c) {
                *v = ((f64::from(*v) - mh) * gain + mr) as f32;
            }
        }
    }
}

/// `i` folded back into `0..n` as a mirror does (`n - 1, n - 2, …` past the end, and so on).
fn mirror(i: usize, n: usize) -> usize {
    let n = n.max(1);
    let m = i % (2 * n);
    if m < n { m } else { 2 * n - 1 - m }
}

/// Outside `inner`, gives every pixel the difference from `img` of the nearest pixel on its edge,
/// so the clone sees only that ring's colour difference (its fast solve also reads pixels further
/// out, like the model's unreliable last pixels in the hole).
fn spread_ring(w: usize, h: usize, ch: usize, src: &mut [f32], img: &[f32], inner: &[bool]) {
    let n = w * h;
    let mut from: Vec<usize> = vec![usize::MAX; n];
    let mut queue = std::collections::VecDeque::new();
    let near = |i: usize| -> [Option<usize>; 4] {
        let (x, y) = (i % w, i / w);
        [(x > 0).then(|| i - 1), (x + 1 < w).then(|| i + 1), (y > 0).then(|| i - w), (y + 1 < h).then(|| i + w)]
    };
    for i in 0..n {
        if !inner[i] && near(i).iter().flatten().any(|&j| inner[j]) {
            from[i] = i;
            queue.push_back(i);
        }
    }
    while let Some(i) = queue.pop_front() {
        for j in near(i).into_iter().flatten() {
            if !inner[j] && from[j] == usize::MAX {
                from[j] = from[i];
                queue.push_back(j);
            }
        }
    }
    for (i, &r) in from.iter().enumerate() {
        if r == usize::MAX || r == i {
            continue;
        }
        for c in 0..ch {
            let (Some(&ri), Some(&rs), Some(&ii)) = (img.get(r * ch + c), src.get(r * ch + c), img.get(i * ch + c)) else { continue };
            if let Some(v) = src.get_mut(i * ch + c) {
                *v = ii - (ri - rs);
            }
        }
    }
}

/// For each pixel where `mask` is set, how far it is from the nearest unset pixel (city-block, at
/// most `cap`); 0 elsewhere.
fn distance_inside(w: usize, h: usize, mask: &[bool], cap: u16) -> Vec<u16> {
    let mut d: Vec<u16> = mask.iter().map(|m| if *m { cap } else { 0 }).collect();
    for i in 0..d.len() {
        let (x, y) = (i % w, i / w);
        let mut v = d[i];
        if x > 0 {
            v = v.min(d[i - 1].saturating_add(1));
        }
        if y > 0 {
            v = v.min(d[i - w].saturating_add(1));
        }
        d[i] = v;
    }
    for i in (0..d.len()).rev() {
        let (x, y) = (i % w, i / w);
        let mut v = d[i];
        if x + 1 < w {
            v = v.min(d[i + 1].saturating_add(1));
        }
        if y + 1 < h {
            v = v.min(d[i + w].saturating_add(1));
        }
        d[i] = v;
    }
    d
}

/// `paint.removeAI`: what the model fills, as `side` × `side` RGB8 and a mask (255 = the hole).
/// The window sits at the top left, scaled down when it's bigger than the square; past it the
/// window is mirrored, holes and all.
pub(super) fn ai_input(s: &mut Session, p: &Value) -> Result<Value> {
    let mut q = p.clone();
    if let Some(o) = q.as_object_mut() {
        let mut ai = o.get("ai").filter(|a| a.is_object()).cloned().unwrap_or_else(|| json!({}));
        if let Some(a) = ai.as_object_mut() {
            a.remove("fill");
        }
        o.insert("ai".into(), ai);
    }
    let plan = plan(s, &q, AI_CMD)?;
    let ai = plan.ai.as_ref().ok_or_else(|| bad(AI_CMD, "`ai` is missing"))?;
    let side = ai.side as usize;
    let d = s.active().ok_or(EngineError::NoDocument)?;
    let mut doc = (*d.doc).clone();
    let hole = checked_hole(&plan, &doc)?;
    let (img, fmt) = window_image(&mut doc, &plan, &q)?;
    let colours = ai_colours(AI_CMD, &fmt)?;
    let (w, h) = (plan.window.width() as usize, plan.window.height() as usize);
    let to8 = |v: f32| (v.clamp(0.0, 1.0) * 255.0).round() as u8;
    let mut full = Vec::with_capacity(w * h * 3);
    for px in img.data.chunks_exact(img.ch.max(1)) {
        let c = |k: usize| to8(px.get(if colours == 3 { k } else { 0 }).copied().unwrap_or(0.0));
        full.extend([c(0), c(1), c(2)]);
    }
    let full_mask: Vec<u8> = hole.iter().map(|m| if *m { 255 } else { 0 }).collect();
    let (sw, sh) = scaled_size(w, h, ai);
    let (small, small_mask) =
        if (sw, sh) == (w, h) { (full, full_mask) } else { (shrink(&full, w, h, 3, sw, sh, false), shrink(&full_mask, w, h, 1, sw, sh, true)) };
    let (mut image, mut mask) = (Vec::with_capacity(side * side * 3), Vec::with_capacity(side * side));
    for y in 0..side {
        for x in 0..side {
            // Past the window, its mirror image (a repeated row or column reads as stripes).
            let j = mirror(y, sh) * sw + mirror(x, sw);
            image.extend(small.get(j * 3..j * 3 + 3).unwrap_or(&[0; 3]));
            mask.push(small_mask.get(j).copied().unwrap_or(0));
        }
    }
    let r = plan.window;
    Ok(json!({
        "image": photocraft_paint::tile::b64_encode(&image),
        "mask": photocraft_paint::tile::b64_encode(&mask),
        "side": side,
        "crop": [r.x0, r.y0, r.width(), r.height()],
        "scale": ai.scale,
    }))
}

/// The fill on a new layer above `id`: the hole's pixels (opaque where the source had no alpha),
/// transparent elsewhere. Returns the damage and the new layer.
fn fill_to_new_layer(doc: &mut Document, id: Option<LayerId>, out: &Region, hole: &[bool]) -> Result<(Rect, LayerId)> {
    let base = doc.pixel_format();
    let fmt = PixelFormat::new(base.mode, base.sample, true);
    let n = fmt.channels();
    let colours = n.saturating_sub(1);
    if out.ch != n && out.ch != colours {
        return Err(EngineError::Other("internal error: the fill's channels don't match the document".into()));
    }
    let mut data = vec![0.0f32; hole.len().saturating_mul(n)];
    for ((dst, src), m) in data.chunks_exact_mut(n).zip(out.data.chunks_exact(out.ch)).zip(hole) {
        if !*m {
            continue;
        }
        for (d, s) in dst.iter_mut().zip(src.iter().take(colours)) {
            *d = *s;
        }
        if let Some(a) = dst.last_mut() {
            *a = if out.ch == n { src.last().copied().unwrap_or(1.0) } else { 1.0 };
        }
    }
    let mut l = Layer::raster(doc.next_layer_name("Layer"), fmt);
    crate::pixels_mut(&mut l)?.write_region(out.rect, &data);
    let nid = doc.insert_above(id, l);
    Ok((out.rect, nid))
}

pub(super) fn remove(s: &mut Session, p: &Value) -> Result<Value> {
    let plan = plan(s, p, CMD)?;
    let label = if plan.ai.is_some() { "AI Remove" } else { "Quick Fill" };
    let d = s.active().ok_or(EngineError::NoDocument)?;
    let doc = d.doc.clone();
    let p = p.clone();
    let id = plan.id;
    let new_layer = plan.new_layer;
    crate::jobs::run(
        s,
        label,
        true,
        {
            let p = p.clone();
            move |ctx| {
                ctx.progress(0.0, label);
                let mut work = (*doc).clone();
                run_remove(&mut work, &plan, &p, ctx, label)
            }
        },
        move |s, filled| {
            let Some((out, hole)) = filled else { return Ok(json!({"changed": false})) };
            if new_layer {
                let (damage, nid) = s.edit(label, |doc, active| {
                    let r = fill_to_new_layer(doc, id, &out, &hole)?;
                    *active = Some(r.1);
                    Ok(r)
                })?;
                if let Some(st) = s.active_mut() {
                    st.last_damage = Some(damage);
                }
                return Ok(json!({ "damage": damage_json(damage), "layer": nid.0 }));
            }
            let damage = s.edit(label, |doc, _| replace(doc, Target { id, all_layers: false }, &p, &out, &hole))?;
            if let Some(st) = s.active_mut() {
                st.last_damage = Some(damage);
            }
            Ok(json!({ "damage": damage_json(damage) }))
        },
    )
}

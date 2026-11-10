//! Type › Text Background: a box behind a type layer. It is a rounded-rectangle shape layer just
//! under the text, linked to it so the two move together, so it saves to PSD as it looks.

use std::sync::Arc;

use photocraft_doc::vector::LiveShape;
use photocraft_doc::{Color, Document, Fill, Layer, LayerContent, LayerId, ShapeLayer};
use photocraft_vector as vector;
use serde_json::{Value, json};

use crate::commands::{CommandSpec, color_param, layer_param};
use crate::vector_cmds::refresh_shape;
use crate::{EngineError, Result, Session};

const CMD: &str = "type.background";

fn has_text(s: &Session) -> std::result::Result<(), String> {
    let d = s.active().ok_or("no document open")?;
    match d.active_layer.and_then(|id| d.doc.layer(id)).map(|l| &l.content) {
        Some(LayerContent::Text(_)) => Ok(()),
        _ => Err("the active layer is not a type layer".into()),
    }
}

/// The background box of `text`: the shape layer right under it, linked to it.
pub fn background_of(doc: &Document, text: LayerId) -> Option<LayerId> {
    let group = doc.layer(text)?.link_group?;
    let mut path = doc.path_of(text)?;
    let last = path.last_mut()?;
    *last = last.checked_sub(1)?;
    let below = doc.layer_at(&path)?;
    (matches!(below.content, LayerContent::Shape(_)) && below.link_group == Some(group)).then_some(below.id)
}

/// The box's look: colour, padding around the text's pixels, corner radius.
#[derive(Clone, Copy)]
struct Look {
    color: Color,
    pad: f64,
    radius: f64,
}

/// `text`'s box and its look, as it sits around the text in `doc`.
fn current(doc: &Document, text: LayerId) -> Option<(LayerId, Look)> {
    let bg = background_of(doc, text)?;
    let ink = crate::layer_multi_cmds::layer_bounds(doc.layer(text)?)?;
    let LayerContent::Shape(sh) = &doc.layer(bg)?.content else { return None };
    let Some(LiveShape::Rect { rect, radii }) = &sh.live else { return None };
    let color = match &sh.fill {
        Some(Fill::Solid(c)) => *c,
        _ => Color::WHITE,
    };
    Some((bg, Look { color, pad: (f64::from(ink.x0) - rect[0]).max(0.0), radius: radii[0] }))
}

/// `text`'s box and how far it reaches past the text, for a preview's damage.
pub(crate) fn reach(doc: &Document, text: LayerId) -> Option<(photocraft_geom::Rect, i32)> {
    let (bg, look) = current(doc, text)?;
    let r = crate::layer_multi_cmds::layer_bounds(doc.layer(bg)?)?;
    Some((r, look.pad.clamp(0.0, 1e6).ceil() as i32 + 2))
}

/// `type.info`'s `background`: the box's layer, colour (sRGB 0…1), padding and radius.
pub(crate) fn info(doc: &Document, text: LayerId) -> Option<Value> {
    let (bg, l) = current(doc, text)?;
    Some(json!({ "layer": bg.0, "color": [l.color.c[0], l.color.c[1], l.color.c[2]], "padding": l.pad, "radius": l.radius }))
}

/// A box with `look` around `text`'s pixels in `doc`.
fn build(doc: &Document, text: LayerId, look: Look) -> Option<ShapeLayer> {
    let ink = crate::layer_multi_cmds::layer_bounds(doc.layer(text)?)?;
    let w = f64::from(ink.x1 - ink.x0) + 2.0 * look.pad;
    let h = f64::from(ink.y1 - ink.y0) + 2.0 * look.pad;
    let r = look.radius.min(w.min(h) / 2.0);
    let live = LiveShape::Rect { rect: [f64::from(ink.x0) - look.pad, f64::from(ink.y0) - look.pad, w, h], radii: [r; 4] };
    let mut sh = ShapeLayer { path: vector::shapes::live_path(&live), fill: Some(Fill::Solid(look.color)), live: Some(live), ..Default::default() };
    refresh_shape(doc, &mut sh);
    Some(sh)
}

/// After any edit: refits the box of every text that was re-rendered, so it follows typing.
pub(crate) fn refit(before: &Document, doc: &mut Document) {
    let changed: Vec<LayerId> = doc
        .walk()
        .iter()
        .filter_map(|(_, _, l)| {
            let LayerContent::Text(t) = &l.content else { return None };
            l.link_group?;
            let old = match before.layer(l.id).map(|b| &b.content) {
                Some(LayerContent::Text(o)) => o.psd_raw.as_ref(),
                _ => None,
            };
            let same = matches!((old, t.psd_raw.as_ref()), (Some(a), Some(b)) if Arc::ptr_eq(a, b));
            (!same).then_some(l.id)
        })
        .collect();
    for text in changed {
        let Some((_, look)) = current(before, text) else { continue };
        let Some(bg) = background_of(doc, text) else { continue };
        if let Some(sh) = build(doc, text, look)
            && let Some(l) = doc.layer_mut(bg)
        {
            l.content = LayerContent::Shape(sh);
        }
    }
}

fn number(p: &Value, key: &str, max: f64) -> Result<Option<f64>> {
    match p.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => v
            .as_f64()
            .filter(|n| n.is_finite() && (0.0..=max).contains(n))
            .map(Some)
            .ok_or_else(|| EngineError::Other(format!("{CMD}: `{key}` must be a number from 0 to {max}"))),
    }
}

fn run(s: &mut Session, p: &Value) -> Result<Value> {
    let text = layer_param(s, p)?;
    let remove = p.get("remove").and_then(Value::as_bool).unwrap_or(false);
    let padding = number(p, "padding", 10_000.0)?;
    let radius = number(p, "radius", 10_000.0)?;
    let d = s.active().ok_or(EngineError::NoDocument)?;
    let layer = d.doc.layer(text).ok_or(EngineError::NoLayer(text))?;
    let LayerContent::Text(t) = &layer.content else {
        return Err(EngineError::Other(format!("{CMD}: layer {} is not a type layer", text.0)));
    };
    let existing = current(&d.doc, text);
    if remove {
        let Some((bg, _)) = existing else { return Ok(json!({ "removed": false })) };
        s.edit("Remove Text Background", |doc, _| {
            doc.remove(bg);
            Ok(())
        })?;
        return Ok(json!({ "removed": true }));
    }
    let size = f64::from(t.size_pt).max(1.0);
    let old = existing.map(|(_, l)| l);
    let color = match (p.get("color"), old) {
        (None, Some(l)) => l.color,
        _ => {
            let c = color_param(CMD, p, "color", [1.0, 1.0, 1.0, 1.0])?;
            Color::rgba(c[0], c[1], c[2], c[3])
        }
    };
    let look = Look {
        color,
        pad: padding.or(old.map(|l| l.pad)).unwrap_or((size * 0.3).round()),
        radius: radius.or(old.map(|l| l.radius)).unwrap_or((size * 0.2).round()),
    };
    let sh = build(&d.doc, text, look).ok_or_else(|| EngineError::Other(format!("{CMD}: the text is empty")))?;
    let name = format!("{} Background", layer.name);
    let label = if existing.is_some() { "Edit Text Background" } else { "Text Background" };
    let bg = s.edit(label, |doc, _| {
        let group = match doc.layer(text).and_then(|l| l.link_group) {
            Some(g) => g,
            None => doc.unused_link_group().ok_or_else(|| EngineError::Other(format!("{CMD}: no free link group")))?,
        };
        if let Some(l) = doc.layer_mut(text) {
            l.link_group = Some(group);
        }
        if let Some(id) = background_of(doc, text)
            && let Some(l) = doc.layer_mut(id)
        {
            l.content = LayerContent::Shape(sh);
            return Ok(id);
        }
        let mut l = Layer::new(name, LayerContent::Shape(sh));
        l.link_group = Some(group);
        Ok(doc.insert_below(Some(text), l))
    })?;
    Ok(json!({ "layer": bg.0 }))
}

pub fn specs() -> Vec<CommandSpec> {
    vec![CommandSpec {
        id: CMD,
        label: "Text Background",
        menu: &["Type"],
        shortcut: None,
        params: r##"{"layer":id? (default active type layer),"color":"#rrggbb"|[r,g,b,a]? (default white, or the box's own),"padding":px?,"radius":px?,"remove":bool?}"##,
        enabled: has_text,
        journal: true,
        run,
    }]
}

#[cfg(test)]
#[path = "type_background_cmds/tests.rs"]
mod tests;

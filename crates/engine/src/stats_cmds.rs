//! `document.stats`: mean, spread and soft-pixel share over a rectangle, for tests and agents
//! that need to check a result (a blur softened an edge, a fill matches its surroundings).

use photocraft_doc::{Layer, LayerId};
use photocraft_geom::Rect;
use serde_json::{Value, json};

use crate::commands::CommandSpec;
use crate::{EngineError, Result, Session};

/// Most samples read per call; larger rectangles are sampled on a grid.
const MAX_SAMPLES: usize = 1 << 20;

fn bad(msg: impl Into<String>) -> EngineError {
    EngineError::BadParams { cmd: "document.stats".into(), msg: msg.into() }
}

fn has_doc(s: &Session) -> std::result::Result<(), String> {
    s.active().map(|_| ()).ok_or_else(|| "no document open".into())
}

fn find_layer<'a>(layers: &'a [Layer], p: &Value) -> Option<&'a Layer> {
    for l in layers {
        let hit = match p {
            Value::Number(n) => n.as_u64() == Some(l.id.0),
            Value::String(s) => &l.name == s,
            _ => false,
        };
        if hit {
            return Some(l);
        }
        if let photocraft_doc::LayerContent::Group(g) = &l.content
            && let Some(f) = find_layer(&g.children, p)
        {
            return Some(f);
        }
    }
    None
}

fn stats(s: &mut Session, p: &Value) -> Result<Value> {
    let d = s.active().ok_or(EngineError::NoDocument)?;
    let doc = &d.doc;
    let r = match p.get("rect").and_then(Value::as_array) {
        Some(a) if a.len() == 4 => {
            let v: Vec<i64> = a.iter().filter_map(Value::as_i64).collect();
            if v.len() != 4 {
                return Err(bad("`rect` must be [x0, y0, x1, y1] integers"));
            }
            let c = |x: i64| x.clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32;
            Rect::new(c(v[0]), c(v[1]), c(v[2]), c(v[3])).intersect(&doc.bounds())
        }
        Some(_) => return Err(bad("`rect` must be [x0, y0, x1, y1]")),
        None => doc.bounds(),
    };
    if r.is_empty() {
        return Err(bad("the rectangle is outside the document"));
    }
    let of = p.get("of").and_then(Value::as_str).unwrap_or("composite");
    let layer = || -> Result<&Layer> {
        let key = p.get("layer").cloned().or_else(|| d.active_layer.map(|LayerId(id)| json!(id))).ok_or(EngineError::Other("no layer".into()))?;
        find_layer(&doc.layers, &key).ok_or_else(|| bad(format!("no layer {key}")))
    };
    let step = ((r.width() as usize * r.height() as usize / MAX_SAMPLES) as f64).sqrt().ceil().max(1.0) as i32;
    let (px, n): (Vec<f32>, usize) = match of {
        "composite" => (photocraft_compose::render(doc, r).px.into_iter().flatten().collect(), 4),
        "pixels" => {
            let surf = layer()?.surface().ok_or_else(|| bad("the layer has no pixels"))?;
            (surf.read_region(r), surf.channels())
        }
        "mask" => {
            let m = layer()?.mask.as_ref().ok_or_else(|| bad("the layer has no mask"))?;
            (m.surface.read_region(r), m.surface.channels())
        }
        "selection" => {
            let m = doc.selection.as_ref().ok_or_else(|| bad("there is no selection"))?;
            (m.read_region(r), m.channels())
        }
        other => return Err(bad(format!("`of` must be composite, pixels, mask or selection, not {other}"))),
    };
    let w = r.width() as usize;
    let (mut sum, mut sq, mut count, mut soft) = (vec![0f64; n], vec![0f64; n], 0usize, 0usize);
    for y in (0..r.height() as usize).step_by(step as usize) {
        for x in (0..w).step_by(step as usize) {
            let Some(c) = px.get((y * w + x) * n..(y * w + x + 1) * n) else { continue };
            for (i, v) in c.iter().enumerate() {
                sum[i] += f64::from(*v);
                sq[i] += f64::from(*v) * f64::from(*v);
            }
            if c.last().is_some_and(|a| *a > 0.1 && *a < 0.9) {
                soft += 1;
            }
            count += 1;
        }
    }
    let k = count.max(1) as f64;
    let mean: Vec<f64> = sum.iter().map(|v| v / k).collect();
    let stddev: Vec<f64> = sq.iter().zip(&mean).map(|(q, m)| (q / k - m * m).max(0.0).sqrt()).collect();
    Ok(json!({ "rect": [r.x0, r.y0, r.x1, r.y1], "mean": mean, "stddev": stddev, "soft": soft as f64 / k, "samples": count }))
}

pub fn specs() -> Vec<CommandSpec> {
    vec![CommandSpec {
        id: "document.stats",
        label: "Region Statistics",
        menu: &[],
        shortcut: None,
        params: r##"{"rect":[x0,y0,x1,y1]?=whole document,"of":"composite|pixels|mask|selection"="composite","layer":id|name?=active layer (pixels, mask)} → {rect, mean:[per channel], stddev:[per channel], soft (share of samples whose last channel is between 0.1 and 0.9), samples}"##,
        enabled: has_doc,
        run: stats,
        journal: false,
    }]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stats_of_a_painted_square() {
        let mut s = Session::new();
        s.execute("file.new", json!({"width": 40, "height": 40})).unwrap();
        s.execute("select.rect", json!({"x": 10, "y": 10, "width": 10, "height": 10})).unwrap();
        s.execute("edit.fill", json!({"contents": "black"})).unwrap();
        let inside = s.execute("document.stats", json!({"rect": [10, 10, 20, 20]})).unwrap();
        assert!(inside["mean"][0].as_f64().unwrap() < 0.01 && inside["stddev"][0].as_f64().unwrap() < 0.01, "{inside}");
        let half = s.execute("document.stats", json!({"rect": [0, 10, 20, 20]})).unwrap();
        assert!((half["mean"][0].as_f64().unwrap() - 0.5).abs() < 0.01 && half["stddev"][0].as_f64().unwrap() > 0.4, "{half}");
        let by_name = s.execute("document.stats", json!({"of": "pixels", "layer": "Background"})).unwrap();
        assert_eq!(by_name["samples"], 1600);
    }

    #[test]
    fn stats_rejects_bad_params() {
        let mut s = Session::new();
        assert!(s.execute("document.stats", json!({})).is_err(), "no document");
        s.execute("file.new", json!({"width": 8, "height": 8})).unwrap();
        for p in [
            json!({"rect": [100, 100, 200, 200]}),
            json!({"rect": [0, 0, 1]}),
            json!({"rect": ["a", 0, 1, 1]}),
            json!({"of": "nope"}),
            json!({"of": "mask"}),
            json!({"of": "pixels", "layer": "missing"}),
        ] {
            assert!(s.execute("document.stats", p.clone()).is_err(), "{p}");
        }
    }
}

//! Queries for the adjustment screens: the histogram behind Levels, Curves and Threshold, their
//! eyedroppers, and Black & White's Auto.

use photocraft_color::ColorMode;
use photocraft_doc::adjust::ToneSpace;
use photocraft_doc::{Document, Layer, LayerContent, LayerId};
use serde_json::{Value, json};

use crate::adjust_params::{adjustment_eyedropper, channel_keys, default_space, eyedropper_sample, to_params};
use crate::commands::CommandSpec;
use crate::{EngineError, Result, Session};

fn has_doc(s: &Session) -> std::result::Result<(), String> {
    s.active().map(|_| ()).ok_or_else(|| "no document open".into())
}

fn bad(msg: impl Into<String>) -> EngineError {
    EngineError::BadParams { cmd: "image.toneHistogram".into(), msg: msg.into() }
}

fn layer_of(p: &Value, doc: &Document) -> Result<Option<LayerId>> {
    match p.get("layer") {
        None | Some(Value::Null) => Ok(None),
        Some(v) => {
            let id = LayerId(v.as_u64().ok_or_else(|| bad("`layer` must be a layer id"))?);
            doc.layer(id).ok_or(EngineError::NoLayer(id))?;
            Ok(Some(id))
        }
    }
}

fn is_adjustment(doc: &Document, id: LayerId) -> bool {
    doc.layer(id).is_some_and(|l| matches!(l.content, LayerContent::Adjustment(_)))
}

/// Shows only the branch of the layer tree holding `id`.
fn isolate(layers: &mut [Layer], id: LayerId) -> bool {
    let mut found = false;
    for l in layers.iter_mut() {
        let here = l.id == id || l.children_mut().is_some_and(|c| isolate(c, id));
        l.visible = here;
        found |= here;
    }
    found
}

/// Channel names and Levels param keys ("" = the top-level keys) in `mode`.
fn channels(mode: ColorMode) -> Vec<(&'static str, &'static str)> {
    let space = default_space(mode);
    if mode == ColorMode::Grayscale {
        return vec![("Gray", "")];
    }
    let names: &[&str] = match space {
        ToneSpace::Rgb => &["Red", "Green", "Blue"],
        ToneSpace::Cmyk => &["Cyan", "Magenta", "Yellow", "Black"],
        ToneSpace::Lab => &["Lightness", "a", "b"],
    };
    let keys = channel_keys(space);
    match space {
        // Lab has no composite: the top-level keys are Lightness.
        ToneSpace::Lab => names.iter().zip(keys).enumerate().map(|(i, (n, k))| (*n, if i == 0 { "" } else { *k })).collect(),
        ToneSpace::Rgb => std::iter::once(("RGB", "")).chain(names.iter().copied().zip(keys.iter().copied())).collect(),
        ToneSpace::Cmyk => std::iter::once(("CMYK", "")).chain(names.iter().copied().zip(keys.iter().copied())).collect(),
    }
}

/// `image.toneHistogram`: 256 bins per channel of what Levels would adjust. An adjustment
/// layer sees the image below it; another layer is shown alone; no layer is the whole image.
fn tone_histogram(s: &mut Session, p: &Value) -> Result<Value> {
    let d = s.active().ok_or(EngineError::NoDocument)?;
    let mut doc = (*d.doc).clone();
    if let Some(id) = layer_of(p, &doc)? {
        if is_adjustment(&doc, id) {
            if let Some(l) = doc.layer_mut(id) {
                l.visible = false;
            }
        } else {
            isolate(&mut doc.layers, id);
        }
    }
    let chans = channels(doc.mode);
    let space = default_space(doc.mode);
    let mut h = vec![[0u32; 256]; chans.len()];
    let img = photocraft_compose::thumbnail(&doc, 384);
    let bin = |v: f32| (v.clamp(0.0, 1.0) * 255.0).round() as usize;
    let mut add = |c: usize, i: usize| {
        if let Some(b) = h.get_mut(c).and_then(|h| h.get_mut(i)) {
            *b += 1;
        }
    };
    for p in img.pixels.as_chunks::<4>().0 {
        if p[3] == 0 {
            continue;
        }
        let rgb = [p[0], p[1], p[2]].map(|v| f32::from(v) / 255.0);
        if doc.mode == ColorMode::Grayscale {
            add(0, bin((rgb[0] + rgb[1] + rgb[2]) / 3.0));
            continue;
        }
        match space {
            ToneSpace::Rgb => {
                for (c, v) in rgb.iter().enumerate() {
                    add(c + 1, bin(*v));
                }
                add(0, bin((rgb[0] + rgb[1] + rgb[2]) / 3.0));
            }
            ToneSpace::Cmyk => {
                let ink = photocraft_color::convert::rgb_to_cmyk(rgb);
                for (c, v) in ink.iter().enumerate() {
                    add(c + 1, bin(1.0 - v));
                }
                add(0, bin(1.0 - ink.iter().sum::<f32>() / 4.0));
            }
            ToneSpace::Lab => {
                let l = photocraft_color::convert::srgb_to_lab(rgb);
                add(0, bin(l[0] / 100.0));
                add(1, bin((l[1] + 128.0) / 255.0));
                add(2, bin((l[2] + 128.0) / 255.0));
            }
        }
    }
    let eyedroppers = matches!(doc.mode, ColorMode::Rgb | ColorMode::Grayscale);
    Ok(json!({
        "channels": chans.iter().zip(&h).map(|((name, key), bins)| json!({"name": name, "key": key, "bins": bins.to_vec()})).collect::<Vec<_>>(),
        "eyedroppers": eyedroppers,
        "grayPicker": doc.mode == ColorMode::Rgb,
    }))
}

/// `image.adjustmentEyedropper`: the Levels or Curves in `params` after a Set Black/Gray/White
/// Point pick.
fn adjustment_eyedropper_cmd(s: &mut Session, p: &Value) -> Result<Value> {
    let d = s.active().ok_or(EngineError::NoDocument)?;
    let kind =
        p.get("kind").and_then(Value::as_str).filter(|k| matches!(*k, "levels" | "curves")).ok_or_else(|| bad("`kind` must be \"levels\" or \"curves\""))?;
    let e = p.get("eyedropper").ok_or_else(|| bad("`eyedropper` is required"))?;
    let hide = layer_of(p, &d.doc)?.filter(|id| is_adjustment(&d.doc, *id));
    let (picker, sample) = eyedropper_sample(&d.doc, hide, e)?;
    let params = p.get("params").cloned().unwrap_or_else(|| json!({}));
    let adj = adjustment_eyedropper(kind, &params, picker, sample, d.doc.mode)?;
    Ok(to_params(&adj))
}

/// Black & White mixes: the screen's presets, and what Auto chooses from.
pub const BLACK_WHITE_MIXES: [(&str, [f32; 6]); 8] = [
    ("Default", [40.0, 60.0, 40.0, 60.0, 20.0, 80.0]),
    ("Lighter", [60.0, 80.0, 60.0, 80.0, 40.0, 100.0]),
    ("Darker", [20.0, 40.0, 20.0, 40.0, 0.0, 60.0]),
    ("Red Filter", [120.0, 110.0, -10.0, -50.0, -50.0, 120.0]),
    ("Yellow Filter", [120.0, 110.0, 40.0, -30.0, -50.0, 90.0]),
    ("Green Filter", [40.0, 120.0, 120.0, 40.0, -30.0, 60.0]),
    ("Blue Filter", [-30.0, -20.0, 30.0, 120.0, 130.0, 110.0]),
    ("Infrared", [-30.0, 200.0, 150.0, -50.0, 0.0, -100.0]),
];

/// `image.blackWhiteAuto`: of [`BLACK_WHITE_MIXES`], the one that spreads the image's grays the
/// most without clipping more than 1% of it.
fn black_white_auto(s: &mut Session, p: &Value) -> Result<Value> {
    let d = s.active().ok_or(EngineError::NoDocument)?;
    let mut doc = (*d.doc).clone();
    if let Some(id) = layer_of(p, &doc)?.filter(|id| is_adjustment(&doc, *id))
        && let Some(l) = doc.layer_mut(id)
    {
        l.visible = false;
    }
    let img = photocraft_compose::thumbnail(&doc, 256);
    let px: Vec<[f32; 4]> = img.pixels.as_chunks::<4>().0.iter().filter(|p| p[3] > 0).map(|p| [p[0], p[1], p[2], 255].map(|v| f32::from(v) / 255.0)).collect();
    let rect = photocraft_geom::Rect::from_xywh(0, 0, u32::try_from(px.len()).unwrap_or(0).max(1), 1);
    let mut best = (f32::MIN, BLACK_WHITE_MIXES[0]);
    for mix in BLACK_WHITE_MIXES {
        let mut buf = photocraft_compose::Buffer { rect, px: px.clone() };
        if buf.px.is_empty() {
            break;
        }
        photocraft_compose::adjust::apply(&photocraft_doc::adjust::Adjustment::BlackWhite { weights: mix.1, tint: None }, &mut buf);
        let n = buf.px.len() as f32;
        let mean = buf.px.iter().map(|p| p[0]).sum::<f32>() / n;
        let sd = (buf.px.iter().map(|p| (p[0] - mean).powi(2)).sum::<f32>() / n).sqrt();
        let clipped = buf.px.iter().filter(|p| p[0] <= 0.002 || p[0] >= 0.998).count() as f32 / n;
        let score = if clipped > 0.01 { sd - 1.0 } else { sd };
        if score > best.0 {
            best = (score, mix);
        }
    }
    let weights = |w: [f32; 6]| json!({"reds": w[0], "yellows": w[1], "greens": w[2], "cyans": w[3], "blues": w[4], "magentas": w[5]});
    let presets: Vec<Value> = BLACK_WHITE_MIXES.iter().map(|(name, w)| json!({"name": name, "weights": weights(*w)})).collect();
    Ok(json!({"auto": best.1.0, "presets": presets}))
}

pub fn specs() -> Vec<CommandSpec> {
    vec![
        CommandSpec {
            id: "image.toneHistogram",
            label: "Tone Histogram",
            menu: &[],
            shortcut: None,
            params: r##"{"layer":id?} (an adjustment layer: the image below it; another layer: that layer alone; none: the image) → {"channels":[{"name","key","bins":[256]}],"eyedroppers":bool,"grayPicker":bool}"##,
            enabled: has_doc,
            run: tone_histogram,
            journal: false,
        },
        CommandSpec {
            id: "image.adjustmentEyedropper",
            label: "Adjustment Eyedropper",
            menu: &[],
            shortcut: None,
            params: r##"{"kind":"levels|curves","params":json (its params),"eyedropper":{"point":"black|gray|white","at":[x,y],"size":1..101=1} or {"point",…,"color":[r,g,b] 0..1},"layer":id? (an adjustment layer is hidden while sampling)} → the new params"##,
            enabled: has_doc,
            run: adjustment_eyedropper_cmd,
            journal: false,
        },
        CommandSpec {
            id: "image.blackWhiteAuto",
            label: "Black & White Auto",
            menu: &[],
            shortcut: None,
            params: r##"{"layer":id? (an adjustment layer: the image below it)} → {"auto": the chosen preset's name,"presets":[{"name","weights":{"reds",…,"magentas"}}]}"##,
            enabled: has_doc,
            run: black_white_auto,
            journal: false,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session() -> Session {
        let mut s = Session::new();
        s.execute("file.new", json!({"width": 8, "height": 8, "background": "#3366cc"})).unwrap();
        s
    }

    #[test]
    fn histogram_has_a_bin_per_channel_and_skips_the_adjustment_layer() {
        let mut s = session();
        let h = s.execute("image.toneHistogram", json!({})).unwrap();
        let names: Vec<_> = h["channels"].as_array().unwrap().iter().map(|c| c["name"].as_str().unwrap().to_string()).collect();
        assert_eq!(names, ["RGB", "Red", "Green", "Blue"]);
        let red = &h["channels"][1]["bins"];
        assert_eq!(red[51].as_u64(), Some(64), "every pixel is at 0.2");
        s.execute("layer.newAdjustmentLayer.invert", json!({})).unwrap();
        let id = s.active().unwrap().active_layer.unwrap().0;
        let below = s.execute("image.toneHistogram", json!({"layer": id})).unwrap();
        assert_eq!(below["channels"][1]["bins"][51].as_u64(), Some(64), "the inverted image isn't counted");
    }

    #[test]
    fn eyedropper_returns_new_levels() {
        let mut s = session();
        let out = s.execute("image.adjustmentEyedropper", json!({"kind": "levels", "eyedropper": {"point": "white", "at": [1, 1]}})).unwrap();
        assert!((out["red"]["inWhite"].as_f64().unwrap() - 51.0).abs() < 1.0, "{out}");
        assert!((out["blue"]["inWhite"].as_f64().unwrap() - 204.0).abs() < 1.0, "{out}");
        let out = s.execute("image.adjustmentEyedropper", json!({"kind": "curves", "eyedropper": {"point": "black", "at": [1, 1]}})).unwrap();
        assert!(out["red"].as_array().is_some_and(|c| c.len() == 2), "{out}");
    }

    #[test]
    fn black_white_auto_picks_a_mix() {
        let mut s = session();
        let out = s.execute("image.blackWhiteAuto", json!({})).unwrap();
        assert!(BLACK_WHITE_MIXES.iter().any(|m| m.0 == out["auto"]), "{out}");
        assert_eq!(out["presets"][0]["weights"]["blues"], 20.0);
    }

    #[test]
    fn bad_params_are_errors() {
        let mut s = session();
        for p in [json!({"layer": "x"}), json!({"layer": 99999})] {
            assert!(s.execute("image.toneHistogram", p).is_err());
        }
        for p in [
            json!({}),
            json!({"kind": "hueSaturation", "eyedropper": {"point": "white", "at": [1, 1]}}),
            json!({"kind": "levels", "eyedropper": {"point": "white"}}),
            json!({"kind": "levels", "eyedropper": {"point": "x", "at": [1, 1]}}),
            json!({"kind": "curves", "eyedropper": {"point": "white", "at": [99, 1]}}),
        ] {
            assert!(s.execute("image.adjustmentEyedropper", p).is_err());
        }
    }
}

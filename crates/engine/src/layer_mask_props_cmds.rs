//! Non-destructive pixel-mask properties: density and feather leave the mask pixels intact.

use photocraft_doc::LayerId;
use serde_json::{Value, json};

use crate::commands::CommandSpec;
use crate::{EngineError, Result, Session};

pub const EDIT: &str = "layer.layerMask.edit";
pub const COPY_TO: &str = "layer.layerMask.copyTo";

fn bad(msg: impl Into<String>) -> EngineError {
    EngineError::BadParams { cmd: EDIT.into(), msg: msg.into() }
}

fn number(p: &Value, name: &str, max: f64) -> Result<Option<f32>> {
    p.get(name)
        .map(|v| {
            v.as_f64()
                .filter(|n| n.is_finite() && (0.0..=max).contains(n))
                .map(|n| n as f32)
                .ok_or_else(|| bad(format!("`{name}` must be a finite number within 0..{max}")))
        })
        .transpose()
}

fn edit(s: &mut Session, p: &Value) -> Result<Value> {
    if !p.is_object() {
        return Err(bad("params must be an object"));
    }
    let density = number(p, "density", 100.0)?.map(|d| d / 100.0);
    let feather = number(p, "feather", 1000.0)?;
    if density.is_none() && feather.is_none() {
        return Err(bad("density or feather is required"));
    }
    let st = s.active().ok_or(EngineError::NoDocument)?;
    if let Some(document) = p.get("document")
        && document.as_u64() != Some(st.doc.id.0)
    {
        return Err(bad("the target document is no longer active"));
    }
    let id = match p.get("layer") {
        Some(v) => LayerId(v.as_u64().ok_or_else(|| bad("`layer` must be an unsigned layer id"))?),
        None => st.active_layer.ok_or_else(|| bad("no layer given and no active layer"))?,
    };
    let layer = st.doc.layer(id).ok_or(EngineError::NoLayer(id))?;
    let mask = layer.mask.as_ref().ok_or_else(|| bad("the target layer has no pixel mask"))?;
    let (density, feather) = (density.unwrap_or(mask.density), feather.unwrap_or(mask.feather));
    if (density, feather) != (mask.density, mask.feather) {
        s.edit("Edit Layer Mask", |doc, _| {
            let layer = doc.layer_mut(id).ok_or(EngineError::NoLayer(id))?;
            let mask = layer.mask.as_mut().ok_or_else(|| bad("the target layer has no pixel mask"))?;
            (mask.density, mask.feather) = (density, feather);
            Ok(())
        })?;
    }
    Ok(json!({"layer": id.0, "density": density * 100.0, "feather": feather}))
}

/// The mask of `layer` (default the active one) onto layer `to`, replacing its mask; `move`
/// takes it off `layer`.
fn copy_to(s: &mut Session, p: &Value) -> Result<Value> {
    let bad = |msg: &str| EngineError::BadParams { cmd: COPY_TO.into(), msg: msg.into() };
    let st = s.active().ok_or(EngineError::NoDocument)?;
    let from = match p.get("layer") {
        Some(v) => LayerId(v.as_u64().ok_or_else(|| bad("`layer` must be an unsigned layer id"))?),
        None => st.active_layer.ok_or_else(|| bad("no layer given and no active layer"))?,
    };
    let to = LayerId(p.get("to").and_then(Value::as_u64).ok_or_else(|| bad("`to` must be an unsigned layer id"))?);
    let moving = match p.get("move") {
        None => false,
        Some(v) => v.as_bool().ok_or_else(|| bad("`move` must be a boolean"))?,
    };
    if from == to {
        return Err(bad("`to` is the layer the mask is on"));
    }
    let mask = st.doc.layer(from).ok_or(EngineError::NoLayer(from))?.mask.clone().ok_or_else(|| bad("the layer has no pixel mask"))?;
    st.doc.layer(to).ok_or(EngineError::NoLayer(to))?;
    if st.doc.is_background(to) {
        return Err(bad("the Background can't have a mask"));
    }
    s.edit(if moving { "Move Layer Mask" } else { "Copy Layer Mask" }, |doc, _| {
        doc.layer_mut(to).ok_or(EngineError::NoLayer(to))?.mask = Some(mask);
        if moving {
            doc.layer_mut(from).ok_or(EngineError::NoLayer(from))?.mask = None;
        }
        Ok(())
    })?;
    Ok(json!({"layer": to.0}))
}

pub fn specs() -> Vec<CommandSpec> {
    vec![CommandSpec {
        id: COPY_TO,
        label: "Copy Layer Mask",
        menu: &[],
        shortcut: None,
        params: r##"{"layer":id? (default active),"to":id,"move":bool=false} → {layer}; replaces the mask on `to`"##,
        enabled: |s| s.active().map(|_| ()).ok_or_else(|| "no document open".into()),
        run: copy_to,
        journal: true,
    }, CommandSpec {
        id: EDIT,
        label: "Edit Layer Mask",
        menu: &[],
        shortcut: None,
        params: r##"{"layer":id? (default active),"document":id? (reject a stale dialog),"density":0..100?,"feather":0..1000? (pixels)} → {layer,density,feather}; at least one property required; mask pixels are preserved"##,
        enabled: |s| s.active().map(|_| ()).ok_or_else(|| "no document open".into()),
        run: edit,
        journal: true,
    }]
}

#[cfg(test)]
mod tests;

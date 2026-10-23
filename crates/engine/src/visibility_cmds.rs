//! Layers panel › Show/Hide all other layers (the layer's menu): hide every layer but this one,
//! or, when they are all hidden already, show them all, whatever they were before. ⌥-click on
//! the eye (`layer.showOnly`) restores the earlier visibility instead. The layer itself and the
//! groups it sits in are made visible; layers inside it are left alone.

use photocraft_doc::LayerId;
use serde_json::{Value, json};

use crate::commands::CommandSpec;
use crate::{EngineError, Result, Session};

const ID: &str = "layer.showHideOthers";

fn bad(msg: impl Into<String>) -> EngineError {
    EngineError::BadParams { cmd: ID.into(), msg: msg.into() }
}

fn has_layers(s: &Session) -> std::result::Result<(), String> {
    let d = s.active().ok_or("no document open")?;
    if d.doc.walk().len() > 1 { Ok(()) } else { Err("the document has only one layer".into()) }
}

fn show_hide_others(s: &mut Session, p: &Value) -> Result<Value> {
    let st = s.active().ok_or(EngineError::NoDocument)?;
    let target = match p.get("layer") {
        None | Some(Value::Null) => st.active_layer.ok_or_else(|| bad("no layer given and no active layer"))?,
        Some(v) => LayerId(v.as_u64().ok_or_else(|| bad("`layer` must be a layer id"))?),
    };
    let path = st.doc.path_of(target).ok_or(EngineError::NoLayer(target))?;
    let walk = st.doc.walk();
    let others: Vec<LayerId> = walk.iter().filter(|(q, _, _)| !path.starts_with(q) && !q.starts_with(&path)).map(|(_, _, l)| l.id).collect();
    let ancestors: Vec<LayerId> = walk.iter().filter(|(q, _, _)| path.starts_with(q)).map(|(_, _, l)| l.id).collect();
    if others.is_empty() {
        return Err(bad("there are no other layers"));
    }
    let hide = walk.iter().any(|(_, _, l)| l.visible && others.contains(&l.id));
    s.edit(if hide { "Hide Layers" } else { "Show Layers" }, |doc, _| {
        for id in &others {
            if let Some(l) = doc.layer_mut(*id) {
                l.visible = !hide;
            }
        }
        for id in &ancestors {
            if let Some(l) = doc.layer_mut(*id) {
                l.visible = true;
            }
        }
        Ok(())
    })?;
    Ok(json!({"hidden": hide, "layers": others.len()}))
}

pub fn specs() -> Vec<CommandSpec> {
    vec![CommandSpec {
        id: ID,
        label: "Show/Hide All Other Layers",
        menu: &[],
        shortcut: None,
        params: r##"{"layer":id?} (no layer: the active one) → {hidden, layers}: hides every other layer, or shows them all when they are all hidden"##,
        enabled: has_layers,
        run: show_hide_others,
        journal: true,
    }]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn visible(s: &Session) -> Vec<(String, bool)> {
        s.active().unwrap().doc.walk().iter().map(|(_, _, l)| (l.name.clone(), l.visible)).collect()
    }

    #[test]
    fn hides_the_others_then_shows_them_all() {
        let mut s = Session::new();
        s.execute("file.new", json!({"width": 16, "height": 16})).unwrap();
        let a = s.execute("layer.new.layer", json!({"name": "a"})).unwrap()["layer"].as_u64().unwrap();
        s.execute("layer.new.layer", json!({"name": "b"})).unwrap();
        s.execute("layer.groupLayers", json!({"name": "g"})).unwrap();
        s.execute("layer.setProps", json!({"layer": a, "visible": false})).unwrap();
        let b = s.active().unwrap().doc.walk().iter().find(|(_, _, l)| l.name == "b").unwrap().2.id.0;
        // b sits in group g: g stays visible, everything else goes.
        assert_eq!(s.execute(ID, json!({"layer": b})).unwrap()["hidden"], true);
        for (name, v) in visible(&s) {
            assert_eq!(v, name == "b" || name == "g", "{name}");
        }
        // Again: everything shows, a too, though it was hidden before.
        assert_eq!(s.execute(ID, json!({"layer": b})).unwrap()["hidden"], false);
        assert!(visible(&s).iter().all(|(_, v)| *v));
        s.execute("edit.undo", json!({})).unwrap();
        assert!(!visible(&s).iter().find(|(n, _)| n == "a").unwrap().1, "one undo step");
    }

    #[test]
    fn bad_params_fail_gracefully() {
        let mut s = Session::new();
        assert!(s.execute(ID, json!({})).is_err());
        s.execute("file.new", json!({"width": 8, "height": 8})).unwrap();
        assert!(s.execute(ID, json!({})).is_err(), "only one layer");
        s.execute("layer.new.layer", json!({})).unwrap();
        assert!(s.execute(ID, json!({"layer": "x"})).is_err());
        assert!(s.execute(ID, json!({"layer": 999_999})).is_err());
    }
}

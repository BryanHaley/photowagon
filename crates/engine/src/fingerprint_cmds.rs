//! `document.fingerprint`: a hash of everything a document saves, so a test can tell two states
//! apart (Undo must bring back exactly the state before, a refused command must change nothing).

use photocraft_doc::{Document, Layer, LayerContent};
use serde_json::{Value, json};

use crate::commands::CommandSpec;
use crate::{EngineError, Result, Session};

fn has_doc(s: &Session) -> std::result::Result<(), String> {
    s.active().map(|_| ()).ok_or_else(|| "no document open".into())
}

fn fingerprint(s: &mut Session, p: &Value) -> Result<Value> {
    let d = s.active().ok_or(EngineError::NoDocument)?;
    if p.get("content").and_then(Value::as_bool) == Some(true) {
        return Ok(json!({ "hash": content(&d.doc).to_hex().to_string(), "activeLayer": d.active_layer.map(|l| l.0) }));
    }
    let mut doc = photocraft_doc::Document::clone(&d.doc);
    // The id is the open document's, not part of its state.
    doc.id = photocraft_doc::DocId(0);
    let bytes =
        photocraft_format::save_to_bytes(&doc, &photocraft_format::SaveOptions::default()).map_err(|e| EngineError::Other(format!("fingerprint: {e}")))?;
    Ok(json!({
        "hash": blake3::hash(&bytes).to_hex().to_string(),
        "activeLayer": d.active_layer.map(|l| l.0),
        "bytes": bytes.len(),
    }))
}

/// What the document looks like and how it's built, without ids or its name: the same after a
/// save and reopen, which numbers layers afresh.
fn content(doc: &Document) -> blake3::Hash {
    let mut h = blake3::Hasher::new();
    let r = doc.bounds();
    let pixels = |h: &mut blake3::Hasher, px: &[f32]| {
        for v in px {
            h.update(&((v * 4096.0).round() as i32).to_le_bytes());
        }
    };
    h.update(format!("{:?} {:?} {:?} {}", doc.size, doc.mode, doc.depth, doc.resolution_dpi).as_bytes());
    pixels(&mut h, &photocraft_compose::render(doc, r).px.into_iter().flatten().collect::<Vec<f32>>());
    fn walk(h: &mut blake3::Hasher, layers: &[Layer], r: photocraft_geom::Rect, depth: usize) {
        for l in layers {
            h.update(format!("{depth} {} {} {:?} {} {} {} {:?}", l.name, l.visible, l.blend, l.opacity, l.fill_opacity, l.clipped, l.locks).as_bytes());
            if let Some(s) = l.surface() {
                for v in s.read_region(r) {
                    h.update(&((v * 4096.0).round() as i32).to_le_bytes());
                }
            }
            if let Some(m) = &l.mask {
                for v in m.surface.read_region(r) {
                    h.update(&((v * 4096.0).round() as i32).to_le_bytes());
                }
            }
            h.update(&[u8::from(l.vector_mask.is_some())]);
            if let LayerContent::Group(g) = &l.content {
                walk(h, &g.children, r, depth + 1);
            }
        }
    }
    walk(&mut h, &doc.layers, r, 0);
    for c in &doc.channels {
        h.update(c.name.as_bytes());
        pixels(&mut h, &c.surface.read_region(r));
    }
    if let Some(sel) = &doc.selection {
        pixels(&mut h, &sel.read_region(r));
    }
    for path in &doc.paths {
        h.update(format!("{} {:?}", path.name, path.path).as_bytes());
    }
    h.update(format!("{:?} {:?}", doc.guides.horizontal, doc.guides.vertical).as_bytes());
    h.finalize()
}

pub fn specs() -> Vec<CommandSpec> {
    vec![CommandSpec {
        id: "document.fingerprint",
        label: "Document Fingerprint",
        menu: &[],
        shortcut: None,
        params: r##"{"content":bool=false (what the document looks like and how it's built, without ids or its name: survives a save and reopen)} → {hash (of everything the document saves), activeLayer, bytes?}"##,
        enabled: has_doc,
        run: fingerprint,
        journal: false,
    }]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hash(s: &mut Session) -> String {
        s.execute("document.fingerprint", json!({})).unwrap()["hash"].as_str().unwrap().to_string()
    }

    #[test]
    fn the_same_state_gives_the_same_hash_and_undo_brings_it_back() {
        let mut s = Session::new();
        s.execute("file.new", json!({"width": 40, "height": 30})).unwrap();
        let a = hash(&mut s);
        assert_eq!(a, hash(&mut s), "stable");
        s.execute("select.rect", json!({"x": 2, "y": 2, "width": 10, "height": 10})).unwrap();
        s.execute("edit.fill", json!({"contents": "black"})).unwrap();
        let b = hash(&mut s);
        assert_ne!(a, b, "a fill changes it");
        s.execute("edit.undo", json!({})).unwrap();
        s.execute("edit.undo", json!({})).unwrap();
        assert_eq!(a, hash(&mut s), "undo brings it back");
        s.execute("edit.redo", json!({})).unwrap();
        s.execute("edit.redo", json!({})).unwrap();
        assert_eq!(b, hash(&mut s), "redo too");
    }

    #[test]
    fn content_leaves_out_ids_and_the_name() {
        let mut s = Session::new();
        s.execute("file.new", json!({"width": 8, "height": 8, "name": "a"})).unwrap();
        let a = s.execute("document.fingerprint", json!({"content": true})).unwrap()["hash"].clone();
        s.execute("file.new", json!({"width": 8, "height": 8, "name": "b"})).unwrap();
        assert_eq!(a, s.execute("document.fingerprint", json!({"content": true})).unwrap()["hash"]);
    }

    #[test]
    fn needs_a_document() {
        assert!(Session::new().execute("document.fingerprint", json!({})).is_err());
    }
}

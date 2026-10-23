//! Window › Timeline › Create Frame Animation: frames that each show the layers their own way
//! (visibility, opacity, position), played in order with a delay each. Pixels are shared by every
//! frame. The layers always show the current frame: going to another frame first keeps what the
//! layers show now in the current one, then shows the other. Going to a frame adds no history
//! step; making, deleting and timing frames do.

use std::sync::Arc;

use photocraft_doc::{AnimationFrame, DEFAULT_FRAME_DELAY, Document, FrameAnimation, FrameLayer, Layer, LayerId};
use serde_json::{Value, json};

use crate::commands::CommandSpec;
use crate::{EngineError, Result, Session};

const MAX_FRAMES: usize = 10_000;

fn has_doc(s: &Session) -> std::result::Result<(), String> {
    s.active().map(|_| ()).ok_or_else(|| "no document open".into())
}

fn has_animation(s: &Session) -> std::result::Result<(), String> {
    match s.active() {
        Some(d) if d.doc.animation.is_some() => Ok(()),
        Some(_) => Err("no frame animation (Create Frame Animation first)".into()),
        None => Err("no document open".into()),
    }
}

fn bad(cmd: &str, msg: impl Into<String>) -> EngineError {
    EngineError::BadParams { cmd: cmd.into(), msg: msg.into() }
}

fn all_layers(layers: &[Layer], out: &mut Vec<(LayerId, bool, f32)>) {
    for l in layers {
        out.push((l.id, l.visible, l.opacity));
        if let Some(ch) = l.children() {
            all_layers(ch, out);
        }
    }
}

/// What the layers show now, kept in the current frame (positions stay as the frame has them).
pub fn capture(doc: &mut Document) {
    let mut live = Vec::new();
    all_layers(&doc.layers, &mut live);
    let Some(a) = doc.animation.as_mut() else { return };
    a.clamp();
    let cur = a.current;
    if let Some(f) = a.frames.get_mut(cur) {
        for (id, visible, opacity) in live {
            let offset = f.layers.get(&id.0).map_or([0, 0], |l| l.offset);
            f.layers.insert(id.0, FrameLayer { visible, opacity, offset });
        }
    }
}

/// Show frame `to` (the layers show frame `from` now): visibility, opacity and position.
fn show(doc: &mut Document, from: usize, to: usize) -> Result<()> {
    let Some(a) = doc.animation.as_ref() else { return Ok(()) };
    let (Some(f), Some(t)) = (a.frames.get(from).cloned(), a.frames.get(to).cloned()) else { return Ok(()) };
    let mut moves = Vec::new();
    for (id, l) in &t.layers {
        let was = f.layers.get(id).map_or([0, 0], |x| x.offset);
        let (dx, dy) = (l.offset[0].saturating_sub(was[0]), l.offset[1].saturating_sub(was[1]));
        if dx != 0 || dy != 0 {
            moves.push((LayerId(*id), dx, dy));
        }
        if let Some(layer) = doc.layer_mut(LayerId(*id)) {
            layer.visible = l.visible;
            layer.opacity = l.opacity.clamp(0.0, 1.0);
        }
    }
    let moves: Vec<_> = moves.into_iter().filter(|(id, _, _)| doc.layer(*id).is_some()).collect();
    if !moves.is_empty() {
        let before = doc.clone();
        crate::layer_multi_cmds::move_layers(doc, &before, &moves)?;
    }
    if let Some(a) = doc.animation.as_mut() {
        a.current = to;
    }
    Ok(())
}

/// Layers `ids` moved by (`dx`, `dy`) in the current frame only (Move in a frame animation).
pub fn moved(doc: &mut Document, ids: &[LayerId], dx: i32, dy: i32) {
    let Some(a) = doc.animation.as_mut() else { return };
    a.clamp();
    let cur = a.current;
    let live: Vec<_> = ids.iter().filter_map(|id| doc.layer(*id).map(|l| (*id, l.visible, l.opacity))).collect();
    let Some(f) = doc.animation.as_mut().and_then(|a| a.frames.get_mut(cur)) else { return };
    for (id, visible, opacity) in live {
        let e = f.layers.entry(id.0).or_insert(FrameLayer { visible, opacity, offset: [0, 0] });
        e.offset = [e.offset[0].saturating_add(dx), e.offset[1].saturating_add(dy)];
    }
}

/// `doc` as frame `i` shows it (for export and thumbnails).
pub fn frame_document(doc: &Document, i: usize) -> Result<Document> {
    let mut d = doc.clone();
    capture(&mut d);
    let cur = d.animation.as_ref().map_or(0, |a| a.current);
    show(&mut d, cur, i)?;
    Ok(d)
}

/// Change the document without a history step (going to a frame).
fn navigate(s: &mut Session, f: impl FnOnce(&mut Document) -> Result<()>) -> Result<Value> {
    let st = s.active_mut().ok_or(EngineError::NoDocument)?;
    let mut doc = (*st.doc).clone();
    f(&mut doc)?;
    st.doc = Arc::new(doc);
    st.revision += 1;
    info(s)
}

fn info(s: &Session) -> Result<Value> {
    let d = s.active().ok_or(EngineError::NoDocument)?;
    Ok(match &d.doc.animation {
        None => json!({"animation": null}),
        Some(a) => json!({"animation": {
            "frames": a.frames.iter().map(|f| json!({"delay": f.delay})).collect::<Vec<_>>(),
            "current": a.current,
            "loops": a.loops,
        }}),
    })
}

/// A frame index param (`key`), inside the animation.
fn frame_param(cmd: &str, p: &Value, key: &str, len: usize) -> Result<Option<usize>> {
    let Some(v) = p.get(key).filter(|v| !v.is_null()) else { return Ok(None) };
    v.as_u64()
        .and_then(|i| usize::try_from(i).ok())
        .filter(|i| *i < len)
        .map(Some)
        .ok_or_else(|| bad(cmd, format!("`{key}` must be a frame from 0 to {}", len.saturating_sub(1))))
}

/// `frames`: a list of frame indices or "all" (default: the current frame).
fn frames_param(cmd: &str, p: &Value, a: &FrameAnimation) -> Result<Vec<usize>> {
    match p.get("frames") {
        None | Some(Value::Null) => Ok(vec![a.current]),
        Some(Value::String(s)) if s == "all" => Ok((0..a.frames.len()).collect()),
        Some(Value::Array(list)) => {
            let mut out: Vec<usize> = list
                .iter()
                .map(|v| v.as_u64().and_then(|i| usize::try_from(i).ok()).filter(|i| *i < a.frames.len()))
                .collect::<Option<_>>()
                .ok_or_else(|| bad(cmd, "`frames` must be frame indices inside the animation"))?;
            out.sort_unstable();
            out.dedup();
            Ok(out)
        }
        Some(_) => Err(bad(cmd, "`frames` must be a list of frame indices or \"all\"")),
    }
}

fn animation(doc: &mut Document) -> Result<&mut FrameAnimation> {
    doc.animation.as_mut().ok_or_else(|| EngineError::Other("no frame animation".into()))
}

fn create(s: &mut Session) -> Result<Value> {
    s.edit("Create Frame Animation", |doc, _| {
        doc.animation = Some(FrameAnimation { frames: vec![AnimationFrame { delay: DEFAULT_FRAME_DELAY, layers: Default::default() }], current: 0, loops: 0 });
        capture(doc);
        Ok(())
    })?;
    info(s)
}

fn select(s: &mut Session, p: &Value) -> Result<Value> {
    const CMD: &str = "animation.selectFrame";
    let len = s.active().and_then(|d| d.doc.animation.as_ref()).map_or(0, |a| a.frames.len());
    let to = frame_param(CMD, p, "frame", len)?.ok_or_else(|| bad(CMD, "`frame` is required"))?;
    navigate(s, |doc| {
        capture(doc);
        let from = doc.animation.as_ref().map_or(0, |a| a.current);
        show(doc, from, to)
    })
}

fn new_frame(s: &mut Session) -> Result<Value> {
    s.edit("New Frame", |doc, _| {
        capture(doc);
        let a = animation(doc)?;
        if a.frames.len() >= MAX_FRAMES {
            return Err(EngineError::Other(format!("an animation has at most {MAX_FRAMES} frames")));
        }
        let copy = a.frames[a.current].clone();
        a.frames.insert(a.current + 1, copy);
        a.current += 1;
        Ok(())
    })?;
    info(s)
}

fn delete_frames(s: &mut Session, p: &Value) -> Result<Value> {
    const CMD: &str = "animation.deleteFrames";
    let a = s.active().and_then(|d| d.doc.animation.clone()).ok_or_else(|| EngineError::Other("no frame animation".into()))?;
    let gone = frames_param(CMD, p, &a)?;
    if gone.len() >= a.frames.len() {
        return Err(bad(CMD, "an animation keeps at least one frame (Delete Animation removes it all)"));
    }
    s.edit("Delete Frame", |doc, _| {
        capture(doc);
        let cur = doc.animation.as_ref().map_or(0, |a| a.current);
        // The frame that shows next: the first kept one at or after the current, else before.
        let keep: Vec<usize> = (0..a.frames.len()).filter(|i| !gone.contains(i)).collect();
        let next = keep.iter().copied().find(|i| *i >= cur).or(keep.last().copied()).unwrap_or(0);
        show(doc, cur, next)?;
        let a = animation(doc)?;
        let shown = a.frames[next].clone();
        a.frames = keep.iter().filter_map(|i| a.frames.get(*i).cloned()).collect();
        a.current = a.frames.iter().position(|f| *f == shown).unwrap_or(0);
        Ok(())
    })?;
    info(s)
}

fn delete_animation(s: &mut Session) -> Result<Value> {
    s.edit("Delete Animation", |doc, _| {
        doc.animation = None;
        Ok(())
    })?;
    info(s)
}

/// One frame per layer (bottom to top), each showing that layer alone (and the Background).
fn frames_from_layers(s: &mut Session) -> Result<Value> {
    s.edit("Make Frames From Layers", |doc, _| {
        if doc.animation.is_none() {
            doc.animation = Some(FrameAnimation { frames: vec![], current: 0, loops: 0 });
        }
        capture(doc);
        let background = doc.layers.first().filter(|l| doc.is_background(l.id)).map(|l| l.id);
        let tops: Vec<LayerId> = doc.layers.iter().map(|l| l.id).filter(|id| Some(*id) != background).collect();
        if tops.is_empty() {
            return Err(EngineError::Other("no layers to make frames from".into()));
        }
        if tops.len() > MAX_FRAMES {
            return Err(EngineError::Other(format!("an animation has at most {MAX_FRAMES} frames")));
        }
        let a = animation(doc)?;
        let cur = a.current;
        let base = a.frames.get(cur).cloned().unwrap_or(AnimationFrame { delay: DEFAULT_FRAME_DELAY, layers: Default::default() });
        let mut frames = Vec::with_capacity(tops.len());
        for id in &tops {
            let mut f = base.clone();
            for other in &tops {
                if let Some(l) = f.layers.get_mut(&other.0) {
                    l.visible = other == id;
                }
            }
            if let Some(b) = background.and_then(|b| f.layers.get_mut(&b.0)) {
                b.visible = true;
            }
            frames.push(f);
        }
        // What shows now goes in front for a moment, so the first new frame is shown from it.
        a.frames = std::iter::once(base).chain(frames).collect();
        a.current = 0;
        show(doc, 0, 1)?;
        let a = animation(doc)?;
        a.frames.remove(0);
        a.current = 0;
        Ok(())
    })?;
    info(s)
}

fn set_delay(s: &mut Session, p: &Value) -> Result<Value> {
    const CMD: &str = "animation.setDelay";
    let a = s.active().and_then(|d| d.doc.animation.clone()).ok_or_else(|| EngineError::Other("no frame animation".into()))?;
    let which = frames_param(CMD, p, &a)?;
    let delay = p
        .get("delay")
        .and_then(Value::as_f64)
        .filter(|d| d.is_finite() && (0.0..=600.0).contains(d))
        .ok_or_else(|| bad(CMD, "`delay` must be 0 to 600 seconds"))?;
    s.edit("Frame Delay", |doc, _| {
        capture(doc);
        let a = animation(doc)?;
        for i in &which {
            if let Some(f) = a.frames.get_mut(*i) {
                f.delay = delay as f32;
            }
        }
        Ok(())
    })?;
    info(s)
}

fn set_loops(s: &mut Session, p: &Value) -> Result<Value> {
    const CMD: &str = "animation.setLoops";
    let loops = match p.get("loops") {
        Some(Value::String(v)) if v == "forever" => 0,
        Some(v) => v.as_u64().filter(|n| (1..=65_535).contains(n)).ok_or_else(|| bad(CMD, "`loops` must be \"forever\" or 1 to 65535"))? as u32,
        None => return Err(bad(CMD, "`loops` is required")),
    };
    s.edit("Looping", |doc, _| {
        animation(doc)?.loops = loops;
        Ok(())
    })?;
    info(s)
}

fn reverse(s: &mut Session) -> Result<Value> {
    s.edit("Reverse Frames", |doc, _| {
        capture(doc);
        let a = animation(doc)?;
        a.frames.reverse();
        a.current = a.frames.len() - 1 - a.current;
        Ok(())
    })?;
    info(s)
}

/// An animated GIF as a document: one layer per frame (bottom first), each frame showing its
/// layer. `None` for a GIF of one frame.
pub fn document_from_gif(name: &str, bytes: &[u8]) -> Result<Option<Document>> {
    let mut frames: Vec<(Document, u32)> = Vec::new();
    photocraft_io::import_gif_frames(name, bytes, &mut |doc, delay_ms| {
        frames.push((doc, delay_ms));
        Ok(())
    })
    .map_err(|e| EngineError::Other(e.to_string()))?;
    Ok(document_from_frames(&frames, 0))
}

/// Full-canvas frames (a document and a delay in milliseconds each) as one document: a layer
/// per frame and the frame animation that shows them in turn. `loops` 0 plays forever. `None`
/// for fewer than two frames.
pub fn document_from_frames(frames: &[(Document, u32)], loops: u32) -> Option<Document> {
    if frames.len() < 2 {
        return None;
    }
    let mut base = frames[0].0.clone();
    base.layers.clear();
    let mut anim = FrameAnimation { frames: Vec::with_capacity(frames.len()), current: 0, loops };
    let mut ids = Vec::new();
    for (i, (d, _)) in frames.iter().enumerate() {
        let Some(mut l) = d.layers.first().cloned() else { continue };
        l.id = LayerId::fresh();
        l.name = format!("Frame {}", i + 1);
        l.locks = Default::default();
        l.visible = i == 0;
        ids.push(l.id);
        base.layers.push(l);
    }
    for (i, (_, delay)) in frames.iter().enumerate() {
        let layers = ids.iter().enumerate().map(|(j, id)| (id.0, FrameLayer { visible: i == j, opacity: 1.0, offset: [0, 0] })).collect();
        anim.frames.push(AnimationFrame { delay: *delay as f32 / 1000.0, layers });
    }
    base.animation = Some(anim);
    Some(base)
}

macro_rules! spec {
    ($id:literal, $label:literal, $params:literal, $en:expr, $run:expr, $journal:expr) => {
        CommandSpec { id: $id, label: $label, menu: &[], shortcut: None, params: $params, enabled: $en, run: $run, journal: $journal }
    };
}

pub fn specs() -> Vec<CommandSpec> {
    vec![
        spec!("animation.create", "Create Frame Animation", "{} → {animation}", has_doc, |s, _| create(s), true),
        spec!("animation.delete", "Delete Animation", "{} → {animation:null}", has_animation, |s, _| delete_animation(s), true),
        spec!("animation.selectFrame", "Go to Frame", r#"{"frame":index} → {animation}"#, has_animation, select, true),
        spec!("animation.newFrame", "New Frame", "{} (a copy of the current frame, after it) → {animation}", has_animation, |s, _| new_frame(s), true),
        spec!("animation.deleteFrames", "Delete Frame", r#"{"frames":[index]|"all"?} (default the current) → {animation}"#, has_animation, delete_frames, true),
        spec!("animation.makeFramesFromLayers", "Make Frames From Layers", "{} → {animation}", has_doc, |s, _| frames_from_layers(s), true),
        spec!("animation.setDelay", "Frame Delay", r#"{"delay":0..600 (seconds),"frames":[index]|"all"?} → {animation}"#, has_animation, set_delay, true),
        spec!("animation.setLoops", "Looping", r#"{"loops":"forever"|1..65535} → {animation}"#, has_animation, set_loops, true),
        spec!("animation.reverseFrames", "Reverse Frames", "{} → {animation}", has_animation, |s, _| reverse(s), true),
        spec!("animation.info", "Animation Info", "{} → {animation:{frames:[{delay}],current,loops}|null}", has_doc, |s, _| info(s), false),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A transparent document with three small layers side by side.
    fn session() -> (Session, Vec<u64>) {
        let mut s = Session::new();
        s.execute("file.new", json!({"width": 60, "height": 20, "background": "transparent"})).unwrap();
        let mut ids = Vec::new();
        for i in 0..3 {
            s.execute("layer.new.layer", json!({"name": format!("L{i}")})).unwrap();
            s.execute("select.rect", json!({"x": i * 20, "y": 0, "width": 10, "height": 10})).unwrap();
            s.execute("edit.fill", json!({"contents": "black"})).unwrap();
            s.execute("select.deselect", json!({})).unwrap();
            ids.push(s.active().unwrap().active_layer.unwrap().0);
        }
        (s, ids)
    }

    fn visible(s: &Session) -> Vec<bool> {
        s.active().unwrap().doc.layers.iter().skip(1).map(|l| l.visible).collect()
    }

    #[test]
    fn frames_from_layers_show_one_layer_each_and_keep_their_own_moves() {
        let (mut s, ids) = session();
        let first = s.execute("animation.create", json!({})).unwrap();
        assert!((first["animation"]["frames"][0]["delay"].as_f64().unwrap() - 0.1).abs() < 1e-6, "0.1 s, as viewers play a GIF's shortest delays");
        let out = s.execute("animation.makeFramesFromLayers", json!({})).unwrap();
        assert_eq!(out["animation"]["frames"].as_array().unwrap().len(), 4, "the empty bottom layer is a layer too");
        s.execute("animation.selectFrame", json!({"frame": 1})).unwrap();
        assert_eq!(visible(&s), [true, false, false]);
        // A copy of frame 1, with its layer moved down in that frame only.
        s.execute("animation.newFrame", json!({})).unwrap();
        s.execute("layer.translate", json!({"layer": ids[0], "dy": 5})).unwrap();
        let bounds = |s: &Session| s.active().unwrap().doc.layer(LayerId(ids[0])).unwrap().surface().unwrap().content_bounds();
        assert_eq!(bounds(&s).y0, 5);
        s.execute("animation.selectFrame", json!({"frame": 1})).unwrap();
        assert_eq!(bounds(&s).y0, 0, "back where frame 1 had it");
        s.execute("animation.selectFrame", json!({"frame": 2})).unwrap();
        assert_eq!(bounds(&s).y0, 5);
        s.execute("animation.selectFrame", json!({"frame": 3})).unwrap();
        assert_eq!(visible(&s), [false, true, false]);
        assert_eq!(bounds(&s).y0, 0, "the hidden layer is back in place too");
        // Hiding a layer while a frame shows belongs to that frame.
        s.execute("animation.selectFrame", json!({"frame": 0})).unwrap();
        let hist = s.active().unwrap().history.entries().len();
        s.execute("animation.selectFrame", json!({"frame": 3})).unwrap();
        assert_eq!(s.active().unwrap().history.entries().len(), hist, "going to a frame isn't a step");
    }

    #[test]
    fn delay_loops_delete_and_reverse() {
        let (mut s, _) = session();
        s.execute("animation.makeFramesFromLayers", json!({})).unwrap();
        s.execute("animation.setDelay", json!({"frames": "all", "delay": 0.2})).unwrap();
        s.execute("animation.setLoops", json!({"loops": 3})).unwrap();
        s.execute("animation.selectFrame", json!({"frame": 3})).unwrap();
        let out = s.execute("animation.deleteFrames", json!({"frames": [0, 3]})).unwrap();
        let a = &out["animation"];
        assert_eq!(a["frames"].as_array().unwrap().len(), 2);
        assert!((a["frames"][1]["delay"].as_f64().unwrap() - 0.2).abs() < 1e-6);
        assert_eq!(a["loops"], 3);
        assert_eq!(a["current"], 1, "the last kept frame shows");
        let out = s.execute("animation.reverseFrames", json!({})).unwrap();
        assert_eq!(out["animation"]["current"], 0);
        s.execute("edit.undo", json!({})).unwrap();
        assert_eq!(s.execute("animation.info", json!({})).unwrap()["animation"]["current"], 1);
    }

    #[test]
    fn a_frame_document_shows_that_frame() {
        let (mut s, _) = session();
        s.execute("animation.makeFramesFromLayers", json!({})).unwrap();
        let doc = s.active().unwrap().doc.clone();
        let f2 = frame_document(&doc, 2).unwrap();
        assert_eq!(f2.layers.iter().skip(1).map(|l| l.visible).collect::<Vec<_>>(), [false, true, false]);
        assert_eq!(visible(&s), [false, false, false], "the document still shows frame 0 (the empty layer)");
    }

    #[test]
    fn save_for_web_writes_every_frame_and_an_animated_gif_opens_as_frames() {
        let (mut s, _) = session();
        s.execute("animation.makeFramesFromLayers", json!({})).unwrap();
        s.execute("animation.setDelay", json!({"frames": "all", "delay": 0.2})).unwrap();
        let mut gif = Vec::new();
        let out = crate::web_cmds::save_for_web_with_writer(&mut s, &json!({"format": "gif", "path": "x.gif", "loops": "forever"}), &mut |_, b| {
            gif = b.to_vec();
            Ok(())
        })
        .unwrap();
        assert_eq!(out["frames"], 4);
        assert!(gif.windows(11).any(|w| w == b"NETSCAPE2.0"), "loops forever");
        let doc = document_from_gif("x.gif", &gif).unwrap().expect("four frames");
        let a = doc.animation.as_ref().unwrap();
        assert_eq!(a.frames.len(), 4);
        assert!((a.frames[1].delay - 0.2).abs() < 1e-6);
        assert_eq!(doc.layers.len(), 4);
        assert_eq!(doc.layers.iter().map(|l| l.visible).collect::<Vec<_>>(), [true, false, false, false]);
        // Frame 2 (layer L1) keeps its transparent surround.
        let l = &doc.layers[2];
        assert_eq!(l.surface().unwrap().sample_channel(30, 15, 3), 0.0);
        assert!(l.surface().unwrap().sample_channel(25, 5, 3) > 0.9);
        let still =
            crate::web_cmds::save_for_web_with_writer(&mut s, &json!({"format": "gif", "path": "y.gif", "animate": false}), &mut |_, _| Ok(())).unwrap();
        assert!(still.get("frames").is_none(), "one frame: {still}");
    }

    #[test]
    fn bad_params_are_errors() {
        let (mut s, _) = session();
        assert!(s.execute("animation.selectFrame", json!({"frame": 0})).is_err(), "no animation yet");
        s.execute("animation.create", json!({})).unwrap();
        for (id, p) in [
            ("animation.selectFrame", json!({})),
            ("animation.selectFrame", json!({"frame": 9})),
            ("animation.setDelay", json!({"delay": -1})),
            ("animation.setDelay", json!({"delay": 1, "frames": [5]})),
            ("animation.setLoops", json!({"loops": 0})),
            ("animation.deleteFrames", json!({"frames": "all"})),
        ] {
            assert!(s.execute(id, p.clone()).is_err(), "{id} {p}");
        }
    }
}

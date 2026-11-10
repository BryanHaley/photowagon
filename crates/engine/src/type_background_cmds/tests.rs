use super::*;

fn session() -> (Session, LayerId) {
    let mut s = Session::new();
    s.execute("file.new", json!({"width": 300, "height": 120, "background": "white"})).unwrap();
    let r = s.execute("type.create", json!({"x": 20, "y": 70, "text": "Hi", "size": 36, "color": "#000000"})).unwrap();
    (s, LayerId(r["layer"].as_u64().unwrap()))
}

fn box_of(s: &Session, text: LayerId) -> (LayerId, [f64; 4], Color) {
    let d = s.active().unwrap();
    let id = background_of(&d.doc, text).expect("a background");
    let LayerContent::Shape(sh) = &d.doc.layer(id).unwrap().content else { panic!("not a shape") };
    let Some(LiveShape::Rect { rect, .. }) = sh.live else { panic!("not a rectangle") };
    let Some(Fill::Solid(c)) = sh.fill else { panic!("no fill") };
    (id, rect, c)
}

#[test]
fn a_box_goes_under_the_text_linked_and_follows_edits() {
    let (mut s, text) = session();
    s.execute(CMD, json!({"color": "#ff0000", "padding": 8})).unwrap();
    let (bg, rect, c) = box_of(&s, text);
    let d = s.active().unwrap();
    let ink = crate::layer_multi_cmds::layer_bounds(d.doc.layer(text).unwrap()).unwrap();
    assert_eq!(rect[0], f64::from(ink.x0) - 8.0);
    assert_eq!(c, Color::rgba(1.0, 0.0, 0.0, 1.0));
    assert_eq!(d.doc.layer(bg).unwrap().link_group, d.doc.layer(text).unwrap().link_group);
    assert_eq!(d.active_layer, Some(text));
    let layers = d.doc.walk().len();
    let info = s.execute("type.info", json!({})).unwrap();
    assert_eq!(info["background"]["layer"], bg.0);
    assert_eq!(info["background"]["padding"], 8.0);

    // Longer text: the same box grows with it, in the same step, keeping its colour and padding.
    s.execute("type.edit", json!({"layer": text.0, "text": "Hello there"})).unwrap();
    let (again, wider, c2) = box_of(&s, text);
    let d = s.active().unwrap();
    let ink = crate::layer_multi_cmds::layer_bounds(d.doc.layer(text).unwrap()).unwrap();
    assert_eq!((again, c2), (bg, c));
    assert_eq!(wider[2], f64::from(ink.x1 - ink.x0) + 16.0);
    s.execute("edit.undo", json!({})).unwrap();
    assert_eq!(box_of(&s, text).1, rect);
    s.execute("edit.redo", json!({})).unwrap();
    assert_eq!(s.active().unwrap().doc.walk().len(), layers);

    assert_eq!(s.execute(CMD, json!({"remove": true})).unwrap()["removed"], true);
    assert!(background_of(&s.active().unwrap().doc, text).is_none());
    s.execute("edit.undo", json!({})).unwrap();
    assert_eq!(box_of(&s, text).0, bg);
}

#[test]
fn bad_params_and_other_layers_are_refused() {
    let (mut s, text) = session();
    assert!(s.execute(CMD, json!({"padding": -1})).is_err());
    assert!(s.execute(CMD, json!({"radius": "big"})).is_err());
    let bottom = s.active().unwrap().doc.walk()[0].2.id;
    assert!(s.execute(CMD, json!({"layer": bottom.0})).is_err());
    assert!(background_of(&s.active().unwrap().doc, text).is_none());
}

#[test]
fn the_box_follows_text_that_is_scaled_or_moved() {
    let (mut s, text) = session();
    s.execute(CMD, json!({"padding": 6})).unwrap();
    let ink = |s: &Session| crate::layer_multi_cmds::layer_bounds(s.active().unwrap().doc.layer(text).unwrap()).unwrap();
    for edit in [json!({"layer": text.0, "scale": 2}), json!({"layer": text.0, "move": [30, 10]})] {
        s.execute("type.edit", edit).unwrap();
        let (_, rect, _) = box_of(&s, text);
        let i = ink(&s);
        assert_eq!([rect[0], rect[1]], [f64::from(i.x0) - 6.0, f64::from(i.y0) - 6.0]);
        assert_eq!(rect[2], f64::from(i.x1 - i.x0) + 12.0);
    }
}

#[test]
fn a_transform_preview_carries_the_box_along() {
    let (mut s, text) = session();
    s.execute(CMD, json!({"padding": 6})).unwrap();
    let (bg, rect, _) = box_of(&s, text);
    let old = crate::layer_multi_cmds::layer_bounds(s.active().unwrap().doc.layer(bg).unwrap()).unwrap();
    let job = crate::transform_cmds::preview(&s, &json!({"dx": 40})).unwrap();
    let area = job.area();
    assert!(area.x0 <= old.x0 && area.x1 >= old.x1 + 40, "{area:?} covers {old:?} and where it goes");
    let doc = job.render().unwrap();
    let LayerContent::Shape(sh) = &doc.layer(bg).unwrap().content else { panic!("not a shape") };
    let Some(LiveShape::Rect { rect: moved, .. }) = sh.live else { panic!("not a rectangle") };
    assert!((moved[0] - rect[0] - 40.0).abs() <= 1.0, "{moved:?} vs {rect:?}");
}

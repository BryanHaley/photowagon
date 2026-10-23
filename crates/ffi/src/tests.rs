use super::*;
use serde_json::Value;

struct NoHost;

impl Host for NoHost {
    fn print(&self, _: Vec<u8>, _: String) -> String {
        String::new()
    }
}

fn editor() -> Arc<Editor> {
    let e = Editor::new(Arc::new(NoHost));
    e.new_document(64, 48).unwrap();
    e
}

fn pt(x: f64, y: f64) -> StrokePoint {
    StrokePoint { x, y, pressure: 1.0, tilt_x: 0.0, tilt_y: 0.0, rotation: 0.0, time_ms: 0.0 }
}

fn pixel(e: &Editor, x: u32, y: u32) -> Vec<f64> {
    let v: Value = serde_json::from_str(&e.execute("document.sampleColor".into(), json!({"x": x, "y": y}).to_string()).unwrap()).unwrap();
    v.as_array().unwrap().iter().map(|c| c.as_f64().unwrap()).collect()
}

#[test]
fn a_live_brush_stroke_commits_as_one_step_with_its_pixels() {
    let e = editor();
    e.execute("tools.setColors".into(), r##"{"foreground":"#ff0000"}"##.into()).unwrap();
    let params = json!({"size": 6, "hardness": 1}).to_string();
    e.stroke_begin("paint.stroke".into(), params, vec![pt(10.0, 20.0)]).unwrap();
    e.stroke_push(vec![pt(30.0, 20.0), pt(50.0, 20.0)]).unwrap();
    let result: Value = serde_json::from_str(&e.stroke_end().unwrap()).unwrap();
    assert_eq!(result["fromLive"], true, "{result}");
    let red = pixel(&e, 30, 20);
    assert!(red[0] > 0.9 && red[1] < 0.1, "{red:?}");
    let info = e.document().unwrap();
    assert!(info.can_undo);
    e.execute("edit.undo".into(), String::new()).unwrap();
    assert!(pixel(&e, 30, 20)[1] > 0.9, "undo restores white");
}

#[test]
fn a_clone_stamp_stroke_copies_from_the_source() {
    let e = editor();
    e.execute("select.rect".into(), json!({"x": 0, "y": 0, "width": 10, "height": 48}).to_string()).unwrap();
    e.execute("edit.fill".into(), json!({"contents": "black"}).to_string()).unwrap();
    e.execute("select.deselect".into(), String::new()).unwrap();
    e.execute("cloneSource.set".into(), json!({"source": [5, 24]}).to_string()).unwrap();
    e.stroke_begin("paint.cloneStamp".into(), json!({"size": 5, "hardness": 100}).to_string(), vec![pt(40.0, 24.0)]).unwrap();
    e.stroke_end().unwrap();
    assert!(pixel(&e, 40, 24)[0] < 0.1);
}

#[test]
fn bad_input_is_an_error_not_a_crash() {
    let e = Editor::new(Arc::new(NoHost));
    assert!(e.execute("paint.stroke".into(), "{".into()).is_err());
    assert!(e.execute("no.such.command".into(), String::new()).is_err());
    assert!(e.stroke_push(vec![pt(1.0, 1.0)]).is_err());
    assert!(e.stroke_end().is_err());
    assert!(e.export("png".into(), None).is_err());
    assert!(e.open("x.png".into(), vec![1, 2, 3], false).is_err());
    assert!(e.layer_thumbnail(7, 64).is_err());
    assert!(e.stroke_begin("paint.stroke".into(), String::new(), vec![pt(f64::NAN, 0.0)]).is_err());
    let e = editor();
    assert!(e.stroke_begin("paint.stroke".into(), String::new(), vec![]).is_err());
    assert!(e.attach(0, 10, 10).is_err());
}

#[test]
fn a_selection_has_an_outline_on_screen() {
    let e = editor();
    let view = ViewState { width: 128, height: 96, zoom: 2.0, center_x: 32.0, center_y: 24.0, rotation: 0.0, pixels_per_point: 2.0 };
    assert!(e.selection_outline(view).is_empty());
    assert!(e.commands().iter().any(|c| c.id == "select.deselect" && !c.enabled));
    e.execute("select.rect".into(), json!({"x": 8, "y": 8, "width": 16, "height": 16}).to_string()).unwrap();
    assert!(e.commands().iter().any(|c| c.id == "select.deselect" && c.enabled && c.menu == "Select"));
    let segs = e.selection_outline(view);
    assert_eq!(segs.len() % 4, 0);
    assert!(segs.chunks(2).any(|p| p == [16.0, 16.0]), "the corner (8, 8) lands at screen (16, 16): {segs:?}");
}

#[test]
fn files_round_trip_through_bytes() {
    let e = editor();
    for format in ["png", "jpg", "psd", "pcraft"] {
        let bytes = e.export(format.into(), None).unwrap();
        let info = e.open(format!("a.{format}"), bytes, false).unwrap();
        assert_eq!((info.width, info.height), (64, 48), "{format}");
    }
    let thumb = e
        .layer_thumbnail(
            e.execute("layer.list".into(), String::new()).map(|v| serde_json::from_str::<Value>(&v).unwrap()["layers"][0]["id"].as_u64().unwrap()).unwrap(),
            32,
        )
        .unwrap();
    assert!(thumb.starts_with(b"\x89PNG"));
    let saved = e.export("pcraft".into(), None).unwrap();
    assert!(crate::pcraft_thumbnail(saved).is_some_and(|t| t.starts_with(b"\x89PNG")));
    assert!(crate::pcraft_thumbnail(b"not a file".to_vec()).is_none());
}

#[test]
fn key_bindings_come_from_the_engine_with_their_kind() {
    let e = editor();
    let keys = e.key_bindings();
    let find = |id: &str| keys.iter().filter(|k| k.id == id).map(|k| (k.shortcut.as_str(), k.kind.as_str())).collect::<Vec<_>>();
    assert_eq!(find("edit.undo"), [("Cmd+Z", "command")]);
    assert_eq!(find("tools.select.brush"), [("B", "tool")]);
    assert_eq!(find("tools.temporary.hand"), [("Space", "hold")]);
    assert_eq!(find("view.fitOnScreen"), [("Cmd+0", "shell")]);
    assert!(find("edit.fill").contains(&("Shift+Backspace", "command")), "alternates too");
    e.execute("tools.increaseBrushSize".into(), String::new()).unwrap();
    let before = e.tool_settings().size;
    e.execute("tools.increaseBrushSize".into(), String::new()).unwrap();
    assert!(e.tool_settings().size > before);
}

#[test]
fn a_live_dodge_stroke_lightens() {
    let e = editor();
    e.execute("edit.fill".into(), json!({"contents": "gray"}).to_string()).unwrap();
    let before = pixel(&e, 30, 24)[0];
    e.stroke_begin("paint.dodge".into(), json!({"size": 20, "hardness": 100, "opacity": 100}).to_string(), vec![pt(10.0, 24.0)]).unwrap();
    e.stroke_push(vec![pt(30.0, 24.0), pt(50.0, 24.0)]).unwrap();
    e.stroke_end().unwrap();
    assert!(pixel(&e, 30, 24)[0] > before + 0.02, "{before}");
}

#[test]
fn a_transform_preview_leaves_the_document_until_it_ends() {
    let e = editor();
    e.execute("layer.new.layer".into(), "{}".into()).unwrap();
    e.execute("select.rect".into(), json!({"x": 4, "y": 4, "width": 10, "height": 10}).to_string()).unwrap();
    e.execute("edit.fill".into(), json!({"contents": "black"}).to_string()).unwrap();
    e.execute("select.deselect".into(), "{}".into()).unwrap();
    let before = e.document().unwrap().revision;
    let p = json!({"rect": [4, 4, 14, 14], "quad": [[20, 4], [30, 4], [30, 14], [20, 14]]});
    e.preview_transform(p.to_string()).unwrap();
    assert_eq!(e.document().unwrap().revision, before);
    assert!(e.lock().preview.as_ref().is_some_and(|p| p.area.contains(25, 8)));
    e.end_preview();
    assert!(e.lock().preview.is_none());
}

#[test]
fn command_fields_come_from_the_params_doc() {
    let e = editor();
    let f = e.command_fields("filter.blur.gaussianBlur".into());
    assert_eq!(f.len(), 1);
    assert_eq!(f[0].name, "radius");
    assert!(e.command_fields("no.such.command".into()).is_empty());
}

#[test]
fn decoded_images_keep_the_original_name_and_libraw_refuses_other_files() {
    let e = editor();
    let tiff = e.export("tiff".into(), None).unwrap();
    let info = e.open_decoded("photo.heic".into(), tiff).unwrap();
    assert_eq!((info.name.as_str(), info.width, info.height), ("photo.heic", 64, 48));
    assert!(e.open_libraw("x.raf".into(), vec![0; 64]).is_err());
    assert_eq!(e.document().unwrap().name, "photo.heic");
}

#[test]
fn documents_stay_open_side_by_side() {
    let e = editor();
    let first = e.document().unwrap().id;
    e.new_document(32, 16).unwrap();
    let docs = e.documents();
    assert_eq!(docs.iter().map(|d| (d.width, d.height)).collect::<Vec<_>>(), [(64, 48), (32, 16)]);
    assert_eq!(e.activate(0).unwrap().id, first);
    e.close(0);
    assert_eq!(e.documents().len(), 1);
    assert_eq!(e.document().unwrap().width, 32);
    assert!(e.activate(5).is_err());
}

#[test]
fn render_region_is_transparent_past_the_canvas_and_capped() {
    let e = editor();
    e.execute("tools.setColors".into(), r##"{"foreground":"#ff0000"}"##.into()).unwrap();
    e.execute("edit.fill".into(), "{}".into()).unwrap();
    // 4 × 2 straddling the left edge: two pixels outside, two red inside.
    let px = e.render_region(-2, 10, 4, 2).unwrap();
    assert_eq!(px.len(), 4 * 2 * 4);
    assert_eq!(&px[0..4], &[0, 0, 0, 0]);
    assert_eq!(&px[8..12], &[255, 0, 0, 255]);
    assert_eq!(&px[16 + 12..16 + 16], &[255, 0, 0, 255], "second row");
    assert!(e.render_region(1000, 1000, 8, 8).unwrap().iter().all(|&b| b == 0));
    assert!(e.render_region(i32::MAX, i32::MIN, 8, 8).is_ok());
    assert_eq!(e.render_region(0, 0, u32::MAX, 0).unwrap().len(), 0);
    assert_eq!(e.render_region(0, 0, 9999, 1).unwrap().len(), MAX_REGION_SIDE as usize * 4);
}

#[test]
fn view_mask_shows_the_mask_in_gray() {
    let e = editor();
    e.execute("layer.new.layer".into(), "{}".into()).unwrap();
    e.execute("layer.layerMask.hideAll".into(), "{}".into()).unwrap();
    e.execute("select.rect".into(), r#"{"x":0,"y":0,"width":32,"height":48}"#.into()).unwrap();
    e.execute("edit.fill".into(), r#"{"contents":"white","target":"mask"}"#.into()).unwrap();
    let doc = e.with(|inner| Ok(inner.session.active().map(|s| s.doc.clone()))).unwrap().unwrap();
    let layer = doc.layers.last().unwrap().id;
    let picture = mask_picture(&doc, layer).unwrap();
    assert_eq!(picture.layers.len(), 1);
    let s = picture.layers[0].surface().unwrap();
    assert!(s.rgba(10, 10)[0] > 0.99, "white where the mask shows");
    assert!(s.rgba(50, 10)[0] < 0.01, "black where it hides");
    assert!(mask_picture(&doc, doc.layers[0].id).is_none(), "no mask, nothing to show");
}

#[test]
fn stroke_pressure_follows_the_pressure_curve() {
    let e = editor();
    let half = StrokePoint { pressure: 0.5, ..pt(1.0, 1.0) };
    let p = |e: &Editor| e.with(|inner| Ok(shaped(&inner.session, vec![half]))).unwrap()[0].pressure;
    assert_eq!(p(&e), 0.5, "linear at first");
    e.execute("prefs.set".into(), json!({"path": "tools.pressureCurve", "value": [[0, 0], [0.6, 0.35], [1, 1]]}).to_string()).unwrap();
    assert!(p(&e) < 0.4, "a firmer press for the same pressure: {}", p(&e));
}

#[test]
fn the_brush_preview_paints_the_current_brush() {
    let e = editor();
    let png = e.brush_preview(200, 60).unwrap();
    let img = photocraft_codecs::decode(&png).unwrap();
    assert_eq!((img.width(), img.height()), (200, 60));
    let px = img.convert(photocraft_codecs::ChannelLayout::Rgba, photocraft_codecs::SampleType::U8).data().to_vec();
    assert!(px.chunks(4).any(|c| c[3] > 200), "the stroke shows");
    assert!(px.chunks(4).any(|c| c[3] == 0), "on a clear background");
}

#[test]
fn unzip_writes_the_files_and_refuses_names_that_leave_the_folder() {
    let dir = std::env::temp_dir().join(format!("pw-unzip-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let pack = |name: &str, entries: &[(&str, &[u8])]| {
        let mut w = photocraft_format::zip::ZipWriter::new();
        for (n, b) in entries {
            w.add(n, b).unwrap();
        }
        let path = dir.join(name);
        std::fs::write(&path, w.finish().unwrap()).unwrap();
        path.to_string_lossy().into_owned()
    };
    let out = dir.join("out").to_string_lossy().into_owned();
    unzip(pack("ok.zip", &[("M.mlpackage/Manifest.json", b"{}"), ("M.mlpackage/Data/w.bin", &[7; 100])]), out.clone()).unwrap();
    assert_eq!(std::fs::read(dir.join("out/M.mlpackage/Data/w.bin")).unwrap(), vec![7; 100]);
    assert!(unzip(pack("bad.zip", &[("../escape", b"x")]), out.clone()).is_err());
    assert!(!dir.join("escape").exists());
    assert!(unzip(dir.join("none.zip").to_string_lossy().into_owned(), out).is_err());
    let _ = std::fs::remove_dir_all(&dir);
}

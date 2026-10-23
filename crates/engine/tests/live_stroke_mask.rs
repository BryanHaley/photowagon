//! A live brush stroke (the iOS app's) paints the targeted layer mask, on a smart object too.

use photocraft_engine::Session;
use photocraft_engine::brush_cmds::LiveStroke;
use serde_json::json;

#[test]
fn a_live_stroke_paints_the_targeted_mask_of_a_smart_object() {
    for smart in [false, true] {
        let mut s = Session::new();
        s.execute("file.new", json!({"width": 64, "height": 64})).unwrap();
        s.execute("layer.new.layer", json!({})).unwrap();
        s.execute("edit.fill", json!({"color": [1.0, 0.0, 0.0]})).unwrap();
        if smart {
            s.execute("layer.smartObjects.convertToSmartObject", json!({})).unwrap();
        }
        s.execute("layer.layerMask.revealAll", json!({})).unwrap();
        s.execute("channel.target.layerMask", json!({})).unwrap();
        let p = json!({"points": [[10, 30, 1], [50, 30, 1]], "size": 10, "color": "#000000"});
        let live = LiveStroke::begin_with(&s, "paint.stroke", &p).unwrap();
        let mut p = p;
        p["seed"] = json!(live.seed);
        s.offer_live_stroke(live).unwrap();
        s.execute("paint.stroke", p).unwrap();
        let st = s.execute("document.stats", json!({"of": "mask", "rect": [20, 28, 40, 32]})).unwrap();
        assert_eq!(st["mean"][0], 0.0, "smart {smart}: the mask is painted black");
    }
}

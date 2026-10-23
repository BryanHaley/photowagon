//! Live strokes: the Brush, Pencil and Eraser, the Clone Stamp, Healing Brush and History Brush,
//! and the dodge, burn, sponge, blur and sharpen tools render onto a copy of the document while
//! the finger or pen moves; other stroke commands (Spot Healing, Quick Selection, …) only
//! collect points. The stroke commits as its command with
//! every point.

use std::sync::Arc;

use photocraft_doc::Document;
use photocraft_engine::brush_cmds::LiveStroke;
use photocraft_engine::retouch_cmds::{LiveDab, LiveRetouch};
use photocraft_engine::{Result, Session};
use photocraft_geom::Rect;
use photocraft_paint::StrokePoint;
use serde_json::{Value, json};

enum Preview {
    Brush(LiveStroke),
    Retouch(LiveRetouch),
    Dab(LiveDab),
    None,
}

pub struct Live {
    cmd: String,
    params: Value,
    points: Vec<StrokePoint>,
    preview: Preview,
    /// Changed since the canvas last showed it.
    pub damage: Option<Rect>,
}

impl Live {
    pub fn begin(s: &Session, cmd: &str, params: Value, first: &[StrokePoint]) -> Result<Self> {
        let p = with_points(&params, first);
        let preview = match cmd {
            "paint.stroke" | "paint.pencil" => Preview::Brush(LiveStroke::begin_with(s, cmd, &p)?),
            "paint.cloneStamp" | "paint.healingBrush" | "paint.historyBrush" => Preview::Retouch(LiveRetouch::begin(s, cmd, &p)?),
            "paint.dodge" | "paint.burn" | "paint.sponge" | "paint.blur" | "paint.sharpen" => Preview::Dab(LiveDab::begin(s, cmd, &p)?),
            _ => Preview::None,
        };
        let damage = match &preview {
            Preview::Brush(l) => Some(l.bounds()),
            Preview::Retouch(l) => Some(l.bounds()),
            Preview::Dab(l) => Some(l.bounds()),
            Preview::None => None,
        };
        Ok(Self { cmd: cmd.into(), params, points: first.to_vec(), preview, damage })
    }

    pub fn push(&mut self, pts: &[StrokePoint]) -> Result<()> {
        if pts.is_empty() {
            return Ok(());
        }
        let changed = match &mut self.preview {
            Preview::Brush(l) => Some(l.push(pts)?),
            Preview::Retouch(l) => Some(l.push(pts)?),
            Preview::Dab(l) => Some(l.push(pts)?),
            Preview::None => None,
        };
        self.points.extend_from_slice(pts);
        if let Some(r) = changed {
            self.damage = Some(self.damage.map_or(r, |d| d.union(&r)));
        }
        Ok(())
    }

    /// The document with the stroke so far, when it is previewed.
    pub fn doc(&self) -> Option<&Arc<Document>> {
        match &self.preview {
            Preview::Brush(l) => Some(&l.doc),
            Preview::Retouch(l) => Some(&l.doc),
            Preview::Dab(l) => Some(&l.doc),
            Preview::None => None,
        }
    }

    /// Everything the preview touched.
    pub fn bounds(&self) -> Option<Rect> {
        match &self.preview {
            Preview::Brush(l) => Some(l.bounds()),
            Preview::Retouch(l) => Some(l.bounds()),
            Preview::Dab(l) => Some(l.bounds()),
            Preview::None => None,
        }
    }

    /// Run the stroke's command with every point; the preview's pixels are reused when the
    /// command accepts them.
    pub fn commit(self, s: &mut Session) -> Result<Value> {
        let mut p = with_points(&self.params, &self.points);
        match self.preview {
            Preview::Brush(l) => {
                p["seed"] = json!(l.seed);
                s.offer_live_stroke(l)?;
            }
            // The Healing Brush blends on release, so its offer is refused: the command renders.
            Preview::Retouch(l) => {
                let _ = s.offer_live_retouch(l);
            }
            Preview::Dab(_) | Preview::None => {}
        }
        let result = s.execute(&self.cmd, p);
        s.clear_live_stroke();
        result
    }
}

/// `params` with `points` as the engine reads them: `[x, y, pressure, tiltX, tiltY, rotation,
/// timeMs, wheel]`.
fn with_points(params: &Value, pts: &[StrokePoint]) -> Value {
    let mut p = if params.is_object() { params.clone() } else { json!({}) };
    p["points"] = pts.iter().map(|q| json!([q.x, q.y, q.pressure, q.tilt_x, q.tilt_y, q.rotation, q.time, q.wheel])).collect();
    p
}

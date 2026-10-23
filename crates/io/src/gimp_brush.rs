//! GIMP and Krita brush tips → brush presets: GIMP brushes (`.gbr`), image pipes (`.gih`, first
//! image only), generated brushes (`.vbr`), Krita presets (`.kpp`: tip, size and spacing) and
//! Krita resource bundles (`.bundle`, its `brushes/` and `paintoppresets/` folders). Read from
//! the published GIMP formats (`devel-docs/gbr.txt`, `gih.txt`, `vbr.txt`) and Krita's files.

use photocraft_paint::{BrushPreset, BrushSettings, GrayTile, TipShape};

use crate::abr_map::{AbrImport, MAX_TIP_EDGE};

/// Largest tip side accepted from a file before downsampling (GIMP's own limit is far lower).
const MAX_FILE_SIDE: u32 = 10_000;
/// Largest bundle entry read.
const MAX_ENTRY: usize = 64 << 20;
/// Most tips taken from one bundle.
const MAX_BUNDLE_TIPS: usize = 2000;

/// The file kinds [`read_brush_file`] reads, by extension.
pub const EXTENSIONS: [&str; 5] = ["gbr", "gih", "vbr", "kpp", "bundle"];

/// Tips in `bytes` (kind from `name`'s extension) as presets in `group`.
pub fn read_brush_file(name: &str, bytes: &[u8], group: &str) -> Result<AbrImport, String> {
    let ext = std::path::Path::new(name).extension().map(|e| e.to_string_lossy().to_ascii_lowercase()).unwrap_or_default();
    let stem = std::path::Path::new(name).file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let mut out = AbrImport::default();
    match ext.as_str() {
        "gbr" => {
            let (tip, _) = read_gbr(bytes)?;
            out.presets.push(tip.preset(&stem, group));
        }
        "gih" => out.presets.push(read_gih(bytes, &mut out.warnings)?.preset(&stem, group)),
        "vbr" => out.presets.push(read_vbr(bytes, &mut out.warnings)?.preset(&stem, group)),
        "kpp" => out.presets.push(read_kpp(bytes, &|_| None, &mut out.warnings)?.preset(&stem, group)),
        "bundle" => read_bundle(bytes, group, &mut out)?,
        _ => return Err(format!("{name}: not a GIMP or Krita brush file (.gbr, .gih, .vbr, .kpp, .bundle)")),
    }
    out.warnings.sort();
    out.warnings.dedup();
    Ok(out)
}

struct Tip {
    name: String,
    brush: BrushSettings,
}

impl Tip {
    fn preset(self, fallback: &str, group: &str) -> BrushPreset {
        let name = if self.name.trim().is_empty() { fallback.to_string() } else { self.name.trim().to_string() };
        BrushPreset { name, brush: self.brush, builtin: false, group: group.to_string(), folder: Vec::new(), captures: Default::default() }
    }
}

fn sampled(name: String, w: u32, h: u32, v: Vec<f32>, spacing: f32) -> Result<Tip, String> {
    if v.iter().all(|&x| x <= 1e-4) {
        return Err(format!("brush \"{name}\" has no paint"));
    }
    let (w, h, v) = crate::abr_map::fit(w, h, v, MAX_TIP_EDGE);
    let brush = BrushSettings {
        tip: TipShape::Sampled(GrayTile::from_f32(w, h, &v)),
        size: w.max(h) as f32,
        spacing: spacing.clamp(0.01, 10.0),
        pressure_size: false,
        ..BrushSettings::default()
    };
    Ok(Tip { name, brush })
}

fn be32(b: &[u8], at: usize) -> Result<u32, String> {
    at.checked_add(4).and_then(|end| b.get(at..end)).map(|s| u32::from_be_bytes([s[0], s[1], s[2], s[3]])).ok_or_else(|| "truncated brush".to_string())
}

/// One GIMP brush; also returns its length in bytes (pipes hold several back to back).
fn read_gbr(b: &[u8]) -> Result<(Tip, usize), String> {
    let header = be32(b, 0)? as usize;
    let version = be32(b, 4)?;
    let (w, h, depth) = (be32(b, 8)?, be32(b, 12)?, be32(b, 16)?);
    let (name_at, spacing) = match version {
        1 => (20, 25),
        2 | 3 => {
            if b.get(20..24) != Some(b"GIMP") {
                return Err("not a GIMP brush (no GIMP magic)".into());
            }
            (28, be32(b, 24)?)
        }
        v => return Err(format!("GIMP brush version {v} is not supported")),
    };
    if header < name_at || w == 0 || h == 0 || w > MAX_FILE_SIDE || h > MAX_FILE_SIDE || !matches!(depth, 1 | 4) {
        return Err(format!("not a valid GIMP brush ({w}×{h}, {depth} bytes per pixel)"));
    }
    let name = b.get(name_at..header).map(|n| String::from_utf8_lossy(n).trim_end_matches('\0').to_string()).ok_or("truncated brush")?;
    let len = (w as usize * h as usize).checked_mul(depth as usize).and_then(|n| n.checked_add(header)).ok_or("brush too large")?;
    let px = b.get(header..len).ok_or("truncated brush pixels")?;
    // Gray brushes store how much paint (255 = full); colour brushes paint where they're opaque.
    let v: Vec<f32> =
        if depth == 1 { px.iter().map(|&x| f32::from(x) / 255.0).collect() } else { px.as_chunks::<4>().0.iter().map(|c| f32::from(c[3]) / 255.0).collect() };
    Ok((sampled(name, w, h, v, spacing as f32 / 100.0)?, len))
}

/// The first image of a GIMP image pipe.
fn read_gih(b: &[u8], warnings: &mut Vec<String>) -> Result<Tip, String> {
    let mut lines = b.splitn(3, |&c| c == b'\n');
    let name = lines.next().map(|n| String::from_utf8_lossy(n).trim().to_string()).unwrap_or_default();
    let params = lines.next().map(|p| String::from_utf8_lossy(p).to_string()).ok_or("truncated image pipe")?;
    let cells: usize = params.split_whitespace().next().and_then(|n| n.parse().ok()).ok_or("not a GIMP image pipe")?;
    let rest = lines.next().ok_or("truncated image pipe")?;
    let (mut tip, _) = read_gbr(rest)?;
    if cells > 1 {
        warnings.push("animated brushes (.gih) keep only their first image".into());
    }
    if !name.is_empty() {
        tip.name = name;
    }
    Ok(tip)
}

/// A GIMP generated brush (versions 1.0 and 1.5).
fn read_vbr(b: &[u8], warnings: &mut Vec<String>) -> Result<Tip, String> {
    let text = String::from_utf8_lossy(b);
    let l: Vec<&str> = text.lines().map(str::trim).collect();
    if l.first() != Some(&"GIMP-VBR") {
        return Err("not a GIMP generated brush".into());
    }
    let num = |i: usize| l.get(i).and_then(|v| v.parse::<f32>().ok()).filter(|v| v.is_finite()).ok_or_else(|| "generated brush: bad value".to_string());
    // 1.0: name, spacing, radius, hardness, aspect, angle. 1.5 adds shape and spikes.
    let (spacing, radius, hardness, aspect, angle) = match l.get(1).copied() {
        Some("1.0") => (num(3)?, num(4)?, num(5)?, num(6)?, num(7)?),
        Some("1.5") => {
            if l.get(3) != Some(&"circle") || num(6)? > 2.0 {
                warnings.push("generated brushes other than circles are drawn round".into());
            }
            (num(4)?, num(5)?, num(7)?, num(8)?, num(9)?)
        }
        v => return Err(format!("generated brush version {} is not supported", v.unwrap_or("?"))),
    };
    let brush = BrushSettings {
        size: (radius * 2.0).clamp(1.0, 5000.0),
        hardness: hardness.clamp(0.0, 1.0),
        roundness: (1.0 / aspect.max(1.0)).clamp(0.01, 1.0),
        angle,
        spacing: (spacing / 100.0).clamp(0.01, 10.0),
        pressure_size: false,
        ..BrushSettings::default()
    };
    Ok(Tip { name: l.get(2).unwrap_or(&"").to_string(), brush })
}

/// The tips in a Krita bundle's `brushes/` folder, then its presets in `paintoppresets/`.
fn read_bundle(b: &[u8], group: &str, out: &mut AbrImport) -> Result<(), String> {
    let zip = photocraft_format::zip::ZipReader::new(b).map_err(|e| e.to_string())?;
    let tip_file = |file: &str| zip.find(&format!("brushes/{file}")).and_then(|e| zip.read(e, MAX_ENTRY).ok());
    for folder in ["brushes/", "paintoppresets/"] {
        for e in &zip.entries {
            let Some(file) = e.name.strip_prefix(folder) else { continue };
            if file.is_empty() || file.ends_with('/') {
                continue;
            }
            if out.presets.len() >= MAX_BUNDLE_TIPS {
                out.warnings.push(format!("only the first {MAX_BUNDLE_TIPS} tips were imported"));
                return Ok(());
            }
            let bytes = match zip.read(e, MAX_ENTRY) {
                Ok(b) => b,
                Err(err) => {
                    out.warnings.push(format!("{file}: {err}"));
                    continue;
                }
            };
            let stem = std::path::Path::new(file).file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
            let tip = if folder == "brushes/" { tip_from_file(file, &bytes, &mut out.warnings) } else { read_kpp(&bytes, &tip_file, &mut out.warnings) };
            match tip {
                Ok(t) => out.presets.push(t.preset(&stem, group)),
                Err(err) => out.warnings.push(format!("{file}: {err}")),
            }
        }
    }
    if out.presets.is_empty() {
        return Err("the bundle has no brush tips PhotoCraft can read".into());
    }
    Ok(())
}

/// A tip file by its extension.
fn tip_from_file(file: &str, bytes: &[u8], warnings: &mut Vec<String>) -> Result<Tip, String> {
    let ext = std::path::Path::new(file).extension().map(|x| x.to_string_lossy().to_ascii_lowercase()).unwrap_or_default();
    let stem = std::path::Path::new(file).file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    match ext.as_str() {
        "gbr" => read_gbr(bytes).map(|t| t.0),
        "gih" => read_gih(bytes, warnings),
        "vbr" => read_vbr(bytes, warnings),
        "png" | "jpg" | "jpeg" | "tif" | "tiff" | "svg" => image_tip(file, bytes, stem),
        _ => Err(format!("{ext} tips are not supported")),
    }
}

/// A Krita brush preset: a PNG preview whose `preset` text holds the settings as XML. A tip file
/// comes from the preset itself (embedded resources) or from `tip_file` (a bundle's `brushes/`).
fn read_kpp(b: &[u8], tip_file: &dyn Fn(&str) -> Option<Vec<u8>>, warnings: &mut Vec<String>) -> Result<Tip, String> {
    let png = photocraft_codecs::decode_as(photocraft_codecs::Format::Png, b).map_err(|e| format!("not a Krita preset: {e}"))?;
    let xml = png.meta.text.iter().find(|(k, _)| k == "preset").map(|(_, v)| v.as_str()).ok_or("not a Krita preset (no settings in the file)")?;
    let doc = roxmltree::Document::parse(xml).map_err(|e| format!("Krita preset: {e}"))?;
    let root = doc.root_element();
    let name = root.attribute("name").unwrap_or_default().to_string();
    let param = |n: &str| root.children().find(|c| c.has_tag_name("param") && c.attribute("name") == Some(n)).and_then(|c| c.text());
    let engine = root.attribute("paintopid").unwrap_or_default();
    if engine != "paintbrush" {
        warnings.push(format!("{name}: Krita's {engine} engine paints like a normal brush here"));
    }
    let def = param("brush_definition").ok_or("the Krita preset has no brush tip")?;
    let def = roxmltree::Document::parse(def).map_err(|e| format!("Krita preset: {e}"))?;
    let brush = def.root_element();
    let num = |n: roxmltree::Node, a: &str, or: f32| n.attribute(a).and_then(|v| v.parse::<f32>().ok()).filter(|v| v.is_finite()).unwrap_or(or);
    let spacing = num(brush, "spacing", 0.1).clamp(0.01, 10.0);
    let angle = num(brush, "angle", 0.0).to_degrees();
    let mut tip = match brush.attribute("type").unwrap_or_default() {
        "auto_brush" => {
            let mask = brush.children().find(|c| c.has_tag_name("MaskGenerator")).ok_or("the Krita preset has no tip shape")?;
            if mask.attribute("type") == Some("rect") {
                warnings.push(format!("{name}: square Krita tips are drawn round"));
            }
            // Krita's soft and Gaussian masks fade from the centre.
            let hardness = if mask.attribute("id").is_none_or(|id| id == "default") { num(mask, "hfade", 1.0) } else { 0.0 };
            let brush = BrushSettings {
                size: num(mask, "diameter", 20.0).clamp(1.0, 5000.0),
                hardness: hardness.clamp(0.0, 1.0),
                roundness: num(mask, "ratio", 1.0).clamp(0.01, 1.0),
                angle,
                spacing,
                pressure_size: false,
                ..BrushSettings::default()
            };
            Tip { name: String::new(), brush }
        }
        "gbr_brush" | "png_brush" | "svg_brush" => {
            let file = brush.attribute("filename").unwrap_or_default();
            let embedded = doc
                .descendants()
                .find(|n| n.has_tag_name("resource") && n.attribute("filename") == Some(file))
                .and_then(|n| n.text())
                .and_then(|t| photocraft_paint::tile::b64_decode(&t.split_whitespace().collect::<String>()));
            let bytes = embedded.or_else(|| tip_file(file)).ok_or_else(|| format!("the tip {file} isn't in the file; import the bundle it comes from"))?;
            let mut t = tip_from_file(file, &bytes, warnings)?;
            t.brush.size = (t.brush.size * num(brush, "scale", 1.0)).clamp(1.0, 5000.0);
            t.brush.spacing = spacing;
            t.brush.angle = angle;
            t
        }
        other => return Err(format!("Krita {other} tips are not supported")),
    };
    tip.name = name;
    Ok(tip)
}

/// An image tip: dark and opaque pixels paint.
fn image_tip(file: &str, bytes: &[u8], name: String) -> Result<Tip, String> {
    let doc = crate::import(file, bytes).map_err(|e| e.to_string())?.document;
    let (w, h) = (doc.size.width, doc.size.height);
    if w > MAX_FILE_SIDE || h > MAX_FILE_SIDE {
        return Err(format!("too large for a brush tip ({w}×{h})"));
    }
    let buf = photocraft_compose::render(&doc, doc.bounds());
    let v = buf.px.iter().map(|c| ((1.0 - photocraft_color::blend::lum([c[0], c[1], c[2]])) * c[3]).clamp(0.0, 1.0)).collect();
    sampled(name, w, h, v, 0.25)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gbr(name: &str, w: u32, h: u32, px: &[u8]) -> Vec<u8> {
        let name = format!("{name}\0");
        let header = 28 + name.len() as u32;
        let mut b = Vec::new();
        for v in [header, 2, w, h, 1] {
            b.extend(v.to_be_bytes());
        }
        b.extend(b"GIMP");
        b.extend(40u32.to_be_bytes());
        b.extend(name.as_bytes());
        b.extend(px);
        b
    }

    #[test]
    fn reads_a_gray_brush() {
        let imp = read_brush_file("dot.gbr", &gbr("Dot", 2, 2, &[0, 255, 128, 0]), "GIMP").unwrap();
        let p = &imp.presets[0];
        assert_eq!((p.name.as_str(), p.group.as_str()), ("Dot", "GIMP"));
        assert!((p.brush.spacing - 0.4).abs() < 1e-6);
        let TipShape::Sampled(t) = &p.brush.tip else { panic!("sampled tip") };
        assert!(t.get(1, 0) > 0.99 && t.get(0, 0) < 0.01);
    }

    #[test]
    fn reads_the_first_image_of_a_pipe() {
        let mut b = b"Splat\n2 ncells:2 dim:1 sel0:random\n".to_vec();
        b.extend(gbr("a", 1, 1, &[255]));
        b.extend(gbr("b", 1, 1, &[255]));
        let imp = read_brush_file("splat.gih", &b, "G").unwrap();
        assert_eq!(imp.presets[0].name, "Splat");
        assert!(!imp.warnings.is_empty());
    }

    #[test]
    fn reads_a_generated_brush() {
        let b = b"GIMP-VBR\n1.5\nOval\ncircle\n20\n50\n2\n0.5\n2\n30\n";
        let p = &read_brush_file("oval.vbr", b, "G").unwrap().presets[0];
        assert_eq!((p.brush.size, p.brush.hardness, p.brush.roundness, p.brush.angle), (100.0, 0.5, 0.5, 30.0));
    }

    #[test]
    fn rejects_broken_files() {
        for (name, b) in [
            ("a.gbr", gbr("x", 3, 3, &[255])),
            ("a.gbr", vec![0, 0, 0, 1]),
            ("a.gbr", gbr("x", 1, 1, &[0])),
            ("a.gih", b"x\nnope\n".to_vec()),
            ("a.vbr", b"GIMP-VBR\n1.0\nx\nnan\n".to_vec()),
            ("a.bundle", b"PK".to_vec()),
            ("a.kpp", vec![0x89, b'P', b'N', b'G']),
            ("a.kpp", kpp("<Preset/>")),
            ("a.txt", vec![]),
        ] {
            assert!(read_brush_file(name, &b, "G").is_err(), "{name} {b:?}");
        }
    }

    fn kpp(xml: &str) -> Vec<u8> {
        use photocraft_codecs::{ChannelLayout, Image, Metadata, SampleType};
        let meta = Metadata { text: vec![("version".into(), "2.2".into()), ("preset".into(), xml.into())], ..Default::default() };
        let img = Image::new(1, 1, ChannelLayout::Rgba, SampleType::U8).unwrap().with_meta(meta);
        photocraft_codecs::encode(&img, photocraft_codecs::Format::Png, &Default::default()).unwrap()
    }

    fn preset(engine: &str, brush: &str) -> String {
        format!(r#"<Preset paintopid="{engine}" name="Inky"><param type="string" name="brush_definition"><![CDATA[{brush}]]></param></Preset>"#)
    }

    #[test]
    fn reads_a_krita_auto_brush() {
        let brush =
            r#"<Brush type="auto_brush" spacing="0.2" angle="0"><MaskGenerator type="circle" id="default" diameter="40" ratio="0.5" hfade="0.7"/></Brush>"#;
        let imp = read_brush_file("inky.kpp", &kpp(&preset("paintbrush", brush)), "K").unwrap();
        let b = &imp.presets[0].brush;
        assert_eq!(imp.presets[0].name, "Inky");
        assert_eq!((b.size, b.roundness, b.hardness, b.spacing), (40.0, 0.5, 0.7, 0.2));
        assert!(matches!(b.tip, TipShape::Round) && imp.warnings.is_empty());
        let other = read_brush_file("inky.kpp", &kpp(&preset("colorsmudge", brush)), "K").unwrap();
        assert_eq!(other.warnings.len(), 1);
    }

    #[test]
    fn a_bundle_preset_takes_its_tip_from_the_bundle() {
        let brush = r#"<Brush type="gbr_brush" filename="dot.gbr" spacing="0.5" scale="2"/>"#;
        let mut z = photocraft_format::zip::ZipWriter::new();
        z.add("brushes/dot.gbr", &gbr("Dot", 2, 2, &[255; 4])).unwrap();
        z.add("brushes/disc.svg", br#"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><circle cx="4" cy="4" r="3"/></svg>"#).unwrap();
        z.add("paintoppresets/inky.kpp", &kpp(&preset("paintbrush", brush))).unwrap();
        let imp = read_brush_file("set.bundle", &z.finish().unwrap(), "Set").unwrap();
        let names: Vec<_> = imp.presets.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(names, ["Dot", "disc", "Inky"], "{:?}", imp.warnings);
        let b = &imp.presets[2].brush;
        assert!(matches!(b.tip, TipShape::Sampled(_)));
        assert_eq!((b.size, b.spacing), (4.0, 0.5));
        // Alone, the preset's tip file is missing.
        assert!(read_brush_file("inky.kpp", &kpp(&preset("paintbrush", brush)), "K").is_err());
        // Unless the preset embeds it.
        let b64 = photocraft_paint::tile::b64_encode(&gbr("Dot", 2, 2, &[255; 4]));
        let xml = preset("paintbrush", brush).replace("</Preset>", &format!(r#"<resource type="brushes" filename="dot.gbr">{b64}</resource></Preset>"#));
        assert_eq!(read_brush_file("inky.kpp", &kpp(&xml), "K").unwrap().presets[0].brush.size, 4.0);
    }

    #[test]
    fn reads_the_tips_in_a_bundle() {
        let mut z = photocraft_format::zip::ZipWriter::new();
        z.add("mimetype", b"application/x-krita-resourcebundle").unwrap();
        z.add("brushes/one.gbr", &gbr("One", 1, 1, &[255])).unwrap();
        z.add("brushes/two.svg", b"<svg").unwrap();
        let imp = read_brush_file("set.bundle", &z.finish().unwrap(), "Set").unwrap();
        assert_eq!(imp.presets.len(), 1);
        assert_eq!(imp.warnings.len(), 1);
    }
}

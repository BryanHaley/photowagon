//! The files Omega's Files section opens (`examples/make_omega_files.rs`) open here too, and what
//! they become can be saved and reopened at the same size.

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

use std::path::Path;

/// Files that aren't pictures: presets, actions, a plug-in, a table.
const NOT_PICTURES: [&str; 9] = ["abr", "aco", "ase", "atn", "csv", "grd", "pat", "shc", "wasm"];

#[test]
fn every_picture_opens_saves_and_reopens() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../ios/PhotoWagonUITests/Samples/formats");
    let mut opened = 0;
    let mut failures = Vec::new();
    for entry in std::fs::read_dir(&dir).unwrap() {
        let path = entry.unwrap().path();
        let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
        if !path.is_file() || NOT_PICTURES.contains(&ext.as_str()) {
            continue;
        }
        let name = path.file_name().unwrap().to_str().unwrap().to_string();
        let bytes = std::fs::read(&path).unwrap();
        let doc = match photocraft_io::import(&name, &bytes) {
            Ok(r) => r.document,
            Err(e) => {
                failures.push(format!("{name}: {e}"));
                continue;
            }
        };
        opened += 1;
        for format in ["psd", "png"] {
            let saved = match photocraft_io::export(&doc, format, &photocraft_io::ExportOptions::default()) {
                Ok(r) => r.bytes,
                Err(e) => {
                    failures.push(format!("{name} as {format}: {e}"));
                    continue;
                }
            };
            match photocraft_io::import(&format!("again.{format}"), &saved) {
                Ok(r) if r.document.size == doc.size => {}
                Ok(r) => failures.push(format!("{name} as {format}: {}x{} became {}x{}", doc.size.width, doc.size.height, r.document.size.width, r.document.size.height)),
                Err(e) => failures.push(format!("{name} as {format} won't reopen: {e}")),
            }
        }
    }
    assert!(opened > 50, "only {opened} files");
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

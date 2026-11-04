//! Index lookups must return the same spec, in the same order, as the registry's public slice.
use photocraft_engine::commands;

#[test]
fn every_lookup_matches_the_first_linear_match() {
    let specs = commands::command_specs();
    for spec in specs {
        let linear = specs.iter().find(|s| s.id == spec.id).unwrap();
        assert!(std::ptr::eq(commands::find(spec.id).unwrap(), linear), "{}", spec.id);
        // The id need not be a static string: control/MCP dispatch owns its input.
        let owned = spec.id.to_string();
        assert!(std::ptr::eq(commands::find(&owned).unwrap(), linear));
    }
    for id in ["", "missing.command", "FILE.NEW", "file.new\0", "💾"] {
        assert!(commands::find(id).is_none(), "{id:?}");
    }
}

#[test]
fn errors_name_the_command_as_its_menu_shows_it() {
    let mut s = photocraft_engine::Session::new();
    s.execute("file.new", serde_json::json!({"width": 8, "height": 8})).unwrap();
    let e = s.execute("image.imageSize", serde_json::json!({"width": 0, "height": 0})).unwrap_err().to_string();
    assert!(e.starts_with("Image Size: ") && !e.contains("image.imageSize"), "{e}");
    assert_eq!(photocraft_engine::command_name("missing.command"), "missing.command");
}

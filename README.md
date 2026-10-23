# PhotoWagon

A photo editor for iPhone and iPad that a user can pick up without help. Menus, tools
and panels are where they'd look for them under names they'll recognise.

PhotoWagon is a SwiftUI app on top of the [PhotoCraft](https://github.com/storytold/photocraft)
engine, an open-source image editor written in Rust. The engine handles layers, masks, adjustment
layers, layer styles, type, brushes, filters and PSD files. The app calls it through a Swift bridge.

## Build and run

You need Xcode, XcodeGen (`brew install xcodegen`) and rustup with the iOS targets
(`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`). If Homebrew's `rust` is also
installed, put rustup's `cargo` first: `export PATH=/opt/homebrew/opt/rustup/bin:$PATH`.

```sh
cargo xtask ios --sim        # build the Rust engine and its Swift bindings
cd ios && xcodegen generate  # make PhotoWagon.xcodeproj
open PhotoWagon.xcodeproj    # build and run (iOS 17 or later)
```

## What's where

| Path | What |
|---|---|
| `ios/PhotoWagon` | The SwiftUI app |
| `ios/PhotoWagonUITests` | UI tests, one file per walkthrough |
| `crates/ffi` | The Swift bridge (UniFFI) |
| `crates/*` | The PhotoCraft engine (Rust) |
| `apps/*`, `crates/ui-egui` | PhotoCraft's own desktop, web and command-line apps |

## Patents

We made a good-faith effort not to use methods covered by patents that are still in force,
Adobe's in particular. To this end we had to remove some code and functionality from the PhotoCraft core; we checked every patent and paper the code cites, and Adobe's US patents against
our features, removed the methods still covered, and replaced them with methods whose patents have expired or that we designed
ourselves. Patent states are from Google Patents and are not legal advice. If you think we've
missed something, please open an issue.

| Removed | Patent | Replaced with |
|---|---|---|
| PatchMatch and the patch-voting fill built on it, including its colour adjustment (`crates/algo/src/nonlocal.rs`, most of `inpaint.rs`). It powered Content-Aware Fill, Fill › Content-Aware, Remove, Spot Healing, Patch, Content-Aware Move and Panorama's edge fill | Adobe and Princeton: US 8,571,328, US 8,811,749, US 8,861,868, US 9,396,530 | An exemplar fill (`crates/algo/src/exemplar.rs`): the hole fills patch by patch from its edge in, after Criminisi, Pérez and Toyama (2004), whose Microsoft patents are listed expired. Colour adaptation uses Poisson blending (Pérez, Gangnet and Blake, 2003; Microsoft US 6,856,705, listed expired) |
| Seam carving (`crates/algo/src/seam.rs`), used by Content-Aware Scale | MERL: US 7,477,800 | Our own warp (`crates/algo/src/retarget.rs`): each column, then each row, shrinks or stretches by how much detail it holds. The command is now Content-Preserving Scale |
| Content-preserving wide-angle correction (`crates/algo/src/wideangle.rs`, the desktop dialog `wide_angle_ui.rs`, and its solver) | Adobe: US 8,525,871, US 9,742,994 | Nothing: the Adaptive Wide Angle command is deleted. Old documents open, minus that filter |
| Guided Upright, straightening a photo from lines the user draws (`crates/algo/src/upright.rs` and its Develop setting) | Adobe: US 9,519,954, US 9,729,787, US 10,652,472 | Nothing: removed |
| The exemplar fill's coarse-to-fine source map: sources found on a small copy, carried up to full size (`crates/algo/src/exemplar.rs`) | Adobe: US 9,305,329, US 9,396,530, US 11,449,974 | Each smaller copy only gives guide colours to the next size up; sources are searched again at every size, by patch descriptors. A large fill takes about 1 s, up from 0.3 s |
| Fill from Surroundings' automatic sampling area: clustering the pixels around the hole and growing those clusters (`crates/algo/src/content_aware.rs`) | Adobe: US 11,042,969 | The plain sampling window around the hole, without leaving out areas that look different |
| Fill from Surroundings' custom sampling area: the Sampling Brush, a user-chosen area and an alpha channel as the area (`crates/algo/src/content_aware.rs`, `edit.contentAwareFill`'s params) | Adobe: US 10,706,509 | Nothing: only the automatic and rectangular windows |
| Spot Healing's Proximity Match: searching around the spot for one source region to copy (`inpaint::best_offset`) | Adobe: US 7,471,417 | Match Nearby (`crates/algo/src/resynth.rs`): each pixel picks its own source by per-pixel resynthesis, after Harrison (2001) |
| Content-Aware Scale on a selection: resizing one region by its energy and leaving the rest (`crates/engine/src/edit_menu_cmds.rs`) | Adobe: US 8,160,398 | Content-Preserving Scale always scales the whole layer |
| Refine Edge's matting: the guided filter's local colour fit on the selection's edge, also used by Select › Sky and Focus Area (`crates/algo/src/matting.rs`, `segment/sky.rs`, `segment/focus.rs`) | Adobe: US 8,264,500 | Edge-aware smoothing of the mask itself: soft where the photo is soft, sharp at sharp edges, with no colour fit. Hair and fur come out less detailed; on iOS, Refine Hair and the object masks use Apple Vision's person matte instead |
| The Refine Edge Brush for hair and fur (`crates/algo/src/matting/brush.rs`) | Adobe: US 8,406,566 | Nothing: removed |
| Field Blur's pins, each with a position and blur amount (`crates/algo/src/gallery.rs`) | Adobe: US 9,019,310 | Variable Blur (Filter › Blur Effects): the blur amount comes from the selection or an alpha channel, as in GIMP |
| Path Blur's Taper (`crates/algo/src/params_ext.rs`) | Adobe: US 9,723,204 | Nothing: removed |
| Shadows/Highlights' separate shadow and highlight neighbourhoods (`crates/algo/src/tone/shadows_highlights.rs`) | Adobe: US 7,853,096 | One shared neighbourhood drives both, as in GIMP's Shadows-Highlights. One radius in place of two |
| Panorama's hard seams, with each image masking part of the next (`crates/algo/src/panorama.rs`, `crates/engine/src/photo_cmds.rs`) | Adobe: US 7,646,932 | Soft weights that fade with distance from each photo's edge. Moving objects can show ghosting |
| Combining two soft selections where both are soft at the same pixel (`crates/algo/src/selection.rs`) | Adobe: US 7,701,470 | Where both edges are soft, each is cut at 50% first, so overlapping feathered edges come out hard there |
| Surface Blur's sliding-histogram fast path for 8-bit images (`crates/algo/src/blur.rs`) | Adobe: US 7,920,741 | The existing non-histogram paths. 8-bit Surface Blur is slower: about 3 s at radius 10 and 10 s at radius 30 on 12 MP, up from about 1.4 s |
| Snapping a moved layer to other layers' edges and centres, with a guide drawn for each match | Adobe: US 10,331,319, US 10,782,861 | Snapping to the canvas's edges and centre only |
| Caching an AI model's results (e.g. Apple Vision's object masks) and reusing them for later edits instead of running the model again | Adobe: US 12,579,596 | Nothing is cached: Vision runs again for each hover, hold, tap and Select Subject. The highlight is slower to appear |

We also:
- **Left out HEVC:** the app doesn't bundle an HEVC (HEIC) decoder. Apple's decoder, licensed
  with iOS, opens HEIC files.
- **Left out noise in Blur Effects:** Photoshop adds grain to the blurred areas, scaled by how
  much each area is blurred, which Adobe's US 9,536,337 covers until 2035. Blur Effects have no
  noise option; add grain with Filter › Noise › Add Noise as a Live Filter instead.
- **Left out masks in Develop:** a list of masked adjustments kept inside the develop screen is
  covered by Adobe's US 10,481,774 until 2036. Develop has no masks; for a local change, use an
  adjustment layer with a mask (Select › Subject, or a gradient on the mask).
- **Left out radial symmetry:** painting symmetry mirrors strokes across one or two lines
  (vertical, horizontal, dual axis, diagonal). Radial or mandala copies made as a list of
  transforms are covered by Adobe's US 11,461,874 until 2040, so there are none.
- **Kept methods whose patents have expired:** dark channel dehaze (Microsoft US 8,340,461),
  GrabCut (Microsoft US 7,660,463) and Poisson editing (Microsoft US 6,856,705).
- **Renamed features:** we use our own names, not Adobe's trademarked ones. We name Adobe Photoshop
  only for its file format (Photoshop® (PSD)), which PhotoWagon opens and saves.

Adobe and Photoshop are either registered trademarks or trademarks of Adobe in the United States
and/or other countries. This project isn't affiliated with or endorsed by Adobe.

## License

MIT or Apache-2.0, at your option ([LICENSE-MIT](LICENSE-MIT), [LICENSE-APACHE](LICENSE-APACHE)).
It is built on [PhotoCraft](https://github.com/storytold/photocraft), whose code is also MIT or Apache-2.0, at your option ([LICENSE-MIT-PhotoCraft](LICENSE-MIT-PhotoCraft), [LICENSE-APACHE-PhotoCraft](LICENSE-APACHE-PhotoCraft)).
Third-party assets keep their own licences, listed in [ATTRIBUTION.md](ATTRIBUTION.md).

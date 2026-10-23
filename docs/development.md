# Development guide

## Prerequisites

Xcode, XcodeGen (`brew install xcodegen`), CMake and Ninja (`brew install cmake ninja`, for
libjxl), and rustup with the iOS targets (`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`).
If Homebrew's `rust` is also installed, put rustup's `cargo` first:
`export PATH=/opt/homebrew/opt/rustup/bin:$PATH`. The C++ libraries are submodules:

```sh
git submodule update --init
git -C submodules/libjxl submodule update --init --depth 1 third_party/highway third_party/brotli third_party/skcms
```

## Build and run

```sh
cargo xtask ios --sim        # the Rust engine, its Swift bindings and the acknowledgements
cd ios && xcodegen generate  # make PhotoWagon.xcodeproj
open PhotoWagon.xcodeproj    # build and run (iOS 17 or later)
```

`cargo xtask ios --device` builds for a phone, and `--release` for a release build. The app's unit
tests are the `PhotoWagonTests` target; the engine's are `cargo test` on the crates.

## Faster test loops

Most of a `cargo test` run is linking test binaries and running them one after another. While iterating:

```sh
cargo test -p <crate> --lib --tests        # skip examples and doctests
cargo test -p <crate> --test <file>        # one integration-test file
cargo nextest run --workspace              # parallel across binaries (cargo install cargo-nextest --locked)
cargo test --doc --workspace               # nextest does not run doctests
```

[cargo-nextest](https://nexte.st) runs each test in its own process. `.config/nextest.toml` puts the GPU tests (`photocraft-gpu`) in a group of at most 4 at a time, because each process opens its own wgpu device and the in-process `gpu_lock()` no longer serializes them. On a 32-thread Windows machine the full workspace went from 297 s (`cargo test`) to about 120 s (#2204). Ignored tests run with `cargo nextest run --run-ignored only`. CI runs it with `--profile ci` (fail-fast, a 10-minute hang timeout), plus `cargo test --doc` for the doctests (#6117); a full `cargo test` stays the final check before a PR.

## Fonts (craft-fonts)

Font assets shared by the Crafting Apps live in [storytold/craft-fonts](https://github.com/storytold/craft-fonts), never in this repo: don't commit font files here (Inter and JetBrains Mono in `assets/fonts/` are the only exceptions; new fonts go to craft-fonts). The rules are in `craftrules/standards/fonts.md` in a sibling `craftrules` checkout (see below); that repository is not public, so outside contributors can ask a maintainer for the rules that apply to their change.

craft-fonts is an **optional build input**, never a Cargo dependency:

```sh
git clone https://github.com/storytold/craft-fonts ../craft-fonts
CRAFT_FONTS_DIR="$PWD/../craft-fonts" cargo run --release -p photocraft
CRAFT_FONTS_DIR="$PWD/../craft-fonts" cargo test --workspace     # runs the Japanese font tests too
```

- Use an absolute path (`$PWD/...`): `build.rs` runs in `crates/text`, so a relative `CRAFT_FONTS_DIR` would resolve from there.
- `crates/text/build.rs` reads `$CRAFT_FONTS_DIR/fonts/manifest.txt` and embeds the fonts as `photocraft_text::CRAFT_FONTS` (`crates/text/src/craft_fonts.rs`). Unset, `CRAFT_FONTS` is empty and the build is unchanged. A bad path is a build warning, or an error with `CRAFT_FONTS_REQUIRED=1` (release builds set both).
- **Type tool:** the text engine registers them in `FontDb::new` (so also with no system fonts) and puts them first in the Japanese slot of the locale-ordered fallback list: BIZ UDPGothic for sans runs, Shippori Mincho / BIZ UDMincho for serif runs.
- Tests that need the fonts skip with a message when `CRAFT_FONTS` is empty. The iOS build doesn't set `CRAFT_FONTS_DIR`.

## Native format (.pcraft)

`crates/format` defines the lossless native bundle. It is either a ZIP of STORE entries or a directory with the same layout:

- `manifest.json`: the versioned document tree, with migrations in `format/src/migrate.rs`.
- `tiles/<blake3>.zst` and `blobs/<blake3>.zst`: zstd-compressed objects, content-addressed by the BLAKE3 hash of their uncompressed bytes.
- `thumb.png` and `composite/preview.png`: previews.

Keep one `PcraftWriter` per open document: re-saving then only compresses and writes tiles that changed. Directory bundles verify objects on first encounter in a folder; later saves reuse them while their file size and modification time are unchanged, and re-verify changed objects, repair missing or damaged objects, and garbage-collect unreferenced ones. `format::Autosaver` writes snapshots into a recovery directory on a background thread. `list_recovery` / `recover` / `discard_recovery` implement crash recovery, and `format::RecoveryStore` is the lifecycle an app uses: new documents autosave under per-launch keys (document ids restart every launch, so they never overwrite an older entry), and a recovered document adopts the entry it came from. That entry is replaced in place by the next autosave and removed only when the document is saved or closed, never just because it was recovered, so a second crash loses nothing.

`photocraft-io` routes `.pcraft` through this crate in `import`/`export`, detecting it by magic or by extension.

## Colour management

`crates/cms` is our own pure-Rust ICC engine (v2/v4 parsing, matrix/TRC and LUT profiles, all four
intents, black point compensation). It ships CC0 built-in profiles, including a synthetic
"PhotoCraft Coated CMYK", because Adobe's CMYK profiles are proprietary (see `crates/cms/README.md`).

- Documents carry an optional embedded ICC profile (`Document::icc_profile`); `edit.assignProfile`
  and `edit.convertToProfile` change it. Mode changes (`image.mode.*`) convert through cms.
- **Proof Colors** (⌘Y), **Proof Setup** and **Gamut Warning** (⇧⌘Y) bake a 3D LUT
  (`cms::Lut3d`) that the canvas shader applies; the document pixels never change.
- Convert colours with `photocraft_cms::transform::cached(src, dst, opts)`: transforms are cached
  process-wide and integer buffers use precomputed tables or a device link.

## Testing strategy

- **Unit and property tests** in every crate. proptest is used for tile COW, regions and codecs.
- **Format crates:**
  - synthetic generators (`psd::testgen`)
  - byte-exact round trips
  - malformed-input sweeps (truncate at every offset)
  - fuzz targets (`crates/*/fuzz`)
- **Real-file corpora** in `corpus/` (gitignored, fetched at pinned commits, sha256-verified): opt-in locally through the `corpus` cargo feature, always run in CI. See [Test corpora](#test-corpora).
- **Composite oracle:** a PSD's embedded merged image is compared with our compositor's output. The pass rate is tracked in the roadmap.
- **App:** unit tests in `ios/PhotoWagonTests` (a real `EditorModel` and engine, no UI) and end-to-end UI tests in `ios/PhotoWagonUITests`.

## Photoshop Actions (.atn)

`photocraft-psd` reads and writes Photoshop Actions files (`atn`, version 16: Photoshop 6 and
later); `photocraft-engine`'s `atn_cmds` maps their events onto commands (`actions.load`,
`actions.save`; the Actions panel menu's Load/Save Actions…). To see what a set holds (event ids, panel names, the parameter keys Photoshop
recorded) when adding an event to the table:

```sh
cargo run -p photocraft-psd --example atn_dump -- "Default Actions.atn"
```

Events outside the table load as `actions.photoshopStep` steps that keep the descriptor
verbatim (so Save Actions writes them back) and fail at playback with the step's Photoshop name.

## Remove Tool quality

`cargo run --release -p photocraft-engine --example remove_quality -- <dir> [out dir]` fills
holes (discs and thin lines over background) in five photos with `photocraft_algo::remove` and
prints, per hole, the PSNR against the original, `texture` (the fill's mean gradient over the
original's: below 1 it is smoother than what it replaces) and `seam` (the same on the band along the
hole's edge: above 1 the edge shows). With an out dir it writes original | hole | fill crops. The
photos are public domain, not committed; download them at 1920 px wide into `<dir>` as:

| File | Photo |
|---|---|
| `01.jpg` | [The Tetons and the Snake River](https://commons.wikimedia.org/wiki/File:Adams_The_Tetons_and_the_Snake_River.jpg), Ansel Adams, 1942 (U.S. National Archives) |
| `02.jpg` | [Ansel Adams, National Archives 79-AAB-01](https://commons.wikimedia.org/wiki/File:Ansel_Adams_-_National_Archives_79-AAB-01.jpg) (U.S. National Archives) |
| `03.jpg` | [Hiking at Crane Meadows National Wildlife Refuge](https://commons.wikimedia.org/wiki/File:Hiking_at_Crane_Meadows_National_Wildlife_Refuge_(49018614166).jpg) (USFWS) |
| `04.jpg` | [Meadow Anemone, Lake Andes National Wildlife Refuge](https://commons.wikimedia.org/wiki/File:Meadow_Anemone_Lake_Andes_National_Wildlife_Refuge_South_Dakota_(53923253226).jpg) (USFWS) |
| `06.jpg` | [Line5070, NOAA Photo Library](https://commons.wikimedia.org/wiki/File:Line5070_-_Flickr_-_NOAA_Photo_Library.jpg) (NOAA) |

`https://commons.wikimedia.org/wiki/Special:FilePath/<file name>?width=1600` serves each at the
size the cases were placed for (Commons rounds it to 1920). Timing on a 24 MP document through the
command: `cargo run --release -p photocraft-engine --example remove_bench`.

## Test corpora

Real files are our best oracles, but they are large binaries, so they never go into this
repository. They live in `corpus/` (gitignored) and are fetched at **pinned commits** and checked
against committed **sha256 manifests**. All pins are in one place:
[`xtask/src/corpus_pins.rs`](../xtask/src/corpus_pins.rs).

| Directory | What | Source | Manifest |
|---|---|---|---|
| `corpus/photoshop/` | 256 PSDs we authored with Photoshop: smart filters, layer-style effect shapes, the text engine, adjustments in every mode and depth | https://github.com/storytold/photocraft-corpus (ours, MIT OR Apache-2.0) | `xtask/photoshop-corpus.sha256` |
| `corpus/psd/` | 170 small psd-tools and ag-psd files, the mix most PSD tests use | psd-tools and ag-psd upstreams (MIT) | `xtask/psd-corpus.sha256` |
| `corpus/psd-tools/` | the complete psd-tools test set (309 files) | psd-tools upstream (MIT) | `xtask/psd-tools-corpus.sha256` |
| `corpus/heif/` | 9 small HEIC/HEIF files (checkerboards, RGB strips, a grid-tiled photo with EXIF/XMP, each with Apple's decode as `.ref.png`; a 10-bit RGBA file with its source PNG), for the `heif` feature | heic-rs (MIT OR Apache-2.0) and pillow-heif (BSD-3-Clause) upstreams | `xtask/heif-corpus.sha256` |
| `corpus/exr/` | the 5 deep OpenEXR test images (scanline deep data with half colour and u32 ID channels; 2.3 MB), checked against the ID manifests of their upstream sidecars | OpenEXR upstream at v3.5.2 (BSD-3-Clause) | `xtask/exr-corpus.sha256` |
| `corpus/affinity/` | 21 public Affinity documents and the 18 Affinity 3 samples for #1606, with exported PNG references | vector-art and affinity-samples (CC0), AFDesignLoad, Jac21/Branding and AssetStoreTemplate (MIT) upstreams | `xtask/affinity-corpus.sha256` |
| `corpus/pngsuite/` | PngSuite | schaik.com release archive (public domain) | (fixed archive) |

```sh
cargo xtask corpus                 # where each corpus lives, its pin, present or missing
cargo xtask corpus --all           # fetch everything missing or stale (cold: about 15 s; verified copies are left alone)
cargo xtask test-corpus            # fetch, then cargo test --release --features corpus (+ heif on codecs, io) on psd, codecs, io, engine
cargo xtask test-corpus -p io      # narrow to one crate (repeat -p for more)
cargo xtask test-corpus --changed  # only if psd, io, codecs, compose, gpu, text, format or affinity changed vs origin/main
cargo xtask test-corpus -- --nocapture   # pass arguments to the test binaries (per-file tables)
scripts/fetch-corpus.sh            # the same as cargo xtask corpus --all
```

**Opt-in locally, strict when opted in, always in CI.**

- The corpus tests sit behind the `corpus` cargo feature of `photocraft-psd`, `photocraft-codecs`,
  `photocraft-io` and `photocraft-engine`, so plain `cargo test` neither compiles nor needs them.
  The HEIF ones also need the `heif` feature of `photocraft-codecs`/`photocraft-io` (test-corpus
  turns it on).
- With the feature on, a missing corpus is a failure ("run `cargo xtask corpus --all`"), never a
  silent skip, and every floor is enforced.
- If you touch psd, io, codecs, compose, gpu, text or format, run `cargo xtask test-corpus` before
  you finish.
- The CI `corpus` job runs `cargo xtask corpus --all` and then `cargo xtask test-corpus` on every PR
  and on main. `corpus/` is cached with `actions/cache`, keyed on the hash of `corpus_pins.rs` and
  the manifests. A download happens only when a pin changes; otherwise the cache restores in seconds
  and is re-verified (sha256) before the tests run. Fork PRs read the base branch's cache.

**Our own corpus: [photocraft-corpus](https://github.com/storytold/photocraft-corpus).**

- **Authoring clone:** a normal git clone, `git clone git@github.com:storytold/photocraft-corpus.git`,
  placed next to this checkout (`../photocraft-corpus`). Its generators write there, and you commit
  and push there.
- **Consuming copy:** `corpus/photoshop/` here. It is a plain directory: the pinned snapshot
  (downloaded as the codeload tarball of the pinned commit, then verified).
- **Local mode:** `cargo xtask corpus --photoshop --local` copies `photoshop/` from
  `../photocraft-corpus` (or `PHOTOCRAFT_CORPUS_REPO=<path>`) instead of downloading. It warns when
  the clone's HEAD isn't the pin or its files differ from the manifest. Use it to test regenerated
  files before pushing: `cargo xtask test-corpus --local` copies them and runs every corpus test.
- **Bumping the pin:** commit and push in photocraft-corpus, then in a PR here set
  `PHOTOCRAFT_CORPUS_COMMIT` in `corpus_pins.rs`, run
  `cargo xtask corpus --photoshop --update-manifest`, commit the manifest diff, run
  `cargo xtask test-corpus`, and raise floors that improved.
- **Not a submodule or a subtree:** a subtree would put the binaries back into this repository's
  history, and submodules cause init and detached-HEAD friction for every contributor. A pin plus a
  manifest gives the same reproducibility.
- The third-party sets (psd-tools, ag-psd, PngSuite) are fetched from their upstreams the same way,
  and are never copied into photocraft-corpus.

## Rendering fidelity (PSD oracle)

`cargo xtask test-corpus -p io -- --nocapture` compares our composite of every corpus PSD with
Photoshop's own merged image (PASS ≤ 2/255) and checks that export → re-import renders the same,
per source with its own floors: `corpus/psd`, the psd-tools set (also a truncation/corruption sweep
over every file that must never panic) and our Photoshop set `corpus/photoshop` (per-feature-group
totals: `smart-filters`, `effects`, `text`, `adjustments/<mode><bits>`). Smart objects and type
layers composite Photoshop's cached pixels there; `cargo xtask test-corpus -p engine -- --nocapture`
(`crates/engine/tests/photoshop_oracles.rs`) re-renders them with our smart-filter stack and text
engine and is the failure map for both. A panic is reported as `CRASH` and fails the run. Files without a real merged image (Maximize Compatibility off)
are judged against their embedded thumbnail instead (`PASS (thumbnail)`, a strict low-resolution
check); a file only SKIPs when it has no oracle at all. Raise the floors in `crates/io/tests/corpus.rs` when they
improve; never lower them. Synthetic reproductions of corpus findings live in
`crates/io/tests/corpus_regressions.rs` (corpus files are never committed). To dig into one file:

```sh
cargo run --release -p photocraft-io --example oracle_diff -- corpus/psd/<file>.psd 0 png /tmp/diff.png
```

writes ours | Photoshop | a diff heatmap side by side; `col`, `row`, `worst [n]`, `grid x0 y0 x1 y1 [ch]`,
`layerpx x y` and `DUMP_FX=1` print samples, the worst pixels, value grids, per-layer pixels and raw
effect descriptors. Findings so far: fill-layer gradients are framed by the layer's mask bounds;
Photoshop's gradient Smoothness is a Catmull-Rom blend and "Perceptual" interpolation is Oklab
(baked into dense stops on import, `crates/io/src/gradient_bake.rs`); a shape layer's vector
stroke is drawn above its clipped layers; linked effect patterns tile from the layer's `fxrp`
reference point; stroke distances follow a 5 × 5 chamfer metric (1, √2, √5) seeded at sub-pixel
edge offsets; interior effects keep the layer's alpha; outside strokes blend onto the backdrop with
their own modes, an upper stroke covering lower ones.


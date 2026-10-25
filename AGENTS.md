# AGENTS.md: guide for AI agents and contributors

**PhotoWagon** is a native iOS photo editor (SwiftUI, iPhone and iPad) built on the PhotoCraft
Rust engine. **The goal is an app a Photoshop user could switch to without help, not a copy of
Photoshop.** Menus, tools and panels sit where a Photoshop user would look for them. Their names
are similar and meaningful, so a Photoshop user recognises them, but they aren't Adobe's (Fill from
Surroundings for Content-Aware Fill, Develop for Camera Raw, Embedded Layers for Smart Objects).
Keep Photoshop's exact word only when there's no other way to say it (Layers, Brush, Crop), and
never use one of Adobe's trademarks as our name: `docs/trademark-guardrails.md` lists them, our
replacements, and how to name Photoshop when we mean its file format. Lay things out for touch.
A button that shows only an icon must say its name when touched and held: use `namedButton(_:model:_:)`
(the name shows in the hint bubble; a full-screen view shows `HintBubble` itself).
Never use a method covered by a patent still in force: the README's Patents section lists what was
removed and why.
Our plan and roadmap are local, not checked in: read `plan/ios-port.md` and `plan/ios-roadmap.md` first if you have them.

**Testing: design for unit tests.** Put logic where a unit test can reach it: in `EditorModel`,
a small type or a `static func`, not inside a SwiftUI view or a `UIView`'s gesture handler. Every
change to app logic comes with unit tests in `ios/PhotoWagonTests` (hosted in the app, a real
`EditorModel()` and engine, no UI; they run in seconds). Aim for more than 50% line coverage of
the app's own Swift (not the generated `Core/photocraft_ffi.swift`). Test what matters, not
everything: real branches, the cases a user hits, the edges that broke before; no tests of
trivial getters or layout. The end-to-end UI tests (`ios/PhotoWagonUITests`) check what only the
real UI can (taps, sheets, system pickers, the walkthroughs as a whole): run the unit tests on
every change, the UI tests for the classes you touched, and the full UI run rarely, two
simulators at a time.

The engine (`crates/`) is a fork of PhotoCraft and keeps that name in code (`photocraft-*`
crates, ids). PhotoCraft's own desktop, web and CLI apps were removed; only the engine is left.
Most of the rest of this file is upstream PhotoCraft's guidance for the engine: follow it where it
helps, but this goal wins where they disagree (for example, upstream aimed at 1:1 Photoshop
parity; we don't).

Upstream notes: the engine is written in **Rust only**. Standards shared across the crafting apps
live in `../craftrules`, and shared Rust components live in
[storytold/craft-libs](https://github.com/storytold/craft-libs), pinned by git revision.

## 1. Orientation (5 minutes)

| Read | Why |
|---|---|
| `docs/architecture.md` | Crate map, dependency layers, the engine/UI seam, document model |
| `docs/development.md` | Build, test, run, drive the app programmatically, debug tricks |
| `docs/contributing.md` | Rules: clean-room, tests, layering, style, commits; the "add a command" checklist |
| `ROADMAP.md` | One-page summary: stage, the two parity numbers, every dimension, languages, what's next |
| `docs/target-app-parity.md` | The authoritative parity assessment against Photoshop 2026: numbers, weights, evidence, hours |
| `docs/gaps.md` | Every known shortfall, ranked: the work list to pick from |
| `docs/roadmap.md` | Milestones, **current focus**, what's next with estimates |
| `docs/brush-parity.md`, `docs/file-format-parity.md` | Per-dimension parity checklists |
| `crates/<name>/README.md` (where present) | Public API of that crate |
| [photocraft-corpus](https://github.com/storytold/photocraft-corpus) + `docs/development.md` › Test corpora | Real-file test oracles (our Photoshop-authored PSDs); with psd-tools, ag-psd and PngSuite fetched into `corpus/` by `cargo xtask corpus --all` at the pins in `xtask/src/corpus_pins.rs` |

## 2. Workspace map

```text
crates/
  geom cms color raster      L0 foundation (geometry, ICC colour management, pixel formats + blend math, COW tiles)
  psd codecs                 L0 standalone format crates (no workspace deps; publishable)
  doc                        L1 document model (layers, masks, adjustments, effects, smart objects: pure data)
  ops paint algo text vector L2 history, brush engine, imaging algorithms, type engine, paths/shapes
  compose gpu format         L3 CPU compositor (the oracle), wgpu compositor, .pcraft native format
  io plugins                 L4 document <-> PSD / flat formats; sandboxed WebAssembly plug-ins
  engine                     L5 Session + command registry (every action is a command)
  ffi                        L6 the Swift bridge (UniFFI) PhotoWagon calls
ios/                         PhotoWagon: SwiftUI app (PhotoWagon/), UI tests (PhotoWagonUITests/), XcodeGen project.yml
xtask/                       cargo xtask layers | ci | stats | corpus | test-corpus | version | ios
```

**Layering is enforced** by `cargo xtask layers`. A crate may depend only on lower layers. `psd`, `codecs` and `cms` depend on nothing in the workspace. A new crate must be registered in `xtask/src/layers.rs`.

## 3. Golden rules

### Never crash (outranks feature work)

People trust PhotoCraft with their work, and a crash loses it. A malformed file, a bad command or MCP param, a corrupt settings file, an odd keystroke or a full disk must produce an error the user or agent can act on, never a panic. Don't ship a feature by adding a panic path; fix a crash before building on top of it. The shared standard is `../craftrules/standards/never-crash.md`.

- **Non-test code never panics.** No `unwrap()`, `expect()`, `panic!`, `unreachable!`, `todo!` or `unimplemented!`. Return the crate's error type and propagate with `?`; use `ok_or(..)?`, `let .. else { return Err(..) }`, `if let`, or `unwrap_or*` where a fallback is truly correct (never one that silently corrupts a document). Unfinished features return an "unsupported" error. The only exception is a provably infallible literal: `#[allow(clippy::expect_used)]` plus `.expect("why it can't fail")`.
- **No `unsafe`.** The workspace sets `unsafe_code = "forbid"`. The exception is the Swift bridge (`crates/ffi`): the C calls to LibRaw and libjxl, and the one `CAMetalLayer` pointer in `canvas.rs`. It sets `unsafe_code = "deny"` and allows it item by item with `#[allow(unsafe_code)]`; give each block a `SAFETY:` comment. Don't add `unsafe` anywhere else.
- **Input-derived numbers are hostile.** Use `get()` rather than `[i]`/`[a..b]` for indices from files, params, selections or arithmetic on them; slice strings only at char boundaries; use `checked_*`/`saturating_*` for lengths, offsets and counts; guard division by zero and NaN/inf casts; cap allocations sized by input.
- **Bound recursion** with depth limits or seen-sets (documents can be deep or cyclic).
- **Don't cascade.** Handle lock poisoning (`lock().unwrap_or_else(PoisonError::into_inner)`) and treat thread joins as `Result`s.
- **Last-resort guard.** The app shell must catch an escaped panic around command dispatch and file import/export, reports it as an error and keeps the document. It's a safety net, not a licence to panic. Keep `panic = "unwind"`.
- **Prove it.** Every crash fix comes with a small synthetic regression test that panicked before the fix.
- **Enforced by clippy.** `clippy.toml` allows `unwrap`/`expect`/`panic`/indexing in tests only. Clean crates carry `#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]`; new crates start with it.

1. **Everything is a command.** New user-visible behaviour = a command in the engine (`crates/engine/src/*_cmds.rs`, registered in `commands.rs`) with id, label, menu path, shortcut, params doc, `enabled` and `run`, plus tests. The app dispatches commands by id through the Swift bridge. Only pure view state (zoom, panels) belongs to the app.
2. **No format or colour assumptions.** Bit depth (8/16/32f) and colour model (RGB/Gray/CMYK/Lab…) are runtime data. Never introduce a `u8`-only pixel path in public APIs. Never assume sRGB: colour conversions go through `photocraft-cms` (`Transform`, `transform::cached`). Test at several depths.
3. **Clean-room.** We studied Photoshop and other proprietary editors for *behaviour and look only*. Never copy their code, shaders, profiles or assets. Implement from public specs (Adobe PSD spec, ICC, ISO 32000 blend modes, papers) and observation. Before implementing a method from a paper, check it isn't patented and in force (Adobe's especially); if it is, find another method or leave the feature out, and record it in the README's Patents section. Read `docs/patent-guardrails.md` before adding or changing a feature in an area it lists. Read `docs/trademark-guardrails.md` before naming a feature, tool, menu item, message or icon. Code under a copyleft ("viral") licence such as the GPL, LGPL or AGPL may be read to learn a method but never copied. Third-party assets must be permissively licensed, keep their license file next to them, and get a row in `ATTRIBUTION.md` (path, title, author, source, license) in the same change; so do original assets. **Never commit font files:** fonts live in [storytold/craft-fonts](https://github.com/storytold/craft-fonts) (rules: `../craftrules/standards/fonts.md`). PhotoCraft uses it through the optional build input `CRAFT_FONTS_DIR=<craft-fonts checkout>` (read by `crates/text/build.rs`, exposed as `photocraft_text::CRAFT_FONTS`; empty without it, and everything must still work). Build with it: `CRAFT_FONTS_DIR="$PWD/../craft-fonts" cargo build`; details in `docs/development.md` › Fonts.
4. **Tests are the gate.** Every change comes with tests. Format crates use round-trip, synthetic-generator, oracle and fuzz tests. Keep the PSD corpus results from regressing.
5. **The UI is thin.** The app's logic goes through the engine's commands and `EditorModel`, where unit tests reach it.
6. **Verify UI changes visually** in the simulator: take a screenshot and look at it. Demo images must be public-domain art, never personal photos. When fetching assets, never put a person's name, email or other personal details in requests (User-Agent, headers, URLs); use a generic `Photocraft-dev` User-Agent.
7. **Performance is a feature.** Benchmark heavy operations on a 24–36 MP image in release. Work per tile in parallel (rayon), skip empty tiles, never scan a full surface per frame (cache per revision), and record before/after timings in the dev log.
8. **Never panic on input** (see *Never crash* above). A command's `run` closure and anything it calls must return `Err`, never panic, for *any* params or document state: validate params, check bounds before indexing or dividing, and reject absurd sizes before allocating. The `panic_hunt` integration test fuzzes every command with adversarial params and must stay green.

## 4. Picking work

Priorities for PhotoWagon: what `plan/ios-roadmap.md` lists, and the walkthrough steps the app can't do yet. The upstream list below measures the engine and desktop app against Photoshop; use it to find engine work, not as the app's goal.

0. **Read `ROADMAP.md`, then `docs/gaps.md`.** `docs/target-app-parity.md` says, dimension by
   dimension, where PhotoCraft was lacking when the desktop app was removed; `docs/gaps.md` ranks
   the work. When your work closes a gap, update its entry with the date.
1. `docs/roadmap.md` → **Current focus**.
2. `log/devlog.md` → the "Still open" bullets of recent entries.

## 5. Before you finish a task

```sh
cargo test -p <crates you touched>
cargo clippy -p <crates> --all-targets -- -D warnings
cargo xtask layers
cargo test -p photocraft-engine --test panic_hunt -- --ignored   # if you added/changed commands: no panic on adversarial input (Rule 8)
cargo xtask test-corpus     # if you touched psd, io, codecs, compose, gpu, text or format (or: --changed decides)
```

While iterating, run less and keep the full commands above as the final gate: `cargo test -p <crate> --lib --tests` skips the examples and doctests plain `cargo test` builds every time, and `cargo test -p <crate> --test <file>` runs one integration-test file. `cargo nextest run` runs tests in parallel across binaries; see `docs/development.md` › Faster test loops.

**Test corpora.** Real-file corpora live in `corpus/` (gitignored, never committed), fetched at pinned commits and sha256-verified by `cargo xtask corpus --all`: our Photoshop-authored oracles from https://github.com/storytold/photocraft-corpus plus psd-tools, ag-psd and PngSuite from their upstreams. Pins: `xtask/src/corpus_pins.rs`. The corpus tests are opt-in (cargo feature `corpus`): plain `cargo test` skips them, and with the feature on a missing corpus fails ("run `cargo xtask corpus --all`"). `cargo xtask test-corpus` fetches and runs them all. CI always runs them (the `corpus` job, cached by pin). Never commit corpus files; new oracles go to photocraft-corpus (its `AGENTS.md`), then a pin bump here. Details: `docs/development.md` › Test corpora.

Commands must **never panic** on bad input (Rule 8): every `run` closure and the code it calls returns `Err`, not a panic, for any params or document state. New commands come with a graceful-failure test (empty/out-of-range/wrong-type params → `Err`, not a crash).

Then append a terse entry to `log/devlog.md` (what landed, numbers, what's still open). Sessions can end abruptly (crashes, context limits), so the dev log plus a green tree is how the next agent picks up. Keep the tree building at every step.

## 6. Parallel agents

- Use your own target dir (`CARGO_TARGET_DIR=target/agent-<name>`) to avoid the Cargo build lock, and edit only the files you own. Shared files (`engine/src/lib.rs`, the `v.extend(...)` list in `engine/src/commands.rs`) get small, surgical edits; re-read before editing.
- Put new commands in a **new module** (`engine/src/<area>_cmds.rs` with a `specs()` function) rather than growing a shared file.
- If someone else's in-progress edit breaks the build, wait and retry; don't fix their files.
- Keep every `Cargo.toml` valid at all times: the `crates/*` glob means one broken manifest breaks everyone's build. **Create or rewrite manifests atomically**: write to a temp file outside `crates/`, then `mv` it into place.
- Disk space: each target dir is about 10 GB. Delete `target/agent-*` dirs of finished agents.

## 7. Where things are tracked


- `docs/roadmap.md`: milestones M0–M12, status and the current focus.
- `ROADMAP.md`, `docs/target-app-parity.md`, `docs/gaps.md` and the `docs/*-parity.md` checklists: where we stand against Photoshop.
- `.github/workflows/ios-app-store.yml`: a `v1.2.3` tag builds the app and puts an unsigned .ipa on the GitHub release (and a signed App Store .ipa in the run's artifacts when the signing secrets are set).
- `plan/` (local, gitignored): research, parity plan, execution plan, estimates.
- `log/` (local, gitignored): the dev log.

## 8. Keeping the native format complete

`photocraft-format` deliberately fails to compile when a `photocraft-doc` struct gains a field, so
nothing is silently dropped from `.pcraft` saves. When you add a doc field, add it to
`crates/format/src/manifest.rs` and `convert.rs` with `#[serde(default)]` so older files still load.
If the field has a PSD equivalent, map it in `crates/io` too, and keep unknown PSD blocks verbatim.

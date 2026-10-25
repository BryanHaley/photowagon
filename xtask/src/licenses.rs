//! The iOS app's acknowledgements: every library built into the app (the C and C++ libraries, the
//! bundled fonts and data, and every Rust crate `photocraft-ffi` links) with its licence texts, as
//! one JSON file the app shows under Help › Acknowledgements.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::Value;

use crate::cargo;

const MPL: &str = include_str!("../licenses/MPL-2.0.txt");
const BSD3: &str = include_str!("../licenses/BSD-3-Clause.txt");
const REPO: &str = "https://github.com/BryanHaley/photowagon";

/// A licence text: a file, or the comment in a source file that holds the given line.
enum Text {
    File(&'static str),
    Comment(&'static str, &'static str),
}

struct Library {
    name: &'static str,
    license: &'static str,
    note: &'static str,
    texts: &'static [Text],
}

const LIBRARIES: &[Library] = &[
    Library {
        name: "LibRaw",
        license: "CDDL 1.0",
        note: "Reads camera raws. Copyright (C) 2008-2025 LibRaw LLC. LibRaw is offered under the LGPL 2.1 or the CDDL 1.0; \
               PhotoWagon uses it under the CDDL 1.0. Its source code is available under the CDDL in the submodules/LibRaw \
               folder of PhotoWagon's source code, {repo}. It includes code from dcraw (Copyright 1997-2018 Dave Coffin), DCB \
               demosaic and FBDD denoise (BSD-3-Clause, Jacek Gozdz), the X3F library (BSD-3-Clause, Roland Karlsson) and \
               the DNG SDK 1.4 (MIT).",
        texts: &[
            Text::File("submodules/LibRaw/COPYRIGHT"),
            Text::File("submodules/LibRaw/LICENSE.CDDL"),
            Text::Comment("submodules/LibRaw/src/demosaic/dcb_demosaic.cpp", "Redistribution and use"),
            Text::Comment("submodules/LibRaw/internal/x3f_tools.h", "Redistribution and use"),
        ],
    },
    Library {
        name: "libjxl",
        license: "BSD-3-Clause",
        note: "Reads and writes JPEG XL. Copyright (c) the JPEG XL Project Authors, with Google's royalty-free patent grant \
               for this implementation of JPEG XL.",
        texts: &[Text::File("submodules/libjxl/LICENSE"), Text::File("submodules/libjxl/PATENTS")],
    },
    Library {
        name: "Highway",
        license: "Apache-2.0 or BSD-3-Clause",
        note: "SIMD code inside libjxl.",
        texts: &[Text::File("submodules/libjxl/third_party/highway/LICENSE"), Text::File("submodules/libjxl/third_party/highway/LICENSE-BSD3")],
    },
    Library { name: "Brotli", license: "MIT", note: "Compression inside libjxl.", texts: &[Text::File("submodules/libjxl/third_party/brotli/LICENSE")] },
    Library {
        name: "skcms",
        license: "BSD-3-Clause",
        note: "Color management inside libjxl.",
        texts: &[Text::File("submodules/libjxl/third_party/skcms/LICENSE")],
    },
    Library {
        name: "X.Org color names",
        license: "MIT",
        note: "The X11 color names XPM images use. Copyright 1985, 1989, 1998 The Open Group; Copyright (c) 1994, 2008, Oracle and/or its affiliates.",
        texts: &[Text::File("crates/codecs/src/codecs/xpm/LICENSE-x11-rgb.txt")],
    },
    Library {
        name: "MI-GAN",
        license: "MIT",
        note: "AI Remove's model, downloaded the first time you use AI Remove. Copyright (c) 2024 Picsart AI Research (PAIR). \
               Source code: https://github.com/Picsart-AI-Research/MI-GAN",
        texts: &[Text::File("xtask/licenses/MI-GAN.txt")],
    },
    Library {
        name: "libfacedetection",
        license: "BSD-3-Clause",
        note: "Face detection weights and network. Copyright (c) 2015-2019, Shiqi Yu.",
        texts: &[Text::File("crates/algo/data/LICENSE-libfacedetection.txt")],
    },
];

const FONTS_AND_DATA: &[Library] = &[
    Library { name: "Inter", license: "SIL Open Font License 1.1", note: "Interface and text font.", texts: &[Text::File("assets/fonts/OFL-Inter.txt")] },
    Library {
        name: "JetBrains Mono",
        license: "SIL Open Font License 1.1",
        note: "Monospaced font.",
        texts: &[Text::File("assets/fonts/OFL-JetBrainsMono.txt")],
    },
    Library { name: "SCOWL", license: "SCOWL licence", note: "English word list for spell checking.", texts: &[Text::File("assets/dict/LICENSE-SCOWL.txt")] },
];

#[derive(Serialize)]
struct Out {
    groups: Vec<Group>,
    texts: Vec<String>,
}

#[derive(Serialize)]
struct Group {
    title: String,
    entries: Vec<Entry>,
}

#[derive(Serialize)]
struct Entry {
    name: String,
    license: String,
    note: String,
    /// Indexes into `Out::texts`: texts several entries share are stored once.
    texts: Vec<usize>,
}

#[derive(Default)]
struct Texts {
    list: Vec<String>,
    index: HashMap<String, usize>,
}

impl Texts {
    fn add(&mut self, text: &str) -> usize {
        let text = text.trim().to_string();
        let key = text.split_whitespace().collect::<Vec<_>>().join(" ");
        *self.index.entry(key).or_insert_with(|| {
            self.list.push(text);
            self.list.len() - 1
        })
    }
}

pub fn write(root: &Path, target: &str, out: &Path) -> Result<(), String> {
    let mut texts = Texts::default();
    let apache = texts.add(&read(&root.join("LICENSE-APACHE"))?);
    let own = Entry {
        name: "PhotoWagon".into(),
        license: "MIT or Apache-2.0".into(),
        note: format!("Copyright (c) 2026 Bryan Haley. Source code: {REPO}"),
        texts: vec![texts.add(&read(&root.join("LICENSE-MIT"))?), apache],
    };
    let upstream = Entry {
        name: "PhotoCraft".into(),
        license: "MIT or Apache-2.0".into(),
        note: "PhotoWagon is built on PhotoCraft. Copyright (c) 2026 ArtCraft Team and the PhotoCraft contributors. \
               Source code: https://github.com/storytold/photocraft"
            .into(),
        texts: vec![texts.add(&read(&root.join("LICENSE-MIT-PhotoCraft"))?), texts.add(&read(&root.join("LICENSE-APACHE-PhotoCraft"))?)],
    };
    let mut groups = vec![Group { title: "PhotoWagon".into(), entries: vec![own, upstream] }];
    for (title, libs) in [("Libraries", LIBRARIES), ("Fonts and data", FONTS_AND_DATA)] {
        let mut entries = Vec::new();
        for lib in libs {
            let mut ids = Vec::new();
            for t in lib.texts {
                let body = match t {
                    Text::File(f) => read(&root.join(f))?,
                    Text::Comment(f, marker) => comment_containing(&read(&root.join(f))?, marker).ok_or_else(|| format!("{f}: no licence comment"))?,
                };
                ids.push(texts.add(&body));
            }
            entries.push(Entry { name: lib.name.into(), license: lib.license.into(), note: lib.note.replace("{repo}", REPO), texts: ids });
        }
        groups.push(Group { title: title.into(), entries });
    }
    groups.push(Group { title: "Rust standard library".into(), entries: rust_std(&mut texts)? });
    groups.push(Group { title: "Rust crates".into(), entries: crates(root, target, &mut texts)? });

    let json = serde_json::to_string(&Out { groups, texts: texts.list }).map_err(|e| format!("acknowledgements: {e}"))?;
    if let Some(dir) = out.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    std::fs::write(out, json).map_err(|e| format!("{}: {e}", out.display()))
}

fn crates(root: &Path, target: &str, texts: &mut Texts) -> Result<Vec<Entry>, String> {
    let out = cargo().args(["metadata", "--format-version", "1", "--filter-platform", target]).output().map_err(|e| format!("cargo metadata: {e}"))?;
    if !out.status.success() {
        return Err(format!("cargo metadata failed:\n{}", String::from_utf8_lossy(&out.stderr)));
    }
    let meta: Value = serde_json::from_slice(&out.stdout).map_err(|e| format!("cargo metadata: bad JSON: {e}"))?;
    let packages: HashMap<&str, &Value> = list(&meta["packages"]).iter().filter_map(|p| Some((p["id"].as_str()?, p))).collect();
    let deps: HashMap<&str, Vec<&str>> = list(&meta["resolve"]["nodes"])
        .iter()
        .filter_map(|n| {
            let normal =
                list(&n["deps"]).iter().filter(|d| list(&d["dep_kinds"]).iter().any(|k| k["kind"].is_null())).filter_map(|d| d["pkg"].as_str()).collect();
            Some((n["id"].as_str()?, normal))
        })
        .collect();
    let workspace: HashSet<&str> = list(&meta["workspace_members"]).iter().filter_map(Value::as_str).collect();
    let start =
        workspace.iter().copied().find(|id| packages.get(id).is_some_and(|p| p["name"] == "photocraft-ffi")).ok_or("photocraft-ffi is not in the workspace")?;

    let mut seen = HashSet::new();
    let mut stack = vec![start];
    while let Some(id) = stack.pop() {
        if seen.insert(id) {
            stack.extend(deps.get(id).into_iter().flatten());
        }
    }
    let mut sorted = BTreeMap::new();
    for id in seen.iter().filter(|id| !workspace.contains(*id)) {
        if let Some(p) = packages.get(id) {
            sorted.insert((p["name"].as_str().unwrap_or(""), p["version"].as_str().unwrap_or("")), *p);
        }
    }

    let mit = read(&root.join("LICENSE-MIT"))?;
    let mit_body = mit.find("Permission is hereby granted").map(|at| mit[at..].to_string()).ok_or("LICENSE-MIT: no permission notice")?;
    let apache = read(&root.join("LICENSE-APACHE"))?;
    let mut entries = Vec::new();
    for ((name, version), p) in sorted {
        let license = p["license"].as_str().unwrap_or("see its licence").replace('/', " OR ");
        let note = match p["source"].as_str().filter(|s| !s.starts_with("registry+")) {
            Some(source) => format!("Source code: {}", source.trim_start_matches("git+")),
            None => format!("Source code: https://crates.io/crates/{name}/{version}"),
        };
        let files = license_files(p);
        let mut ids = Vec::new();
        if files.is_empty() {
            let authors: Vec<String> = list(&p["authors"]).iter().filter_map(Value::as_str).map(without_email).collect();
            let holder = if authors.is_empty() { format!("the {name} authors") } else { authors.join(", ") };
            let body = if license.contains("MIT") {
                format!("Copyright (c) {holder}\n\n{mit_body}")
            } else if license.contains("Apache-2.0") {
                apache.clone()
            } else if license.contains("BSD-3-Clause") {
                format!("Copyright (c) {holder}\n\n{BSD3}")
            } else if license.contains("MPL-2.0") {
                MPL.to_string()
            } else {
                return Err(format!("{name} {version}: no licence file, and no template for {license}"));
            };
            ids.push(texts.add(&body));
        }
        for f in files {
            ids.push(texts.add(&read(&f)?));
        }
        entries.push(Entry { name: format!("{name} {version}"), license, note, texts: ids });
    }
    Ok(entries)
}

/// The standard library compiled into the app, from the notice the Rust toolchain ships
/// (share/doc/rust/COPYRIGHT-library.html): Rust itself, then each crate it is built from.
fn rust_std(texts: &mut Texts) -> Result<Vec<Entry>, String> {
    let rustc = std::env::var("RUSTC").unwrap_or_else(|_| "rustc".into());
    let out = std::process::Command::new(&rustc).args(["--print", "sysroot"]).output().map_err(|e| format!("{rustc} --print sysroot: {e}"))?;
    let sysroot = PathBuf::from(String::from_utf8_lossy(&out.stdout).trim());
    let docs = sysroot.join("share/doc/rust");
    let html = read(&docs.join("COPYRIGHT-library.html"))?;
    let mut entries = vec![Entry {
        name: "Rust standard library".into(),
        license: "MIT or Apache-2.0".into(),
        note: "Copyright the Rust Project Developers (https://thanks.rust-lang.org). Its Unicode tables are Copyright 1991-2024 \
               Unicode, Inc., under the Unicode-3.0 licence. Source code: https://github.com/rust-lang/rust"
            .into(),
        texts: ["MIT.txt", "Apache-2.0.txt", "Unicode-3.0.txt"]
            .iter()
            .map(|f| read(&docs.join("licenses").join(f)).map(|t| texts.add(&t)))
            .collect::<Result<_, _>>()?,
    }];
    for block in html.split("<h3>📦 ").skip(1) {
        let Some((name, rest)) = block.split_once("</h3>") else { continue };
        let field = |label: &str| rest.split_once(&format!("<b>{label}:</b> ")).and_then(|(_, r)| r.split_once("</p>")).map(|(v, _)| unescape(v));
        let url = field("URL").map(|u| u.split_once('>').map_or(u.clone(), |(_, a)| a.trim_end_matches("</a>").to_string()));
        let ids = rest.split("<pre>").skip(1).filter_map(|p| p.split_once("</pre>")).map(|(t, _)| texts.add(&unescape(t))).collect::<Vec<_>>();
        // Without a notice: crates only other platforms build (SGX, WASI, VEX).
        if ids.is_empty() {
            continue;
        }
        entries.push(Entry {
            name: name.trim().to_string(),
            license: field("License").unwrap_or_default(),
            note: url.map(|u| format!("Part of the Rust standard library. Source code: {u}")).unwrap_or_default(),
            texts: ids,
        });
    }
    if entries.len() < 2 {
        return Err(format!("{}: no crates found", docs.join("COPYRIGHT-library.html").display()));
    }
    Ok(entries)
}

fn unescape(s: &str) -> String {
    s.replace("&#34;", "\"")
        .replace("&#39;", "'")
        .replace("&#60;", "<")
        .replace("&#62;", ">")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&amp;", "&")
}

fn license_files(p: &Value) -> Vec<PathBuf> {
    let Some(dir) = p["manifest_path"].as_str().and_then(|m| Path::new(m).parent()) else { return Vec::new() };
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|f| f.is_file())
        .filter(|f| {
            let n = f.file_name().map(|n| n.to_string_lossy().to_uppercase()).unwrap_or_default();
            ["LICEN", "COPYING", "COPYRIGHT", "NOTICE", "UNLICENSE"].iter().any(|s| n.starts_with(s))
        })
        .collect();
    if let Some(f) = p["license_file"].as_str().map(|f| dir.join(f)).filter(|f| f.is_file() && !files.contains(f)) {
        files.push(f);
    }
    files.sort();
    files
}

/// The text of the `/* … */` comment holding `marker`, without the comment marks.
fn comment_containing(src: &str, marker: &str) -> Option<String> {
    let at = src.find(marker)?;
    let start = src[..at].rfind("/*")? + 2;
    let end = at + src[at..].find("*/")?;
    let lines: Vec<&str> = src[start..end]
        .lines()
        .map(|l| {
            let l = l.trim();
            l.strip_prefix('*').map_or(l, str::trim)
        })
        .collect();
    Some(lines.join("\n"))
}

fn without_email(author: &str) -> String {
    author.split('<').next().unwrap_or(author).trim().to_string()
}

fn list(v: &Value) -> &[Value] {
    v.as_array().map_or(&[], Vec::as_slice)
}

fn read(path: &Path) -> Result<String, String> {
    std::fs::read(path)
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .map_err(|e| format!("{}: {e} (run `git submodule update --init` for the submodules)", path.display()))
}

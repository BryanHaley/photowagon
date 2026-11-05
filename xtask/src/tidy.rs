//! `cargo xtask tidy`: removes build output that only piles up. Cargo never deletes an old build
//! (each profile, target and feature set keeps its own copy of a 300-700 MB library, and every
//! test binary ever built), and a build folder made for one run stays behind. All of it is
//! rebuilt when needed.

use std::path::Path;
use std::time::{Duration, SystemTime};

/// Cargo output not touched for this long goes.
const STALE: Duration = Duration::from_secs(7 * 24 * 3600);
/// A folder made for one run goes once unused this long (a build may still be using a newer one).
const UNUSED: Duration = Duration::from_secs(24 * 3600);

/// Xcode build folders the tooling keeps; any other `target/ios/*dd*` was made for one run.
const KEPT_XCODE: &[&str] = &["target/ios/dd", "target/omega/dd", "target/omega/dd-device", "target/omega/dd-release"];

pub fn cmd(root: &Path) -> Result<(), String> {
    let freed = run(root);
    println!("tidy: freed {:.1} GB", freed as f64 / 1e9);
    Ok(())
}

/// Before a build. Not on CI: each job has a fresh machine, and a restored cache keeps its old
/// dates, so it would all look stale.
pub fn auto(root: &Path) {
    if std::env::var_os("CI").is_none() {
        run(root);
    }
}

/// Tidies `root`'s `target/`; returns the bytes freed. Errors are skipped: tidying is best effort.
pub fn run(root: &Path) -> u64 {
    let target = root.join("target");
    let now = SystemTime::now();
    let mut freed = 0;
    // Folders made for one run: agents' own target dirs and Xcode build folders.
    for dir in [target.clone(), target.join("ios")] {
        for e in entries(&dir) {
            let name = e.file_name().to_string_lossy().to_string();
            let rel = e.path().strip_prefix(root).map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
            let one_run = (dir == target && name.starts_with("agent-")) || (dir != target && name.ends_with("dd") && !KEPT_XCODE.contains(&rel.as_str()));
            if one_run && e.path().is_dir() && unused(&e.path(), now) {
                freed += remove(&e.path());
            }
        }
    }
    // Cargo's profile folders: target/<profile> and target/<triple>/<profile>.
    let mut profiles = Vec::new();
    for e in entries(&target) {
        let p = e.path();
        if p.join(".fingerprint").is_dir() {
            profiles.push(p);
        } else if p.is_dir() {
            profiles.extend(entries(&p).into_iter().map(|e| e.path()).filter(|q| q.join(".fingerprint").is_dir()));
        }
    }
    for profile in profiles {
        // The libraries and binaries Cargo copies up beside `deps` too.
        let top = entries(&profile).into_iter().filter(|e| e.path().is_file());
        let below = ["deps", "build", ".fingerprint", "incremental", "examples"].into_iter().flat_map(|sub| entries(&profile.join(sub)));
        for e in top.chain(below) {
            let stale = e.metadata().and_then(|m| m.modified()).is_ok_and(|t| now.duration_since(t).unwrap_or_default() > STALE);
            if stale {
                freed += remove(&e.path());
            }
        }
    }
    freed
}

/// Nothing in `dir` or the two levels below it changed for [`UNUSED`]: every Xcode build or test
/// writes to its `Logs`, every Cargo build to its `incremental`.
fn unused(dir: &Path, now: SystemTime) -> bool {
    let changed = |p: &Path| p.metadata().and_then(|m| m.modified()).ok();
    let mut newest = changed(dir);
    for a in entries(dir) {
        newest = newest.max(changed(&a.path()));
        for b in entries(&a.path()) {
            newest = newest.max(changed(&b.path()));
        }
    }
    newest.is_some_and(|t| now.duration_since(t).unwrap_or_default() > UNUSED)
}

fn entries(dir: &Path) -> Vec<std::fs::DirEntry> {
    std::fs::read_dir(dir).map(|r| r.flatten().collect()).unwrap_or_default()
}

/// Removes a file or folder; returns its size, or 0 when it couldn't go.
fn remove(p: &Path) -> u64 {
    let size = size(p);
    let gone = if p.is_dir() { std::fs::remove_dir_all(p) } else { std::fs::remove_file(p) };
    if gone.is_ok() { size } else { 0 }
}

fn size(p: &Path) -> u64 {
    let Ok(m) = std::fs::symlink_metadata(p) else { return 0 };
    if m.is_dir() { entries(p).iter().map(|e| size(&e.path())).sum() } else { m.len() }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn age(p: &Path, days: u64) {
        let t = SystemTime::now() - Duration::from_secs(days * 24 * 3600);
        std::fs::File::open(p).and_then(|f| f.set_modified(t)).unwrap();
    }

    fn put(p: &Path, days: u64) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, b"x").unwrap();
        age(p, days);
    }

    #[test]
    fn old_builds_and_one_run_folders_go_the_rest_stays() {
        let root = std::env::temp_dir().join(format!("tidy-{}", std::process::id()));
        let t = root.join("target");
        put(&t.join("debug/deps/old.rlib"), 9);
        put(&t.join("debug/deps/new.rlib"), 1);
        put(&t.join("debug/.fingerprint/old/f"), 9);
        age(&t.join("debug/.fingerprint/old"), 9);
        put(&t.join("aarch64-apple-ios/release/deps/old.a"), 9);
        put(&t.join("aarch64-apple-ios/release/.fingerprint/x"), 1);
        put(&t.join("debug/libold.a"), 9);
        put(&t.join("debug/libkept.a"), 1);
        put(&t.join("ios/walk-dd/Logs/l"), 3);
        for d in ["ios/walk-dd/Logs", "ios/walk-dd"] {
            age(&t.join(d), 3);
        }
        put(&t.join("ios/busy-dd/Logs/l"), 0);
        put(&t.join("ios/dd/Logs/l"), 3);
        put(&t.join("ios/PhotoWagon.xcarchive/Info.plist"), 30);
        run(&root);
        for gone in ["debug/libold.a", "debug/deps/old.rlib", "debug/.fingerprint/old", "aarch64-apple-ios/release/deps/old.a", "ios/walk-dd"] {
            assert!(!t.join(gone).exists(), "{gone}");
        }
        for kept in ["debug/deps/new.rlib", "debug/libkept.a", "ios/busy-dd", "ios/dd", "ios/PhotoWagon.xcarchive"] {
            assert!(t.join(kept).exists(), "{kept}");
        }
        std::fs::remove_dir_all(&root).unwrap();
    }
}

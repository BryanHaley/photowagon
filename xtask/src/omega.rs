//! `cargo xtask omega`: the long pre-release test (plan/omega-e2e.md). Builds once, runs the Omega
//! scheme on iOS 27 and iOS 18 side by side, resumes after a crash, and writes the report.

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Deserialize;

use crate::run;

/// Where a section runs: a simulator, and the name of its results folder. Tier B's lanes are
/// iOS versions (the folder is the version the app reports); tier A's are device setups.
struct Lane {
    name: &'static str,
    destination: &'static str,
    tier: Tier,
}

#[derive(Clone, Copy, PartialEq)]
enum Tier {
    /// In-app combinations (PhotoWagonOmegaTests).
    B,
    /// Touch (PhotoWagonOmegaUITests).
    A,
    /// Part 2, on a real device (`omega device`).
    D,
    /// The walkthrough UI tests (PhotoWagonUITests, scheme PhotoWagon), one class at a time.
    W,
}

impl Tier {
    fn target(self) -> &'static str {
        match self {
            Tier::B => "PhotoWagonOmegaTests",
            Tier::A | Tier::D => "PhotoWagonOmegaUITests",
            Tier::W => "PhotoWagonUITests",
        }
    }
}

const LANES: [Lane; 11] = [
    Lane { name: "27.0", destination: "platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0", tier: Tier::B },
    Lane { name: "18.5", destination: "platform=iOS Simulator,name=iPhone 16 Pro,OS=18.5", tier: Tier::B },
    Lane { name: "phone27", destination: "platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0", tier: Tier::A },
    Lane { name: "phone18", destination: "platform=iOS Simulator,name=iPhone 16 Pro,OS=18.5", tier: Tier::A },
    Lane { name: "small18", destination: "platform=iOS Simulator,name=iPhone 16e,OS=18.5", tier: Tier::A },
    Lane { name: "ipad27", destination: "platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=27.0", tier: Tier::A },
    Lane { name: "landscape27", destination: "platform=iOS Simulator,name=iPhone 18 Pro Max,OS=27.0", tier: Tier::A },
    Lane { name: "darkLarge27", destination: "platform=iOS Simulator,name=iPhone 17,OS=27.0", tier: Tier::A },
    Lane { name: "walk27", destination: "platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0", tier: Tier::W },
    Lane { name: "walk18", destination: "platform=iOS Simulator,name=iPhone 16 Pro,OS=18.5", tier: Tier::W },
    Lane { name: "device", destination: "", tier: Tier::D },
];

/// Walkthrough classes that make pictures (the store page, the manual) or need a real device.
const NOT_WALKTHROUGHS: [&str; 3] = ["ManualScreenshotsTests", "StoreScreenshotsTests", "DeviceVisionTests"];

/// The simulator's name in a destination, for `simctl`.
fn simulator(destination: &str) -> &str {
    destination.split(',').find_map(|p| p.strip_prefix("name=")).unwrap_or("")
}
/// Runs after a crash: each one picks up where the last stopped.
const MAX_ATTEMPTS: usize = 6;

/// Commands that can't succeed in Omega, with why. Every other command needs an "ok" case.
const NEVER_SUCCEED: [(&str, &str); 3] = [
    ("actions.photoshopStep", "stands for a step that can't play: refusing is its job"),
    ("file.print.page", "Windows only; on iOS the system print dialog picks the paper"),
    ("layer.smartObjects.revealInFinder", "iOS has no Finder"),
];
/// Where the sections are: each `final class Omega<Name>Tests` in a tier's folder is one.
fn sections_source(t: Tier) -> &'static str {
    match t {
        Tier::B => "ios/PhotoWagonOmegaTests",
        Tier::A | Tier::D => "ios/PhotoWagonOmegaUITests",
        Tier::W => "ios/PhotoWagonUITests",
    }
}

#[derive(Deserialize)]
struct Case {
    id: String,
    command: String,
    fixture: String,
    params: String,
    outcome: String,
    message: Option<String>,
    #[serde(rename = "undoSteps")]
    undo_steps: Option<u32>,
    problems: Vec<String>,
    ms: u64,
}

/// What a section's run left: `status.json` (written when it finishes) and `code.txt` (the code it
/// ran on, written by the runner).
struct Section {
    lane: &'static Lane,
    name: String,
    status: Option<String>,
    code: Option<String>,
}

impl Section {
    fn class(&self) -> String {
        if self.lane.tier == Tier::W { format!("{}Tests", self.name) } else { format!("Omega{}Tests", self.name) }
    }
    fn state(&self, code: &str) -> &'static str {
        match self.status.as_deref() {
            None if self.code.is_none() => "not run",
            None => "crashed or stopped",
            Some("pass") if self.code.as_deref() == Some(code) => "pass",
            Some("pass") => "pass (older code)",
            _ => "fail",
        }
    }
}

const USAGE: &str = "usage: cargo xtask omega <command>
  run                    every section, from scratch (before an App Store upload)
  run --section <Name>   only these sections, from scratch (repeat --section for more)
  run --failed           only sections that failed, crashed, never ran or ran on older code
  run --resume           carry on an interrupted run, keeping finished cases
  run --skip <Name>      leave a section out (repeat for more); with any of the above
  run --coverage         with any of the above: the Rust core counts its lines, instead of the
                         Swift (both at once don't work; Speed is left out: the counting slows it)
  device                 part 2 on the iPhone or iPad plugged in (OMEGA_TEAM = your signing team)
  gate                   passes only when every section, part 2 included, passed on this code:
                         the check before an App Store upload
  list                   every section and its state
  report                 write the report again
  coverage               which lines of the app's Swift the runs so far reached (counts start
                         afresh with a full run from scratch)
  accept                 after looking at them: this run's pictures and timings become the
                         approved ones, in the baselines checkout ($OMEGA_BASELINES, or
                         ../photowagon-omega-baselines), for you to commit there";

pub fn cmd(root: &Path, args: &[&str]) -> Result<(), String> {
    let dir = root.join("target/omega");
    let results = dir.join("results");
    let code = code_hash(root)?;
    match args.first().copied() {
        Some("run") => {
            crate::tidy::auto(root);
            let all = sections(root, &results)?;
            let named: Vec<&str> = args.windows(2).filter(|w| w[0] == "--section").map(|w| w[1]).collect();
            for n in &named {
                if !all.iter().any(|s| s.name == *n) {
                    return Err(format!("no section `{n}`: see `cargo xtask omega list`"));
                }
            }
            let resume = args.contains(&"--resume");
            RUST_COVERAGE.store(args.contains(&"--coverage"), std::sync::atomic::Ordering::Relaxed);
            let mut skipped: Vec<&str> = args.windows(2).filter(|w| w[0] == "--skip").map(|w| w[1]).collect();
            if rust_coverage() {
                skipped.push("Speed");
            }
            let picked: Vec<&Section> = all
                .iter()
                .filter(|s| s.lane.tier != Tier::D && !skipped.contains(&s.name.as_str()))
                .filter(|s| {
                    if !named.is_empty() {
                        named.contains(&s.name.as_str())
                    } else if args.contains(&"--failed") {
                        s.state(&code) != "pass"
                    } else if resume {
                        s.status.is_none()
                    } else {
                        true
                    }
                })
                .collect();
            if picked.is_empty() {
                eprintln!("omega: nothing to run");
                return Ok(());
            }
            // A full run from scratch counts afresh: the counts only match the build they came from.
            if !resume && named.is_empty() && !args.contains(&"--failed") {
                let _ = std::fs::remove_dir_all(dir.join("dd/Build/ProfileData"));
                let _ = std::fs::remove_dir_all(rust_raw(&dir));
            }
            if rust_coverage() {
                std::fs::create_dir_all(rust_raw(&dir)).map_err(|e| format!("{}: {e}", rust_raw(&dir).display()))?;
            }
            for s in &picked {
                let folder = results.join(s.lane.name).join(s.class());
                if !resume {
                    let _ = std::fs::remove_dir_all(&folder);
                }
                std::fs::create_dir_all(&folder).map_err(|e| format!("{}: {e}", folder.display()))?;
                std::fs::write(folder.join("code.txt"), &code).map_err(|e| format!("{}: {e}", folder.display()))?;
            }
            build(root, &dir)?;
            for attempt in 1..=MAX_ATTEMPTS {
                // Sections not finished yet, by lane.
                let left: Vec<(&'static Lane, Vec<String>)> = LANES
                    .iter()
                    .map(|lane| {
                        let classes = picked
                            .iter()
                            .filter(|s| std::ptr::eq(s.lane, lane) && !results.join(lane.name).join(s.class()).join("status.json").exists())
                            .map(|s| s.class())
                            .collect();
                        (lane, classes)
                    })
                    .filter(|(_, c): &(&'static Lane, Vec<String>)| !c.is_empty())
                    .collect();
                if left.is_empty() {
                    break;
                }
                if attempt > 1 {
                    eprintln!("omega: a section crashed or stopped; resuming it (attempt {attempt} of {MAX_ATTEMPTS})");
                }
                test(root, &dir, &results, &left)?;
            }
            let page = report(root, &results, &dir.join("report"), &code)?;
            let after = sections(root, &results)?;
            print_sections(&after, &code);
            eprintln!("omega: report at {}", page.display());
            let bad = after.iter().filter(|s| s.state(&code) != "pass").count();
            if bad == 0 { Ok(()) } else { Err(format!("omega: {bad} section(s) not passing on this code; `cargo xtask omega run --failed` reruns only those")) }
        }
        Some("list") => {
            print_sections(&sections(root, &results)?, &code);
            Ok(())
        }
        Some("accept") => accept(root, &results),
        Some("gate") => {
            let all = sections(root, &results)?;
            let bad: Vec<String> = all.iter().filter(|s| s.state(&code) != "pass").map(|s| format!("{} {}: {}", s.lane.name, s.name, s.state(&code))).collect();
            let never = without_success(&tier_b_cases(&results));
            if !bad.is_empty() {
                Err(format!("omega: {} of {} sections don't pass on this code:\n  {}", bad.len(), all.len(), bad.join("\n  ")))
            } else if !never.is_empty() {
                Err(format!("omega: {} commands have no successful case: {}", never.len(), never.join(", ")))
            } else {
                eprintln!("omega: all {} sections pass on this code", all.len());
                Ok(())
            }
        }
        Some("device") => device(root, &dir, &results, &code),
        Some("coverage") => coverage(&dir),
        Some("report") => {
            let page = report(root, &results, &dir.join("report"), &code)?;
            eprintln!("omega: report at {}", page.display());
            Ok(())
        }
        _ => Err(USAGE.into()),
    }
}

/// Every section on every lane of its tier, with what its last run left.
fn sections(root: &Path, results: &Path) -> Result<Vec<Section>, String> {
    let mut out = Vec::new();
    for tier in [Tier::B, Tier::A, Tier::W, Tier::D] {
        let dir = root.join(sections_source(tier));
        let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
            .map_err(|e| format!("{}: {e}", dir.display()))?
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|e| e == "swift"))
            .collect();
        files.sort();
        let src: String = files.iter().filter_map(|f| std::fs::read_to_string(f).ok()).collect::<Vec<_>>().join("\n");
        let names: Vec<String> = if tier == Tier::D {
            vec!["Device".into()]
        } else if tier == Tier::W {
            src.lines()
                .filter_map(|l| l.trim_start().strip_prefix("final class "))
                .filter_map(|rest| rest.split_once("Tests:").map(|(n, _)| n.to_string()))
                .filter(|n| !NOT_WALKTHROUGHS.contains(&format!("{n}Tests").as_str()))
                .collect()
        } else {
            src.lines()
                .filter_map(|l| l.trim_start().strip_prefix("final class Omega"))
                .filter_map(|rest| rest.split_once("Tests:").map(|(n, _)| n.to_string()))
                .collect()
        };
        for lane in LANES.iter().filter(|l| l.tier == tier) {
            for name in &names {
                let folder = results.join(lane.name).join(if tier == Tier::W { format!("{name}Tests") } else { format!("Omega{name}Tests") });
                let status = std::fs::read_to_string(folder.join("status.json"))
                    .ok()
                    .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
                    .and_then(|v| v.get("status").and_then(|s| s.as_str()).map(String::from));
                let code = std::fs::read_to_string(folder.join("code.txt")).ok();
                out.push(Section { lane, name: name.clone(), status, code });
            }
        }
    }
    Ok(out)
}

fn print_sections(sections: &[Section], code: &str) {
    for s in sections {
        eprintln!("  {:<12} {:<14} {}", s.lane.name, s.name, s.state(code));
    }
}

/// The approved pictures and timings: a checkout of their own repo, pinned by its commit.
fn baselines(root: &Path) -> PathBuf {
    std::env::var_os("OMEGA_BASELINES").map_or_else(|| root.join("../photowagon-omega-baselines"), PathBuf::from)
}

/// This run's pictures and timings (iOS 27) become the approved ones.
fn accept(root: &Path, results: &Path) -> Result<(), String> {
    let base = baselines(root);
    let pictures = base.join("pictures");
    std::fs::create_dir_all(&pictures).map_err(|e| format!("{}: {e}", pictures.display()))?;
    let from = results.join(LANES[0].name).join("OmegaPicturesTests/pictures");
    let mut n = 0;
    for f in std::fs::read_dir(&from).map_err(|e| format!("{}: {e} (run the Pictures section first)", from.display()))?.flatten() {
        std::fs::copy(f.path(), pictures.join(f.file_name())).map_err(|e| format!("{}: {e}", f.path().display()))?;
        n += 1;
    }
    let mut timings = serde_json::Map::new();
    for c in read(&results.join(LANES[0].name).join("OmegaSpeedTests")) {
        let ms = c.message.as_deref().and_then(|m| m.rsplit("; ").next()).and_then(|m| m.split(" ms").next()).and_then(|v| v.trim().parse::<f64>().ok());
        if let (Some(ms), "ok") = (ms, c.outcome.as_str()) {
            timings.insert(c.command, ms.into());
        }
    }
    let t = base.join("timings.json");
    std::fs::write(&t, serde_json::to_string_pretty(&timings).map_err(|e| e.to_string())?).map_err(|e| format!("{}: {e}", t.display()))?;
    eprintln!("omega: {n} pictures and {} timings approved in {}; commit them there", timings.len(), base.display());
    Ok(())
}

/// The code a run tests: the commit plus every uncommitted change, new files included.
fn code_hash(root: &Path) -> Result<String, String> {
    let git = |args: &[&str]| -> Result<Vec<u8>, String> {
        let out = Command::new("git").args(args).current_dir(root).output().map_err(|e| format!("git: {e}"))?;
        if out.status.success() { Ok(out.stdout) } else { Err(format!("git {}: {}", args.join(" "), String::from_utf8_lossy(&out.stderr))) }
    };
    let mut all = git(&["rev-parse", "HEAD"])?;
    all.extend(git(&["diff", "HEAD", "--binary"])?);
    let untracked = git(&["ls-files", "--others", "--exclude-standard", "-z"])?;
    for f in untracked.split(|b| *b == 0).filter(|f| !f.is_empty()) {
        all.extend_from_slice(f);
        all.extend(std::fs::read(root.join(String::from_utf8_lossy(f).as_ref())).unwrap_or_default());
    }
    Ok(crate::sha256::hex(&all))
}

/// Omega tests the shipping Rust core (release), in a Debug app build (tests need testability).
const RUST_RELEASE: &str = "PHOTOWAGON_RUST_RELEASE=1";
/// Every build and run counts which lines of the app's Swift ran (`omega coverage`), except a
/// `run --coverage`: Xcode's coverage runtime would take the Rust core's counts over.
fn swift_coverage() -> [&'static str; 2] {
    ["-enableCodeCoverage", if rust_coverage() { "NO" } else { "YES" }]
}
/// `run --coverage`: the Rust core counts its lines instead of the Swift (slower: Speed is left out).
static RUST_COVERAGE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn rust_coverage() -> bool {
    RUST_COVERAGE.load(std::sync::atomic::Ordering::Relaxed)
}

/// Where the Rust core's counts go (`OMEGA_RUST_COVERAGE` in the tests).
fn rust_raw(dir: &Path) -> PathBuf {
    dir.join("coverage/rust-raw")
}

fn build(root: &Path, dir: &Path) -> Result<(), String> {
    // Xcode keeps every test run's result bundle here; the sections keep what they need.
    let _ = std::fs::remove_dir_all(dir.join("dd/Logs/Test"));
    crate::ios::cmd(root, if rust_coverage() { &["--sim", "--release", "--coverage"] } else { &["--sim", "--release"] })?;
    let rust_cov = if rust_coverage() { "PHOTOWAGON_RUST_COVERAGE=1" } else { "PHOTOWAGON_RUST_COVERAGE=0" };
    let mut c = Command::new("xcodegen");
    c.arg("generate").current_dir(root.join("ios"));
    run(c, "xcodegen generate")?;
    let mut c = xcodebuild(root, dir);
    // A generic simulator build also wants x86_64, which the Rust library doesn't have.
    c.args(["-destination", LANES[0].destination, "build-for-testing", "-quiet", RUST_RELEASE, rust_cov]);
    run(c, "xcodebuild build-for-testing (Omega)")?;
    let mut c = Command::new("xcodebuild");
    c.current_dir(root.join("ios"))
        .args(["-project", "PhotoWagon.xcodeproj", "-scheme", "PhotoWagon", "-derivedDataPath"])
        .arg(dir.join("dd"))
        .args(swift_coverage())
        .args(["-destination", LANES[0].destination, "build-for-testing", "-quiet", RUST_RELEASE, rust_cov]);
    run(c, "xcodebuild build-for-testing (walkthroughs)")
}

/// Runs each lane's classes on its simulator, two lanes at a time (more overloads this Mac). A
/// failing class doesn't stop the run: the sections' own status files say how each went.
fn test(root: &Path, dir: &Path, results: &Path, left: &[(&'static Lane, Vec<String>)]) -> Result<(), String> {
    let base: Vec<_> = xcodebuild(root, dir).get_args().map(ToOwned::to_owned).collect();
    let (walk, omega): (Vec<_>, Vec<_>) = left.iter().partition(|(lane, _)| lane.tier == Tier::W);
    let left: Vec<(&'static Lane, Vec<String>)> = omega.into_iter().cloned().collect();
    walkthroughs(root, dir, results, &walk);
    for pair in left.chunks(2) {
        let mut running = Vec::new();
        for (lane, classes) in pair {
            // Looked at again now: a section may have finished meanwhile (another run, by hand).
            let classes: Vec<&String> = classes.iter().filter(|c| !results.join(lane.name).join(c.as_str()).join("status.json").exists()).collect();
            if classes.is_empty() {
                continue;
            }
            let dark = lane.name.starts_with("darkLarge");
            if dark {
                simctl_ui(lane, &[&["appearance", "dark"], &["content_size", "accessibility-extra-extra-extra-large"]]);
            }
            let mut c = Command::new("caffeinate");
            // Keep the Mac awake while it runs.
            c.arg("-i").arg("xcodebuild").args(&base).current_dir(root.join("ios")).args(["-destination", lane.destination]);
            for class in &classes {
                c.arg(format!("-only-testing:{}/{class}", lane.tier.target()));
            }
            if rust_coverage() {
                c.env("TEST_RUNNER_OMEGA_RUST_COVERAGE", rust_raw(dir));
            }
            c.env("TEST_RUNNER_OMEGA_OUT", results)
                .env("TEST_RUNNER_OMEGA_BASELINES", baselines(root))
                .env("TEST_RUNNER_OMEGA_SETUP", lane.name)
                .args(["test-without-building", "-quiet", "-collect-test-diagnostics", "never", "-resultBundlePath"])
                .arg(bundle(dir, lane));
            // xcodebuild refuses a bundle that is already there.
            let _ = std::fs::remove_dir_all(bundle(dir, lane));
            let _ = std::fs::create_dir_all(dir.join("bundles"));
            eprintln!("$ xcodebuild test-without-building (Omega, {}: {})", lane.name, classes.iter().map(|c| c.as_str()).collect::<Vec<_>>().join(", "));
            // Its own process group, so a stuck lane can be stopped with its xcodebuild.
            std::os::unix::process::CommandExt::process_group(&mut c, 0);
            running.push((lane, dark, c.spawn().map_err(|e| format!("xcodebuild: {e}"))?));
        }
        // A lane that writes no result for its stall time is stuck (a test waiting on something that
        // won't happen): stop it, and the next attempt resumes it, the stuck item noted as a crash.
        let stall = if rust_coverage() { STALL * 3 } else { STALL };
        let mut watch: Vec<(u64, std::time::Instant)> = running.iter().map(|_| (0, std::time::Instant::now())).collect();
        while running.iter_mut().any(|(_, _, c)| matches!(c.try_wait(), Ok(None))) {
            std::thread::sleep(std::time::Duration::from_secs(30));
            for ((lane, _, c), (seen, last)) in running.iter_mut().zip(&mut watch) {
                let now = written(&results.join(lane.name));
                if now != *seen {
                    (*seen, *last) = (now, std::time::Instant::now());
                } else if last.elapsed() > stall && matches!(c.try_wait(), Ok(None)) {
                    eprintln!("omega: {} wrote nothing for {} min; stopping it to resume it", lane.name, stall.as_secs() / 60);
                    let _ = Command::new("kill").args(["-TERM", &format!("-{}", c.id())]).status();
                    *last = std::time::Instant::now();
                }
            }
        }
        for (lane, dark, mut child) in running {
            let _ = child.wait();
            // The sections write their own results; the bundle is GBs of screen recording.
            let _ = std::fs::remove_dir_all(bundle(dir, lane));
            if dark {
                simctl_ui(lane, &[&["appearance", "light"], &["content_size", "large"]]);
            }
        }
    }
    Ok(())
}

/// Where a lane's xcodebuild puts its result bundle (else it lands in DerivedData's logs).
fn bundle(dir: &Path, lane: &Lane) -> PathBuf {
    dir.join("bundles").join(format!("{}.xcresult", lane.name))
}

/// What part 2 asks a person, since no test can do it.
const BY_HAND: [&str; 6] = [
    "Pencil: pressure makes the brush thicker and darker",
    "Pencil: tilt shades with the side of the tip",
    "Pencil: hovering shows where the brush will land",
    "Pencil: squeeze (Pencil Pro) opens the tool palette",
    "Pencil: double-tap switches to the eraser",
    "Photos: a Live Photo opens, and an edit saves to Photos",
];

/// Part 2: the device tests on the iPhone or iPad plugged in, the Release build, and the checks
/// done by hand.
fn device(root: &Path, dir: &Path, results: &Path, code: &str) -> Result<(), String> {
    let team = std::env::var("OMEGA_TEAM").map_err(|_| "set OMEGA_TEAM to your Apple signing team id".to_string())?;
    let list = Command::new("xcrun").args(["devicectl", "list", "devices"]).output().map_err(|e| format!("devicectl: {e}"))?;
    let udid = String::from_utf8_lossy(&list.stdout)
        .lines()
        .find(|l| l.contains("physical") && l.contains("available"))
        .and_then(|l| l.split_whitespace().find(|w| w.len() >= 24 && w.contains('-')))
        .map(String::from)
        .ok_or("no iPhone or iPad is plugged in and unlocked")?;
    let folder = results.join("device").join("OmegaDeviceTests");
    let _ = std::fs::remove_dir_all(&folder);
    std::fs::create_dir_all(&folder).map_err(|e| format!("{}: {e}", folder.display()))?;
    std::fs::write(folder.join("code.txt"), code).map_err(|e| e.to_string())?;
    let dd = dir.join("dd-device");
    let destination = format!("id={udid}");
    let signing = [format!("DEVELOPMENT_TEAM={team}"), "CODE_SIGN_STYLE=Automatic".into()];

    crate::ios::cmd(root, &["--device"])?;
    let mut c = Command::new("xcodebuild");
    c.current_dir(root.join("ios"))
        .args(["-project", "PhotoWagon.xcodeproj", "-scheme", "Omega", "-destination", &destination, "-derivedDataPath"])
        .arg(&dd)
        .args(["-allowProvisioningUpdates", "build-for-testing", "-quiet"])
        .args(&signing);
    run(c, "xcodebuild build-for-testing (Omega, device)")?;

    // The photos, in the app's Documents.
    let app = dd.join("Build/Products/Debug-iphoneos/PhotoWagon.app");
    let mut c = Command::new("xcrun");
    c.args(["devicectl", "device", "install", "app", "--device", &udid]).arg(&app);
    run(c, "devicectl install (Omega build)")?;
    let samples = root.join("ios/PhotoWagonUITests/Samples");
    let big = dir.join("big.jpg");
    let mut c = Command::new("sips");
    c.args(["-z", "4000", "6000"]).arg(samples.join("seaside.jpg")).arg("--out").arg(&big);
    run(c, "sips (a 24 MP photo)")?;
    for (file, name) in [(samples.join("subject.jpg"), "subject.jpg"), (samples.join("seaside.jpg"), "seaside.jpg"), (big.clone(), "big.jpg")] {
        let mut c = Command::new("xcrun");
        c.args([
            "devicectl",
            "device",
            "copy",
            "to",
            "--device",
            &udid,
            "--domain-type",
            "appDataContainer",
            "--domain-identifier",
            "net.bhaley.photowagon",
            "--source",
        ])
        .arg(&file)
        .args(["--destination", &format!("Documents/{name}")]);
        run(c, &format!("devicectl copy {name}"))?;
    }

    let mut cases: Vec<serde_json::Value> = Vec::new();
    let out = Command::new("xcodebuild")
        .current_dir(root.join("ios"))
        .args(["-project", "PhotoWagon.xcodeproj", "-scheme", "Omega", "-destination", &destination, "-derivedDataPath"])
        .arg(&dd)
        .args(["test-without-building", "-only-testing:PhotoWagonOmegaUITests/DeviceOmegaTests"])
        .args(&signing)
        .output()
        .map_err(|e| format!("xcodebuild: {e}"))?;
    let log = String::from_utf8_lossy(&out.stdout);
    for line in log.lines().filter(|l| l.starts_with("Test Case '-[PhotoWagonOmegaUITests.DeviceOmegaTests ")) {
        let name = line.split_whitespace().nth(3).unwrap_or("").trim_end_matches("]'");
        let passed = line.contains("' passed");
        let problems: Vec<String> = if passed || line.contains("skipped") { vec![] } else { vec![format!("{name} failed: see target/omega/device.log")] };
        cases.push(serde_json::json!({"id": format!("device|{name}"), "command": name, "fixture": "device", "params": "", "outcome": if passed { "ok" } else { "failed" }, "problems": problems, "ms": 0}));
    }
    let _ = std::fs::write(dir.join("device.log"), log.as_bytes());
    if cases.is_empty() {
        cases.push(serde_json::json!({"id": "device|tests", "command": "device tests", "fixture": "device", "params": "", "outcome": "failed", "problems": ["the device tests didn't run: see target/omega/device.log"], "ms": 0}));
    }

    // The Release build installs and opens.
    let mut c = Command::new("xcodebuild");
    c.current_dir(root.join("ios"))
        .args(["-project", "PhotoWagon.xcodeproj", "-scheme", "PhotoWagon", "-configuration", "Release", "-destination", &destination, "-derivedDataPath"])
        .arg(dir.join("dd-release"))
        .args(["-allowProvisioningUpdates", "build", "-quiet"])
        .args(&signing);
    let release_ok = crate::ios::cmd(root, &["--device", "--release"]).is_ok() && run(c, "xcodebuild build (Release, device)").is_ok() && {
        let app = dir.join("dd-release/Build/Products/Release-iphoneos/PhotoWagon.app");
        let installed = Command::new("xcrun").args(["devicectl", "device", "install", "app", "--device", &udid]).arg(&app).status().is_ok_and(|s| s.success());
        let launched = Command::new("xcrun")
            .args(["devicectl", "device", "process", "launch", "--device", &udid, "net.bhaley.photowagon"])
            .output()
            .is_ok_and(|o| String::from_utf8_lossy(&o.stdout).contains("Launched"));
        installed && launched
    };
    cases.push(serde_json::json!({"id": "device|release", "command": "Release build installs and opens", "fixture": "device", "params": "", "outcome": if release_ok { "ok" } else { "failed" }, "problems": if release_ok { vec![] } else { vec!["the Release build didn't install or open (is the device unlocked?)".to_string()] }, "ms": 0}));

    // By hand.
    let tty = std::io::IsTerminal::is_terminal(&std::io::stdin());
    for (i, q) in BY_HAND.iter().enumerate() {
        let answer = if tty {
            eprint!("omega: on the device, {q}? [y/n] ");
            let mut a = String::new();
            let _ = std::io::stdin().read_line(&mut a);
            a.trim().to_lowercase()
        } else {
            String::new()
        };
        let problems: Vec<String> = match answer.as_str() {
            "y" | "yes" => vec![],
            "" => vec!["not checked by hand (run `cargo xtask omega device` in a terminal)".into()],
            _ => vec![format!("checked by hand: {q}: no")],
        };
        cases.push(serde_json::json!({"id": format!("device|hand{i}"), "command": q, "fixture": "device", "params": "", "outcome": "by hand", "problems": problems, "ms": 0}));
    }

    let failed = cases.iter().filter(|c| c["problems"].as_array().is_some_and(|p| !p.is_empty())).count();
    let lines: String = cases.iter().map(|c| format!("{c}\n")).collect();
    std::fs::write(folder.join("results.jsonl"), lines).map_err(|e| e.to_string())?;
    let status = serde_json::json!({"status": if failed == 0 { "pass" } else { "fail" }, "cases": cases.len(), "failed": failed});
    std::fs::write(folder.join("status.json"), status.to_string()).map_err(|e| e.to_string())?;
    let page = report(root, results, &dir.join("report"), code)?;
    eprintln!("omega: part 2: {} checks, {failed} with problems; report at {}", cases.len(), page.display());
    if failed == 0 { Ok(()) } else { Err(format!("omega: part 2 has {failed} problem(s)")) }
}

/// The walkthrough classes, one xcodebuild each (its exit says pass or fail), both lanes at once.
fn walkthroughs(root: &Path, dir: &Path, results: &Path, lanes: &[&(&'static Lane, Vec<String>)]) {
    std::thread::scope(|scope| {
        for (lane, classes) in lanes.iter().copied() {
            scope.spawn(move || {
                for class in classes {
                    let folder = results.join(lane.name).join(class);
                    let mut c = Command::new("caffeinate");
                    c.arg("-i")
                        .arg("xcodebuild")
                        .current_dir(root.join("ios"))
                        .args(["-project", "PhotoWagon.xcodeproj", "-scheme", "PhotoWagon", "-derivedDataPath"])
                        .arg(dir.join("dd"))
                        .args(swift_coverage())
                        // No diagnostics after a failure: collecting them takes 10 minutes a time.
                        .args(["-destination", lane.destination, "test-without-building", "-collect-test-diagnostics", "never", "-resultBundlePath"])
                        .arg(folder.join("result.xcresult"))
                        .arg(format!("-only-testing:PhotoWagonUITests/{class}"));
                    // A walkthrough can crawl without ever stalling, so it gets a limit of its own.
                    let limit = if rust_coverage() { WALK_LIMIT_SECS * 5 } else { WALK_LIMIT_SECS }.to_string();
                    c.args(["-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", &limit, "-maximum-test-execution-time-allowance", &limit]);
                    if rust_coverage() {
                        c.env("TEST_RUNNER_OMEGA_RUST_COVERAGE", rust_raw(dir));
                    }
                    eprintln!("$ xcodebuild test-without-building (walkthrough {class}, {})", lane.name);
                    let _ = std::fs::remove_dir_all(folder.join("result.xcresult"));
                    let start = std::time::Instant::now();
                    let out = c.output();
                    let ok = out.as_ref().is_ok_and(|o| o.status.success());
                    let log = out.map(|o| String::from_utf8_lossy(&o.stdout).into_owned() + &String::from_utf8_lossy(&o.stderr)).unwrap_or_default();
                    let _ = std::fs::write(folder.join("xcodebuild.log"), &log);
                    // Kept only to look at a failure: each is about a gigabyte.
                    if ok {
                        let _ = std::fs::remove_dir_all(folder.join("result.xcresult"));
                    }
                    let problems: Vec<String> =
                        if ok { vec![] } else { vec![format!("the walkthrough failed: see {}", folder.join("result.xcresult").display())] };
                    let case = serde_json::json!({"id": format!("walk|{class}"), "command": class, "fixture": lane.name, "params": "", "outcome": if ok { "ok" } else { "failed" }, "problems": problems, "ms": start.elapsed().as_millis() as u64});
                    let _ = std::fs::write(folder.join("results.jsonl"), format!("{case}\n"));
                    let status = serde_json::json!({"status": if ok { "pass" } else { "fail" }, "cases": 1, "failed": u8::from(!ok)});
                    let _ = std::fs::write(folder.join("status.json"), status.to_string());
                }
            });
        }
    });
}

/// The longest one walkthrough may take. The slowest normally takes about 12 minutes.
const WALK_LIMIT_SECS: u32 = 30 * 60;

/// How long a lane may go without writing a result before it counts as stuck.
const STALL: std::time::Duration = std::time::Duration::from_secs(15 * 60);

/// Bytes of results written under a lane's folder, to see whether it's moving.
fn written(lane: &Path) -> u64 {
    std::fs::read_dir(lane).map(|d| d.flatten().filter_map(|e| std::fs::metadata(e.path().join("results.jsonl")).ok()).map(|m| m.len()).sum()).unwrap_or(0)
}

/// Dark mode and text size on a lane's simulator (booted first).
fn simctl_ui(lane: &Lane, settings: &[&[&str]]) {
    let name = simulator(lane.destination);
    let _ = Command::new("xcrun").args(["simctl", "boot", name]).output();
    for s in settings {
        let _ = Command::new("xcrun").args(["simctl", "ui", name]).args(*s).status();
    }
}

fn xcodebuild(root: &Path, dir: &Path) -> Command {
    let mut c = Command::new("xcodebuild");
    c.current_dir(root.join("ios"))
        .args(["-project", "PhotoWagon.xcodeproj", "-scheme", "Omega", "-derivedDataPath"])
        .arg(dir.join("dd"))
        .args(swift_coverage());
    c
}

/// Which lines of the app's own Swift every run so far reached: the lanes' counts merged, a
/// report per file in `coverage/swift.txt`.
fn coverage(dir: &Path) -> Result<(), String> {
    let mut profiles = Vec::new();
    let mut stack = vec![dir.join("dd/Build/ProfileData")];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else if p.extension().is_some_and(|x| x == "profraw" || x == "profdata") {
                profiles.push(p);
            }
        }
    }
    let out = dir.join("coverage");
    std::fs::create_dir_all(&out).map_err(|e| format!("{}: {e}", out.display()))?;
    let app = dir.join("dd/Build/Products/Debug-iphonesimulator/PhotoWagon.app");
    let bin = [app.join("PhotoWagon.debug.dylib"), app.join("PhotoWagon")].into_iter().find(|p| p.exists()).ok_or("omega: no app build")?;
    if profiles.is_empty() {
        eprintln!("omega: no Swift coverage yet (run the sections first)");
        return rust_report(dir, &bin, &out);
    }
    let merged = out.join("swift.profdata");
    let mut c = Command::new("xcrun");
    c.args(["llvm-profdata", "merge", "-sparse", "-o"]).arg(&merged).args(&profiles);
    run(c, "llvm-profdata merge")?;
    // The app's own code: not the generated bridge, not the tests.
    let ignore = "photocraft_ffi|PhotoWagonTests|PhotoWagonOmega|PhotoWagonUITests|OmegaShared|DerivedSources";
    let report = Command::new("xcrun")
        .args(["llvm-cov", "report"])
        .arg(&bin)
        .arg("-instr-profile")
        .arg(&merged)
        .args(["-ignore-filename-regex", ignore])
        .output()
        .map_err(|e| format!("llvm-cov: {e}"))?;
    let text = String::from_utf8_lossy(&report.stdout).into_owned();
    std::fs::write(out.join("swift.txt"), &text).map_err(|e| e.to_string())?;
    let total = text.lines().find(|l| l.starts_with("TOTAL")).unwrap_or("");
    let lines = total.split_whitespace().nth(9).unwrap_or("?");
    eprintln!("omega: Swift line coverage {lines} ({} profiles); per file in {}", profiles.len(), out.join("swift.txt").display());
    rust_report(dir, &bin, &out)
}

/// The Rust core's coverage from a `run --coverage`: our crates only (not dependencies), per crate
/// and the files that miss most, in `coverage/rust.txt`. Read with the toolchain's own LLVM tools
/// (`rustup component add llvm-tools`): the counters' format follows rustc's LLVM.
fn rust_report(dir: &Path, bin: &Path, out: &Path) -> Result<(), String> {
    let raws: Vec<PathBuf> =
        std::fs::read_dir(rust_raw(dir)).into_iter().flatten().flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "profraw")).collect();
    if raws.is_empty() {
        eprintln!("omega: no Rust coverage (that takes `run --coverage`)");
        return Ok(());
    }
    let sysroot = Command::new("rustc").args(["--print", "sysroot"]).output().map_err(|e| format!("rustc: {e}"))?;
    let vv = Command::new("rustc").arg("-vV").output().map_err(|e| format!("rustc: {e}"))?;
    let host = String::from_utf8_lossy(&vv.stdout).lines().find_map(|l| l.strip_prefix("host: ").map(str::to_string)).unwrap_or_default();
    let tools = PathBuf::from(String::from_utf8_lossy(&sysroot.stdout).trim()).join("lib/rustlib").join(host).join("bin");
    if !tools.join("llvm-cov").exists() {
        return Err("omega: Rust coverage needs `rustup component add llvm-tools`".into());
    }
    let merged = out.join("rust.profdata");
    let mut c = Command::new(tools.join("llvm-profdata"));
    c.args(["merge", "-sparse", "-o"]).arg(&merged).args(&raws);
    run(c, "llvm-profdata merge (Rust)")?;
    let export = Command::new(tools.join("llvm-cov"))
        .args(["export", "-summary-only"])
        .arg(bin)
        .arg("-instr-profile")
        .arg(&merged)
        .output()
        .map_err(|e| format!("llvm-cov: {e}"))?;
    let json: serde_json::Value = serde_json::from_slice(&export.stdout).map_err(|e| format!("llvm-cov export: {e}"))?;
    // Ours: the workspace's crates (paths relative to the checkout); the rest is dependencies.
    let mut files: Vec<(String, u64, u64)> = json["data"][0]["files"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|f| {
            let name = f["filename"].as_str()?;
            let name = name.strip_prefix("./").unwrap_or(name);
            name.starts_with("crates/")
                .then(|| (name.to_string(), f["summary"]["lines"]["count"].as_u64().unwrap_or(0), f["summary"]["lines"]["covered"].as_u64().unwrap_or(0)))
        })
        .collect();
    let mut crates: std::collections::BTreeMap<String, (u64, u64)> = std::collections::BTreeMap::new();
    for (name, n, c) in &files {
        let e = crates.entry(name.split('/').nth(1).unwrap_or("").to_string()).or_default();
        (e.0, e.1) = (e.0 + n, e.1 + c);
    }
    let pct = |c: u64, n: u64| if n == 0 { 0.0 } else { 100.0 * c as f64 / n as f64 };
    let (n, c) = crates.values().fold((0, 0), |a, v| (a.0 + v.0, a.1 + v.1));
    let mut text = format!("Our crates: {c} of {n} lines ({:.1}%), from {} profiles\n\n", pct(c, n), raws.len());
    let mut by: Vec<_> = crates.iter().collect();
    by.sort_by_key(|e| std::cmp::Reverse(e.1.0));
    for (k, (n, c)) in by {
        text += &format!("{k:12} {n:7} lines {:5.1}%\n", pct(*c, *n));
    }
    files.sort_by_key(|f| std::cmp::Reverse(f.1 - f.2));
    text += "\nMost lines missed:\n";
    for (name, n, c) in files.iter().take(60) {
        text += &format!("{:6} missed of {n:6}  {name}\n", n - c);
    }
    std::fs::write(out.join("rust.txt"), &text).map_err(|e| e.to_string())?;
    eprintln!("omega: Rust line coverage {:.1}% of our crates; per crate in {}", pct(c, n), out.join("rust.txt").display());
    Ok(())
}

/// Every `results.jsonl` under `results` (one per iOS version and test class).
fn shards(results: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(versions) = std::fs::read_dir(results) else { return out };
    for v in versions.flatten() {
        let Ok(classes) = std::fs::read_dir(v.path()) else { continue };
        for c in classes.flatten() {
            if c.path().join("results.jsonl").exists() {
                out.push(c.path());
            }
        }
    }
    out.sort();
    out
}

fn read(shard: &Path) -> Vec<Case> {
    std::fs::read_to_string(shard.join("results.jsonl")).unwrap_or_default().lines().filter_map(|l| serde_json::from_str(l).ok()).collect()
}

/// Every command case on the tier B lanes.
fn tier_b_cases(results: &Path) -> Vec<Case> {
    shards(results)
        .iter()
        .filter(|s| LANES.iter().any(|l| l.tier == Tier::B && s.parent().is_some_and(|v| v.ends_with(l.name))))
        .flat_map(|s| read(s))
        .collect()
}

/// Commands with no "ok" case that `NEVER_SUCCEED` doesn't excuse.
fn without_success(cases: &[Case]) -> Vec<String> {
    let worked: HashSet<&str> = cases.iter().filter(|c| c.outcome == "ok").map(|c| c.command.as_str()).collect();
    let all: BTreeSet<&str> = cases.iter().map(|c| c.command.as_str()).filter(|c| *c != "session").collect();
    all.into_iter().filter(|c| !worked.contains(c) && !NEVER_SUCCEED.iter().any(|(id, _)| id == c)).map(String::from).collect()
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

fn report(root: &Path, results: &Path, out: &Path, code: &str) -> Result<PathBuf, String> {
    std::fs::create_dir_all(out).map_err(|e| format!("{}: {e}", out.display()))?;
    let mut by_version: BTreeMap<String, Vec<Case>> = BTreeMap::new();
    for s in shards(results) {
        let version = s.parent().and_then(Path::file_name).map(|v| v.to_string_lossy().into_owned()).unwrap_or_default();
        by_version.entry(version).or_default().extend(read(&s));
    }
    let mut h = String::from(
        "<!doctype html><meta charset=utf-8><title>Omega report</title><style>\
         body{font:14px -apple-system,sans-serif;margin:24px;max-width:1200px}table{border-collapse:collapse;width:100%}\
         td,th{border-bottom:1px solid #ddd;padding:4px 6px;text-align:left;vertical-align:top}code{font-size:12px;word-break:break-all}\
         .bad{color:#b00020}.ok{color:#1b7f3b}h2{margin-top:32px}</style><h1>Omega report</h1>",
    );
    let all = sections(root, results)?;
    let passing = all.iter().filter(|s| s.state(code) == "pass").count();
    let _ = write!(
        h,
        "<p class={}><b>{} of {} sections pass on this code.</b> Rerun the others with <code>cargo xtask omega run --failed</code>.</p><table><tr><th>Lane</th><th>Section</th><th>State</th></tr>",
        if passing == all.len() { "ok" } else { "bad" },
        passing,
        all.len()
    );
    for s in &all {
        let st = s.state(code);
        let _ = write!(h, "<tr><td>{}</td><td>{}</td><td class={}>{}</td></tr>", s.lane.name, esc(&s.name), if st == "pass" { "ok" } else { "bad" }, st);
    }
    h.push_str("</table>");
    let never = without_success(&tier_b_cases(results));
    if !never.is_empty() {
        let _ = write!(h, "<p class=bad><b>{} commands have no successful case:</b> <code>{}</code></p>", never.len(), esc(&never.join(", ")));
    }
    for (version, cases) in &by_version {
        let mut outcomes: BTreeMap<&str, usize> = BTreeMap::new();
        for c in cases {
            *outcomes.entry(&c.outcome).or_default() += 1;
        }
        let failed: Vec<&Case> = cases.iter().filter(|c| !c.problems.is_empty()).collect();
        let commands: BTreeSet<&str> = cases.iter().map(|c| c.command.as_str()).collect();
        let worked: HashSet<&str> = cases.iter().filter(|c| c.outcome == "ok").map(|c| c.command.as_str()).collect();
        let never: Vec<&&str> = commands.iter().filter(|c| !worked.contains(**c)).collect();
        let minutes = cases.iter().map(|c| c.ms).sum::<u64>() / 60_000;
        let _ = write!(
            h,
            "<h2>{}</h2><p class={}><b>{}</b>: {} cases over {} commands, {} with problems, about {} min.</p><p>",
            esc(version),
            if failed.is_empty() { "ok" } else { "bad" },
            if failed.is_empty() { "Pass" } else { "Fail" },
            cases.len(),
            commands.len(),
            failed.len(),
            minutes
        );
        for (o, n) in &outcomes {
            let _ = write!(h, "{}: {n} &nbsp; ", esc(o));
        }
        h.push_str("</p>");

        // Problems, most common first.
        let mut kinds: BTreeMap<String, usize> = BTreeMap::new();
        for c in &failed {
            for p in &c.problems {
                *kinds.entry(p.split(':').next().unwrap_or(p).to_string()).or_default() += 1;
            }
        }
        let mut kinds: Vec<_> = kinds.into_iter().collect();
        kinds.sort_by_key(|k| std::cmp::Reverse(k.1));
        h.push_str("<h3>Problems by kind</h3><table><tr><th>Problem</th><th>Cases</th></tr>");
        for (k, n) in &kinds {
            let _ = write!(h, "<tr><td>{}</td><td>{n}</td></tr>", esc(k));
        }
        h.push_str("</table>");

        let _ = write!(h, "<h3>Commands that never worked on any document ({})</h3><p>", never.len());
        h.push_str("They likely need settings written by hand in OmegaCatalog.fixedParams.</p><p><code>");
        h.push_str(&never.iter().map(|c| esc(c)).collect::<Vec<_>>().join(", "));
        h.push_str("</code></p>");

        let mut fixtures: BTreeMap<&str, usize> = BTreeMap::new();
        for c in cases.iter().filter(|c| c.outcome == "fixture") {
            *fixtures.entry(&c.fixture).or_default() += 1;
        }
        let _ = write!(h, "<h3>Documents that couldn't be built ({})</h3><table>", fixtures.len());
        for (f, n) in &fixtures {
            let why = cases.iter().find(|c| c.fixture == *f && c.outcome == "fixture").and_then(|c| c.message.as_deref()).unwrap_or("");
            let _ = write!(h, "<tr><td><code>{}</code></td><td>{n} cases</td><td>{}</td></tr>", esc(f), esc(why));
        }
        h.push_str("</table>");

        let _ = write!(
            h,
            "<h3>Cases with problems ({})</h3><table><tr><th>Command</th><th>Document</th><th>Settings</th><th>Result</th><th>Problems</th></tr>",
            failed.len()
        );
        for c in failed.iter().take(2000) {
            let _ = write!(
                h,
                "<tr><td><code>{}</code></td><td><code>{}</code></td><td><code>{}</code></td><td>{}{}{}</td><td class=bad>{}</td></tr>",
                esc(&c.command),
                esc(&c.fixture),
                esc(&c.params),
                esc(&c.outcome),
                c.message.as_deref().map(|m| format!(": {}", esc(m))).unwrap_or_default(),
                c.undo_steps.map(|n| format!(" (undo {n})")).unwrap_or_default(),
                c.problems.iter().map(|p| esc(p)).collect::<Vec<_>>().join("<br>")
            );
        }
        h.push_str("</table>");

        let mut slow: Vec<&Case> = cases.iter().collect();
        slow.sort_by_key(|c| std::cmp::Reverse(c.ms));
        h.push_str("<h3>Slowest cases</h3><table>");
        for c in slow.iter().take(20) {
            let _ = write!(h, "<tr><td>{} ms</td><td><code>{}</code></td><td><code>{}</code></td></tr>", c.ms, esc(&c.command), esc(&c.id));
        }
        h.push_str("</table>");
    }
    if by_version.is_empty() {
        h.push_str("<p>No results yet: run <code>cargo xtask omega run</code>.</p>");
    }
    let page = out.join("index.html");
    std::fs::write(&page, h).map_err(|e| format!("{}: {e}", page.display()))?;
    Ok(page)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn section(status: Option<&str>, code: Option<&str>) -> Section {
        Section { lane: &LANES[0], name: "File".into(), status: status.map(String::from), code: code.map(String::from) }
    }

    #[test]
    fn a_section_passes_only_on_the_code_it_ran_on() {
        assert_eq!(section(Some("pass"), Some("abc")).state("abc"), "pass");
        assert_eq!(section(Some("pass"), Some("old")).state("abc"), "pass (older code)");
        assert_eq!(section(Some("fail"), Some("abc")).state("abc"), "fail");
        assert_eq!(section(None, Some("abc")).state("abc"), "crashed or stopped");
        assert_eq!(section(None, None).state("abc"), "not run");
    }

    #[test]
    fn every_command_needs_a_success_or_a_reason() {
        let case = |command: &str, outcome: &str| Case {
            id: String::new(),
            command: command.into(),
            fixture: String::new(),
            params: String::new(),
            outcome: outcome.into(),
            message: None,
            undo_steps: None,
            problems: Vec::new(),
            ms: 0,
        };
        let cases = [case("a", "refused"), case("a", "ok"), case("b", "refused"), case("session", "refused"), case("file.print.page", "refused")];
        assert_eq!(without_success(&cases), ["b"]);
    }

    #[test]
    fn lanes_name_their_simulators() {
        assert_eq!(simulator(LANES[5].destination), "iPad Pro 11-inch (M5)");
        assert!(LANES.iter().filter(|l| l.tier == Tier::B).count() == 2, "tier B runs on iOS 27 and 18");
        assert!(LANES.iter().all(|l| l.tier == Tier::D || l.destination.contains("OS=27.0") || l.destination.contains("OS=18.5")), "iOS 27 and 18 only");
    }

    #[test]
    fn walkthrough_classes_keep_their_own_names() {
        let s = Section { lane: &LANES[8], name: "Brush".into(), status: None, code: None };
        assert_eq!(s.class(), "BrushTests");
        assert_eq!(section(None, None).class(), "OmegaFileTests");
    }
}

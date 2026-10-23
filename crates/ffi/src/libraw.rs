//! Camera raw files through LibRaw (built from `submodules/LibRaw` with the wrapper in
//! `libraw.cpp`), for cameras and formats our own decoder doesn't read.

use std::ffi::{c_char, c_int, c_uint, c_ushort, c_void};

#[repr(C)]
struct PcRaw {
    rgb: *mut c_ushort,
    width: c_uint,
    height: c_uint,
    make: [c_char; 64],
    model: [c_char; 64],
}

#[repr(C)]
struct PcRawData {
    data: *mut c_ushort,
    width: c_uint,
    height: c_uint,
    channels: c_uint,
    black: c_uint,
    maximum: c_uint,
}

#[allow(unsafe_code)]
unsafe extern "C" {
    fn pc_libraw_develop(data: *const c_void, len: usize, out: *mut PcRaw, error: *mut c_char, error_len: usize) -> c_int;
    fn pc_libraw_raw(data: *const c_void, len: usize, out: *mut PcRawData, error: *mut c_char, error_len: usize) -> c_int;
    fn pc_libraw_free(rgb: *mut c_ushort);
}

/// LibRaw's unpacked sensor values, before any processing.
#[cfg_attr(not(test), allow(dead_code))]
pub struct Sensor {
    /// The stored size, margins included.
    pub width: u32,
    pub height: u32,
    /// 1 for a mosaic, 3 or 4 for linear raws.
    pub channels: u32,
    pub data: Vec<u16>,
    pub black: u32,
    pub maximum: u32,
}

/// The sensor values as LibRaw unpacks them (for checking our own decoder against it).
#[allow(unsafe_code)]
#[cfg_attr(not(test), allow(dead_code))]
pub fn sensor(bytes: &[u8]) -> Result<Sensor, String> {
    let mut out = PcRawData { data: std::ptr::null_mut(), width: 0, height: 0, channels: 0, black: 0, maximum: 0 };
    let mut error = [0 as c_char; 256];
    // SAFETY: as in `develop`: the buffers outlive the call, and `out` is filled only on success.
    let rc = unsafe { pc_libraw_raw(bytes.as_ptr().cast(), bytes.len(), &mut out, error.as_mut_ptr(), error.len()) };
    if rc != 0 {
        return Err(text(&error));
    }
    let n = (out.width as usize).checked_mul(out.height as usize).and_then(|p| p.checked_mul(out.channels as usize)).ok_or("the image is too large")?;
    // SAFETY: on success `out.data` holds width × height × channels samples the wrapper allocated.
    let data = unsafe { std::slice::from_raw_parts(out.data, n) }.to_vec();
    // SAFETY: `out.data` came from the wrapper's allocation and is not used again.
    unsafe { pc_libraw_free(out.data) };
    Ok(Sensor { width: out.width, height: out.height, channels: out.channels, data, black: out.black, maximum: out.maximum })
}

/// A raw developed to 16-bit ProPhoto RGB (gamma 1.8).
pub struct Developed {
    pub width: u32,
    pub height: u32,
    pub rgb: Vec<u16>,
    /// Make and model, when LibRaw knows them.
    pub camera: String,
}

#[allow(unsafe_code)]
pub fn develop(bytes: &[u8]) -> Result<Developed, String> {
    let mut out = PcRaw { rgb: std::ptr::null_mut(), width: 0, height: 0, make: [0; 64], model: [0; 64] };
    let mut error = [0 as c_char; 256];
    // SAFETY: `bytes`, `out` and `error` outlive the call; the wrapper writes at most
    // `error.len()` bytes (NUL included) into `error` and fills `out` only when it returns 0.
    let rc = unsafe { pc_libraw_develop(bytes.as_ptr().cast(), bytes.len(), &mut out, error.as_mut_ptr(), error.len()) };
    if rc != 0 {
        return Err(text(&error));
    }
    let n = (out.width as usize).checked_mul(out.height as usize).and_then(|p| p.checked_mul(3)).ok_or("the image is too large")?;
    // SAFETY: on success `out.rgb` holds width × height × 3 samples the wrapper allocated; it is
    // read once here and freed right after.
    let rgb = unsafe { std::slice::from_raw_parts(out.rgb, n) }.to_vec();
    // SAFETY: `out.rgb` came from the wrapper's allocation and is not used again.
    unsafe { pc_libraw_free(out.rgb) };
    let camera = format!("{} {}", text(&out.make), text(&out.model)).trim().to_string();
    Ok(Developed { width: out.width, height: out.height, rgb, camera })
}

/// A NUL-terminated C string in `buf`.
fn text(buf: &[c_char]) -> String {
    let bytes: Vec<u8> = buf.iter().take_while(|c| **c != 0).map(|c| *c as u8).collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Our raw decoder against LibRaw, sensor value by sensor value, on every file in
    /// corpus/pixls (`cargo xtask corpus --pixls`): where both read a file they must agree on
    /// every value (values at or above the white level count as equal: LibRaw doesn't clip a
    /// Sony curve's top, we do). Prints a table; skips without the corpus. `RAW_DIFF=1` prints
    /// the first differing values.
    #[test]
    fn our_raw_decoder_matches_libraw() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../corpus/pixls");
        let Ok(entries) = std::fs::read_dir(&dir) else {
            eprintln!("corpus/pixls is missing: run `cargo xtask corpus --pixls`");
            return;
        };
        let mut files: Vec<_> = entries.flatten().map(|e| e.path()).filter(|p| p.is_file()).collect();
        files.sort();
        let mut differ = Vec::new();
        for path in files {
            let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            let Ok(bytes) = std::fs::read(&path) else { continue };
            let theirs = sensor(&bytes);
            let ours = photocraft_raw::decode(&bytes, &photocraft_raw::Limits::default());
            let verdict = match (&ours, &theirs) {
                (Err(o), Err(t)) => format!("neither reads it (ours: {o}; LibRaw: {t})"),
                (Err(o), Ok(_)) => format!("LibRaw only (ours: {o})"),
                (Ok(_), Err(t)) => format!("ours only (LibRaw: {t})"),
                (Ok(o), Ok(t)) if (o.width, o.height, o.samples) != (t.width as usize, t.height as usize, t.channels as usize) => {
                    differ.push(name.clone());
                    format!("size or channels differ: ours {}×{}×{}, LibRaw {}×{}×{}", o.width, o.height, o.samples, t.width, t.height, t.channels)
                }
                (Ok(o), Ok(t)) => {
                    let lin = |v: u16| o.linearization.as_ref().and_then(|l| l.get(usize::from(v)).or_else(|| l.last()).copied()).unwrap_or(v);
                    let (mut same, mut max) = (0usize, 0u32);
                    let mut shown = 0;
                    for (i, (&a, &b)) in o.data.iter().zip(&t.data).enumerate() {
                        let top = u16::try_from(t.maximum).unwrap_or(u16::MAX);
                        let d = u32::from(lin(a).min(top).abs_diff(b.min(top)));
                        same += usize::from(d == 0);
                        max = max.max(d);
                        if d > 0 && shown < 8 && std::env::var_os("RAW_DIFF").is_some() {
                            shown += 1;
                            println!("  {name} ({}, {}): ours {} (stored {a}), LibRaw {b}", i % o.width, i / o.width, lin(a));
                        }
                    }
                    let share = same as f64 / o.data.len().max(1) as f64;
                    if same != o.data.len() {
                        differ.push(name.clone());
                    }
                    format!("{:.3}% identical, max difference {max} (LibRaw black {}, maximum {})", share * 100.0, t.black, t.maximum)
                }
            };
            println!("{name:52} {verdict}");
        }
        assert!(differ.is_empty(), "our raw decoder and LibRaw disagree on {differ:?}");
    }
}

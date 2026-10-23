//! Hole filling for Content-Aware Fill and Spot Healing: patch-based completion and texture
//! synthesis.
//!
//! * [`complete`], content-aware fill: the exemplar-based fill of [`crate::exemplar`].
//!
//!   PatchMatch, and the patch-voting completion built on it, were removed to avoid infringing
//!   Adobe's patents on them (US 8,571,328, US 8,811,749, US 8,861,868, US 9,396,530).
//! * [`synthesize`], create texture: patch-based texture synthesis in the style of A. Efros,
//!   W. Freeman, *Image Quilting for Texture Synthesis and Transfer*, SIGGRAPH 2001 (blocks picked from
//!   random candidates by overlap error, joined along minimum-error boundary cuts, so the texture is
//!   copied, never averaged).
//!
//! All functions take interleaved `w × h × ch` normalised floats (any colour model/depth) and a
//! `w × h` hole mask, and return a full buffer equal to the input outside the hole. They are
//! deterministic (fixed-seed hash RNG, results independent of thread count).

use std::borrow::Cow;

use crate::poisson::membrane_fill;

/// SplitMix64: tiny deterministic RNG.
#[derive(Clone)]
pub(crate) struct Rng(u64);
impl Rng {
    pub(crate) fn new(seed: u64) -> Self {
        Rng(seed ^ 0x9E37_79B9_7F4A_7C15)
    }
    pub(crate) fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}

/// How far copied content may be adjusted to its target, per channel: `gain · source + bias`, the
/// gain within `gain` and the bias within `±bias`. The fill uses only `bias`, as the most its
/// colour adaptation may move a value.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Adapt {
    pub gain: (f32, f32),
    pub bias: f32,
}

impl Adapt {
    /// Copies are taken as they are.
    pub const NONE: Adapt = Adapt { gain: (1.0, 1.0), bias: 0.0 };

    pub fn is_none(&self) -> bool {
        self.gain == (1.0, 1.0) && self.bias == 0.0
    }
}

impl Default for Adapt {
    fn default() -> Self {
        Self::NONE
    }
}

/// Parameters for [`complete`].
#[derive(Clone, Debug, PartialEq)]
pub struct CompleteParams {
    /// Patch radius (patches are `2r+1` square).
    pub patch_radius: usize,
    /// The fields below tuned the removed PatchMatch completion; the exemplar fill ignores them.
    /// EM iterations at the coarsest level (finer levels use fewer, down to `min_em_iters`).
    pub em_iters: usize,
    pub min_em_iters: usize,
    /// PatchMatch passes per EM iteration.
    pub pm_iters: usize,
    /// Levels where the hole is wider than this (in that level's pixels) only *refine* the
    /// scaled-up match field (one local PatchMatch pass and one vote), which keeps big holes
    /// tractable: the structure is decided at coarse scale, fine levels just add detail.
    pub refine_extent: usize,
    /// Colour adaptation of the copies.
    pub adapt: Adapt,
    pub seed: u64,
}

impl Default for CompleteParams {
    fn default() -> Self {
        Self { patch_radius: 3, em_iters: 10, min_em_iters: 3, pm_iters: 2, refine_extent: 192, adapt: Adapt::NONE, seed: 1 }
    }
}

/// What a pixel is to [`complete_masked`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Px {
    /// Not part of the image (a gap, or outside a transformed copy): ignored.
    Void,
    /// Known, part of the context the fill must agree with, but not copied from.
    Known,
    /// Known and may be copied from.
    Source,
    /// To be filled.
    Hole,
}

/// Summed-area table of a boolean grid (`(w+1) × (h+1)`). Not inlined: in [`synthesize`] it made
/// Create Texture's candidate loop slower (measured).
#[inline(never)]
fn integral(w: usize, h: usize, m: &[bool]) -> Vec<u32> {
    let mut s = vec![0u32; (w + 1) * (h + 1)];
    for y in 0..h {
        let mut row = 0u32;
        for x in 0..w {
            row += u32::from(m[y * w + x]);
            s[(y + 1) * (w + 1) + x + 1] = s[y * (w + 1) + x + 1] + row;
        }
    }
    s
}

/// Count of set cells in the clipped window `[x0, x1) × [y0, y1)`.
fn window_count(s: &[u32], gw: usize, gh: usize, x0: i32, y0: i32, x1: i32, y1: i32) -> u32 {
    let (x0, y0) = (x0.max(0) as usize, y0.max(0) as usize);
    let (x1, y1) = ((x1.max(0) as usize).min(gw), (y1.max(0) as usize).min(gh));
    if x1 <= x0 || y1 <= y0 {
        return 0;
    }
    let w1 = gw + 1;
    s[y1 * w1 + x1] + s[y0 * w1 + x0] - s[y0 * w1 + x1] - s[y1 * w1 + x0]
}

fn hole_bbox(w: usize, h: usize, hole: &[bool]) -> Option<(usize, usize, usize, usize)> {
    let mut b: Option<(usize, usize, usize, usize)> = None;
    for y in 0..h {
        for x in 0..w {
            if hole[y * w + x] {
                b = Some(match b {
                    None => (x, y, x + 1, y + 1),
                    Some((x0, y0, x1, y1)) => (x0.min(x), y0.min(y), x1.max(x + 1), y1.max(y + 1)),
                });
            }
        }
    }
    b
}

/// A channel deviation under which a patch counts as flat for [`fit`] (about 5 levels of 255).
const FLAT: f32 = 0.02;

/// Gain and bias of one channel for target moments `(Σt, Σt²)` and source moments `(Σs, Σs²)`
/// over `n` samples, within the limits.
#[inline]
pub(crate) fn fit(a: Adapt, n: f32, st: f32, stt: f32, ss: f32, sss: f32) -> (f32, f32) {
    let (mt, ms) = (st / n, ss / n);
    let vt = (stt / n - mt * mt).max(0.0);
    let vs = (sss / n - ms * ms).max(0.0);
    let g = if vs > 1e-10 { (vt / vs).sqrt() } else { 1.0 };
    let (mut lo, mut hi) = a.gain;
    // Nearly flat patches of about the same colour (their means within the bias of each other):
    // the ratio of their deviations is noise, so match the mean first, keeping the gain where the
    // bias can still bring the source's mean to the target's. Gained about zero, a gain at its
    // limit moved bright means further than the bias could bring back, and each channel by a
    // different amount: a tinted blotch in a smooth gradient. Textured patches, and flat ones
    // whose colours differ more (Content-Aware Move's Color), are fitted as before.
    if vt.max(vs) < FLAT * FLAT && (mt - ms).abs() <= a.bias && ms > 1e-6 {
        let (glo, ghi) = ((mt - a.bias) / ms, (mt + a.bias) / ms);
        if glo.max(lo) <= ghi.min(hi) {
            (lo, hi) = (glo.max(lo), ghi.min(hi));
        }
    }
    let g = g.clamp(lo, hi);
    let b = (mt - g * ms).clamp(-a.bias, a.bias);
    (g, b)
}

/// Content-aware completion of `hole` (see module docs), copying from any pixel outside it. Returns
/// `None` when there is no fully-known patch to copy from (the caller can fall back to
/// [`membrane_fill`]).
pub fn complete(w: usize, h: usize, ch: usize, img: &[f32], hole: &[bool], p: &CompleteParams) -> Option<Vec<f32>> {
    // Never cancelled, so never `Err`.
    complete_with(w, h, ch, img, hole, p, &photocraft_raster::Interrupt::NONE).unwrap_or(None)
}

/// [`complete`] that can be cancelled (checked every few patches)
/// and reports progress (by pyramid level). `Err(Cancelled)` when `ctl` was cancelled.
pub fn complete_with(
    w: usize,
    h: usize,
    ch: usize,
    img: &[f32],
    hole: &[bool],
    p: &CompleteParams,
    ctl: &photocraft_raster::Interrupt,
) -> Result<Option<Vec<f32>>, photocraft_raster::Cancelled> {
    assert_eq!(hole.len(), w * h);
    let px: Vec<Px> = hole.iter().map(|h| if *h { Px::Hole } else { Px::Source }).collect();
    complete_masked(w, h, ch, img, &px, p, ctl)
}

/// [`complete_with`] with every pixel's role given ([`Px`]): the hole, the context, what may be
/// copied, and what isn't image at all.
pub fn complete_masked(
    w: usize,
    h: usize,
    ch: usize,
    img: &[f32],
    px: &[Px],
    p: &CompleteParams,
    ctl: &photocraft_raster::Interrupt,
) -> Result<Option<Vec<f32>>, photocraft_raster::Cancelled> {
    Ok(complete_cow(w, h, ch, Cow::Borrowed(img), px, p, ctl)?.ok())
}

/// [`complete_masked`] that fills `img` itself instead of a copy of it (only the hole changes):
/// `Err(img)`, untouched, when there is nothing to copy from.
pub fn complete_masked_owned(
    w: usize,
    h: usize,
    ch: usize,
    img: Vec<f32>,
    px: &[Px],
    p: &CompleteParams,
    ctl: &photocraft_raster::Interrupt,
) -> Result<Result<Vec<f32>, Vec<f32>>, photocraft_raster::Cancelled> {
    Ok(complete_cow(w, h, ch, Cow::Owned(img), px, p, ctl)?.map_err(Cow::into_owned))
}

/// The completion, on the caller's pixels or a copy of them: `Err` gives them back when there is
/// nothing to copy from.
fn complete_cow<'a>(
    w: usize,
    h: usize,
    ch: usize,
    img: Cow<'a, [f32]>,
    px: &'a [Px],
    p: &CompleteParams,
    ctl: &photocraft_raster::Interrupt,
) -> Result<Result<Vec<f32>, Cow<'a, [f32]>>, photocraft_raster::Cancelled> {
    Ok(crate::exemplar::complete(w, h, ch, &img, px, p.adapt.bias, ctl)?.ok_or(img))
}

/// Create texture: fill the hole with blocks of surrounding texture (see module docs).
pub fn synthesize(w: usize, h: usize, ch: usize, img: &[f32], hole: &[bool], block: usize, seed: u64) -> Vec<f32> {
    let mut out = img.to_vec();
    let Some((bx0, by0, bx1, by1)) = hole_bbox(w, h, hole) else { return out };
    let b = block.max(4) as i32;
    let ov = (b / 3).max(1);
    let hs = integral(w, h, hole);
    // Candidate block origins: whole block (with overlap) inside the grid and outside the hole.
    let mut cands = Vec::new();
    for y in ov..(h as i32 - b - ov) {
        for x in ov..(w as i32 - b - ov) {
            if window_count(&hs, w, h, x - ov, y - ov, x + b + ov, y + b + ov) == 0 {
                cands.push((x, y));
            }
        }
    }
    if cands.is_empty() {
        return membrane_fill(w, h, ch, img, hole);
    }
    let mut filled: Vec<bool> = hole.iter().map(|x| !x).collect();
    let mut rng = Rng::new(seed);
    let mut by = by0 as i32;
    while by < by1 as i32 {
        let mut bx = bx0 as i32;
        while bx < bx1 as i32 {
            if window_count(&hs, w, h, bx, by, bx + b, by + b) > 0 {
                // Pick the candidate whose block best agrees with already-known pixels around/inside.
                let mut best = (cands[0], f32::INFINITY);
                for _ in 0..48 {
                    let c = cands[(rng.next() % cands.len() as u64) as usize];
                    let (mut e, mut n) = (0.0f32, 0u32);
                    for y in (by - ov)..(by + b + ov) {
                        for x in (bx - ov)..(bx + b + ov) {
                            if x < 0 || y < 0 || x >= w as i32 || y >= h as i32 || !filled[y as usize * w + x as usize] {
                                continue;
                            }
                            let (a, s) = ((y as usize * w + x as usize) * ch, ((y - by + c.1) as usize * w + (x - bx + c.0) as usize) * ch);
                            for k in 0..ch {
                                let d = out[a + k] - img[s + k];
                                e += d * d;
                            }
                            n += 1;
                        }
                    }
                    let e = if n == 0 { 0.0 } else { e / n as f32 };
                    if e < best.1 {
                        best = (c, e);
                    }
                }
                let c = best.0;
                let (x0, y0) = ((bx - ov).max(0), (by - ov).max(0));
                let (x1, y1) = ((bx + b + ov).min(w as i32), (by + b + ov).min(h as i32));
                let src = |x: i32, y: i32| ((y - by + c.1) as usize * w + (x - bx + c.0) as usize) * ch;
                // Squared difference between what is there and the block, where both exist.
                let err = |x: i32, y: i32| {
                    let i = y as usize * w + x as usize;
                    if !(hole[i] && filled[i]) {
                        return 0.0;
                    }
                    let (a, s) = (i * ch, src(x, y));
                    (0..ch).map(|q| (out[a + q] - img[s + q]).powi(2)).sum::<f32>()
                };
                // Minimum-error boundary cuts through the overlaps with the blocks to the left and
                // above: the block is copied right of and below them, untouched pixels are kept
                // on the other side. Copying (rather than averaging) keeps the texture's grain.
                let left = min_cut((x0..(bx + ov).min(x1)).len(), (y0..y1).len(), |u, v| err(x0 + u as i32, y0 + v as i32));
                let top = min_cut((y0..(by + ov).min(y1)).len(), (x0..x1).len(), |u, v| err(x0 + v as i32, y0 + u as i32));
                for y in y0..y1 {
                    for x in x0..x1 {
                        let i = y as usize * w + x as usize;
                        if !hole[i] {
                            continue;
                        }
                        let (u, v) = ((x - x0) as usize, (y - y0) as usize);
                        let keep = filled[i] && (left.get(v).is_some_and(|s| u < *s) || top.get(u).is_some_and(|s| v < *s));
                        if !keep {
                            let (a, s) = (i * ch, src(x, y));
                            out[a..a + ch].copy_from_slice(&img[s..s + ch]);
                        }
                        filled[i] = true;
                    }
                }
            }
            bx += b;
        }
        by += b;
    }
    out
}

/// The minimum-error cut through a band `across` wide and `along` long (Efros & Freeman's
/// boundary cut, by dynamic programming): for each step along the band, the offset across it
/// where the cut runs (`err(across, along)` is the cost of a pixel). Pixels before the cut keep
/// what is there. Empty when there is no cost anywhere (nothing to cut through).
fn min_cut(across: usize, along: usize, err: impl Fn(usize, usize) -> f32) -> Vec<usize> {
    if across == 0 || along == 0 {
        return Vec::new();
    }
    // Cumulative cost, step by step along the band; the cut may move by one pixel per step.
    let mut acc: Vec<f32> = (0..along).flat_map(|v| (0..across).map(move |u| (u, v))).map(|(u, v)| err(u, v)).collect();
    if acc.iter().all(|x| *x == 0.0) {
        return Vec::new();
    }
    for v in 1..along {
        for u in 0..across {
            let lo = u.saturating_sub(1);
            let hi = (u + 1).min(across - 1);
            let m = (lo..=hi).map(|k| acc[(v - 1) * across + k]).fold(f32::INFINITY, f32::min);
            acc[v * across + u] += m;
        }
    }
    let argmin = |v: usize, lo: usize, hi: usize| (lo..=hi).min_by(|a, b| acc[v * across + a].total_cmp(&acc[v * across + b])).unwrap_or(lo);
    let mut cut = vec![0; along];
    let mut u = argmin(along - 1, 0, across - 1);
    for v in (0..along).rev() {
        if v + 1 < along {
            u = argmin(v, u.saturating_sub(1), (u + 1).min(across - 1));
        }
        cut[v] = u;
    }
    cut
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The mean is matched first: on a nearly flat bright patch with a noisy deviation ratio the
    /// gain stays where the bias can still reach the target's mean.
    #[test]
    fn fit_matches_the_mean_before_the_contrast() {
        let a = Adapt { gain: (0.9, 1.1), bias: 0.04 };
        // Target mean 0.70, source mean 0.70; deviations 0.01 vs 0.004 (ratio 2.5).
        let n = 25.0;
        let (mt, ms, sdt, sds) = (0.70f32, 0.70f32, 0.01f32, 0.004f32);
        let (g, b) = fit(a, n, mt * n, (sdt * sdt + mt * mt) * n, ms * n, (sds * sds + ms * ms) * n);
        assert!((g * ms + b - mt).abs() < 1e-5, "mean {} vs {mt} (g {g}, b {b})", g * ms + b);
        // Where the mean can't be reached anyway, the limits hold as before.
        let (g, b) = fit(a, n, 0.2 * n, 0.04 * n, 0.9 * n, 0.81 * n);
        assert!((a.gain.0..=a.gain.1).contains(&g) && b.abs() <= a.bias + 1e-6);
    }

    /// Smooth gradient plus deterministic fine noise.
    fn texture(w: usize, h: usize) -> Vec<f32> {
        let mut rng = Rng::new(7);
        (0..w * h)
            .flat_map(|i| {
                let (x, y) = ((i % w) as f32, (i / w) as f32);
                let n = (rng.next() % 1000) as f32 / 1000.0 * 0.04 - 0.02;
                [0.3 + 0.004 * x + n, 0.5 + 0.002 * y + n, 0.4 + n]
            })
            .collect()
    }

    fn disc(w: usize, h: usize, cx: f32, cy: f32, r: f32) -> Vec<bool> {
        (0..w * h).map(|i| ((i % w) as f32 - cx).hypot((i / w) as f32 - cy) < r).collect()
    }

    fn hole_rmse(a: &[f32], b: &[f32], hole: &[bool], ch: usize) -> f32 {
        let (mut e, mut n) = (0.0f32, 0);
        for (i, hh) in hole.iter().enumerate() {
            if *hh {
                for c in 0..ch {
                    e += (a[i * ch + c] - b[i * ch + c]).powi(2);
                    n += 1;
                }
            }
        }
        (e / n as f32).sqrt()
    }

    #[test]
    fn completion_fills_blemish_from_texture() {
        let (w, h, ch) = (96, 96, 3);
        let clean = texture(w, h);
        let hole = disc(w, h, 48.0, 48.0, 9.0);
        let mut dirty = clean.clone();
        for (i, hh) in hole.iter().enumerate() {
            if *hh {
                dirty[i * ch..i * ch + ch].copy_from_slice(&[0.02, 0.02, 0.02]);
            }
        }
        let out = complete(w, h, ch, &dirty, &hole, &CompleteParams::default()).unwrap();
        let before = hole_rmse(&dirty, &clean, &hole, ch);
        let after = hole_rmse(&out, &clean, &hole, ch);
        assert!(after < 0.06 && after < before * 0.15, "rmse before {before} after {after}");
        // Outside the hole untouched.
        assert!(out.iter().zip(&dirty).zip(hole.iter().flat_map(|h| [*h; 3])).all(|((a, b), h)| h || a == b));
        // Deterministic.
        assert_eq!(out, complete(w, h, ch, &dirty, &hole, &CompleteParams::default()).unwrap());
    }

    #[test]
    fn completion_continues_structure() {
        // Vertical stripes: the filled hole should keep the stripes (not a blur).
        let (w, h, ch) = (80, 80, 1);
        let clean: Vec<f32> = (0..w * h).map(|i| if (i % w / 4) % 2 == 0 { 0.2 } else { 0.8 }).collect();
        let hole = disc(w, h, 40.0, 40.0, 7.0);
        let dirty: Vec<f32> = clean.iter().zip(&hole).map(|(c, h)| if *h { 0.5 } else { *c }).collect();
        let out = complete(w, h, ch, &dirty, &hole, &CompleteParams::default()).unwrap();
        let err = hole_rmse(&out, &clean, &hole, ch);
        assert!(err < 0.15, "{err}");
    }

    fn busy(w: usize, h: usize, ch: usize, seed: u64) -> Vec<f32> {
        let mut rng = Rng::new(seed);
        (0..w * h)
            .flat_map(|i| {
                let (x, y) = (i % w, i / w);
                let flat = (x / 9 + y / 7) % 5 == 0;
                let n = (rng.next() % 1000) as f32 / 1000.0;
                (0..ch)
                    .map(move |c| if flat { 0.25 + 0.1 * c as f32 } else { (0.2 + 0.004 * x as f32 + 0.1 * ((x + 2 * y + c) % 6) as f32 + 0.05 * n).min(1.0) })
            })
            .collect()
    }

    fn bits(v: &[f32]) -> Vec<u32> {
        v.iter().map(|x| x.to_bits()).collect()
    }

    /// Roles: a hole, a band that is context only, a corner that is no image.
    fn roles(w: usize, h: usize, hole: &[bool]) -> Vec<Px> {
        (0..w * h)
            .map(|i| {
                let (x, y) = (i % w, i / w);
                if hole[i] {
                    Px::Hole
                } else if x < 4 && y < 6 {
                    Px::Void
                } else if (w * 3 / 4..w * 3 / 4 + 3).contains(&x) {
                    Px::Known
                } else {
                    Px::Source
                }
            })
            .collect()
    }

    /// A long thin hole goes the thin way (a shallow pyramid that starts from a membrane): it is
    /// filled, only it changes, and the result does not depend on the thread count either.
    #[test]
    #[cfg(not(target_arch = "wasm32"))]
    fn thin_holes_are_filled_the_same_on_any_number_of_threads() {
        let (w, h) = (300, 200);
        let img = busy(w, h, 3, 5);
        // A wavy line 6 px thick across the image.
        let hole: Vec<bool> = (0..w * h).map(|i| (((i % w) as f32 * 0.05).sin() * 30.0 + 100.0 - (i / w) as f32).abs() < 3.0).collect();
        let px = roles(w, h, &hole);
        let run = |threads: usize| {
            let pool = rayon::ThreadPoolBuilder::new().num_threads(threads).build().unwrap();
            pool.install(|| complete_masked(w, h, 3, &img, &px, &CompleteParams::default(), &photocraft_raster::Interrupt::NONE)).unwrap().unwrap()
        };
        let one = run(1);
        assert_eq!(bits(&one), bits(&run(7)));
        assert!((0..w * h).all(|i| hole[i] || (0..3).all(|c| one[i * 3 + c].to_bits() == img[i * 3 + c].to_bits())));
        assert!((0..w * h).filter(|&i| hole[i]).all(|i| (0..3).all(|c| one[i * 3 + c].is_finite())));
    }

    #[test]
    #[cfg(not(target_arch = "wasm32"))]
    fn results_do_not_depend_on_the_thread_count() {
        // Big enough for the parallel passes.
        let (w, h) = (300, 260);
        for (ch, adapt) in [(3, Adapt::NONE), (4, Adapt { gain: (0.9, 1.1), bias: 0.04 })] {
            let img = busy(w, h, ch, 3);
            let hole = disc(w, h, 140.0, 130.0, 40.0);
            let px = roles(w, h, &hole);
            let p = CompleteParams { adapt, ..Default::default() };
            let run = |threads: usize| {
                let pool = rayon::ThreadPoolBuilder::new().num_threads(threads).build().unwrap();
                bits(&pool.install(|| complete_masked(w, h, ch, &img, &px, &p, &photocraft_raster::Interrupt::NONE)).unwrap().unwrap())
            };
            let one = run(1);
            assert_eq!(one, run(3), "{ch} channels, 3 threads");
            assert_eq!(one, run(16), "{ch} channels, 16 threads");
        }
    }

    #[test]
    fn owned_completion_fills_in_place_or_gives_the_pixels_back() {
        let (w, h, ch) = (64, 52, 3);
        let img = busy(w, h, ch, 6);
        let hole = disc(w, h, 30.0, 26.0, 8.0);
        let px = roles(w, h, &hole);
        let (p, none) = (CompleteParams::default(), photocraft_raster::Interrupt::NONE);
        let borrowed = complete_masked(w, h, ch, &img, &px, &p, &none).unwrap().unwrap();
        let owned = complete_masked_owned(w, h, ch, img.clone(), &px, &p, &none).unwrap().unwrap();
        assert_eq!(bits(&owned), bits(&borrowed));
        // Nothing may be copied: no completion, and the pixels come back as they were.
        let known: Vec<Px> = px.iter().map(|k| if *k == Px::Source { Px::Known } else { *k }).collect();
        assert!(complete_masked(w, h, ch, &img, &known, &p, &none).unwrap().is_none());
        let back = complete_masked_owned(w, h, ch, img.clone(), &known, &p, &none).unwrap().unwrap_err();
        assert_eq!(bits(&back), bits(&img));
        // Cancelled, it stops.
        let yes = || true;
        assert!(complete_masked_owned(w, h, ch, img, &px, &p, &photocraft_raster::Interrupt::cancel_only(&yes)).is_err());
    }

    #[test]
    fn synthesis_fills_hole_with_plausible_values() {
        let (w, h, ch) = (64, 64, 3);
        let clean = texture(w, h);
        let hole = disc(w, h, 32.0, 32.0, 6.0);
        let out = synthesize(w, h, ch, &clean, &hole, 8, 3);
        let err = hole_rmse(&out, &clean, &hole, ch);
        assert!(err < 0.15, "{err}");
        assert!(out.iter().all(|v| v.is_finite()));
    }
}

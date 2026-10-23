//! Content-aware scaling (Edit › Content-Aware Scale) by an axis-aligned warp: each column (then
//! each row) gets its own scale from how much detail it holds, so flat columns give up or take
//! the change in size and detailed ones keep theirs. Columns kept at their size are copied
//! exactly; the rest are resampled linearly.
//!
//! A protect map (`0..=1`, e.g. an alpha channel or detected skin tones) keeps the columns and
//! rows it covers at their size. Buffers are interleaved `w × h × ch` normalised floats of any
//! colour model and depth (alpha is carried like any other channel). Deterministic.

use photocraft_raster::{Cancelled, Interrupt};

use crate::par;

/// Importance added to a column a protect map covers: far above any normalised detail.
const PROTECT: f32 = 1000.0;
/// Importance every column has, so flat ones still scale smoothly.
const FLOOR: f32 = 0.02;
/// How far a column may scale beyond the uniform scale: 1/5 of it when shrinking, 3× when
/// enlarging.
const SHRINK_LIMIT: f32 = 0.2;
const GROW_LIMIT: f32 = 3.0;

/// Content-aware resize of `img` to `new_w × new_h` (width first, then height).
#[allow(clippy::too_many_arguments)]
pub fn retarget_with(
    w: usize,
    h: usize,
    ch: usize,
    img: &[f32],
    protect: Option<&[f32]>,
    new_w: usize,
    new_h: usize,
    ctl: &Interrupt,
) -> Result<Vec<f32>, Cancelled> {
    let (new_w, new_h) = (new_w.max(1), new_h.max(1));
    if w == 0 || h == 0 || ch == 0 || img.len() != w * h * ch {
        return Ok(vec![0.0; new_w * new_h * ch]);
    }
    let protect = protect.filter(|p| p.len() == w * h);
    ctl.check()?;
    let wide = if new_w == w { img.to_vec() } else { warp_width(w, h, ch, img, protect, new_w) };
    ctl.progress(0.5);
    if new_h == h {
        return Ok(wide);
    }
    ctl.check()?;
    // Protection follows the width change by plain resampling.
    let prot_t = protect.map(|p| transpose(new_w, h, 1, &resize_bilinear(w, h, 1, p, new_w, h)));
    let t = transpose(new_w, h, ch, &wide);
    let tall = warp_width(h, new_w, ch, &t, prot_t.as_deref(), new_h);
    ctl.progress(1.0);
    Ok(transpose(new_h, new_w, ch, &tall))
}

/// The scale of each column for a width change to `new_w`: their sum is `new_w`.
fn column_scales(w: usize, h: usize, ch: usize, img: &[f32], protect: Option<&[f32]>, new_w: usize) -> Vec<f32> {
    let ratio = new_w as f32 / w as f32;
    let mut imp: Vec<f32> = par::map(w, true, |x| {
        let mut s = 0.0f32;
        for y in 0..h {
            let at = |xx: usize, yy: usize, c: usize| img[(yy * w + xx) * ch + c];
            let (xl, xr) = (x.saturating_sub(1), (x + 1).min(w - 1));
            let (yu, yd) = (y.saturating_sub(1), (y + 1).min(h - 1));
            for c in 0..ch {
                let v = at(x, y, c);
                s += (at(xr, y, c) - v).abs() + (v - at(xl, y, c)).abs() + (at(x, yd, c) - v).abs() + (v - at(x, yu, c)).abs();
            }
        }
        s / h as f32
    });
    let top = imp.iter().copied().fold(0.0f32, f32::max);
    for (x, v) in imp.iter_mut().enumerate() {
        *v = if top > 1e-6 { *v / top } else { 0.0 } + FLOOR;
        if let Some(p) = protect
            && (0..h).any(|y| p[y * w + x] > 0.5)
        {
            *v += PROTECT;
        }
    }
    // Shrinking: scale = k·importance within [limit·ratio, 1]. Enlarging: k / importance within
    // [1, limit·ratio]. Both sums grow with k; find the k that gives `new_w`.
    let shrink = new_w < w;
    let scale = |k: f32, v: f32| if shrink { (k * v).clamp(SHRINK_LIMIT * ratio, 1.0) } else { (k / v).clamp(1.0, GROW_LIMIT * ratio) };
    let (mut lo, mut hi) = (0.0f32, if shrink { 1.0 / FLOOR } else { (GROW_LIMIT * ratio) * (1.0 + PROTECT) });
    for _ in 0..60 {
        let k = 0.5 * (lo + hi);
        let sum: f32 = imp.iter().map(|v| scale(k, *v)).sum();
        if sum < new_w as f32 {
            lo = k;
        } else {
            hi = k;
        }
    }
    imp.iter().map(|v| scale(hi, *v)).collect()
}

fn warp_width(w: usize, h: usize, ch: usize, img: &[f32], protect: Option<&[f32]>, new_w: usize) -> Vec<f32> {
    let s = column_scales(w, h, ch, img, protect, new_w);
    // Each output column's source: two columns and the weight of the second.
    let mut from = Vec::with_capacity(new_w);
    let (mut x, mut edge) = (0usize, 0.0f32);
    for ox in 0..new_w {
        let c = ox as f32 + 0.5;
        while x + 1 < w && edge + s[x] <= c {
            edge += s[x];
            x += 1;
        }
        if (s[x] - 1.0).abs() < 1e-4 {
            from.push((x, x, 0.0));
            continue;
        }
        let u = (x as f32 + ((c - edge) / s[x]).clamp(0.0, 1.0) - 0.5).clamp(0.0, (w - 1) as f32);
        let x0 = u.floor() as usize;
        from.push((x0, (x0 + 1).min(w - 1), u - x0 as f32));
    }
    let mut out = vec![0.0f32; new_w * h * ch];
    par::chunks_mut(&mut out, new_w * ch, true, |y, row| {
        let src = &img[y * w * ch..(y + 1) * w * ch];
        for (ox, &(x0, x1, t)) in from.iter().enumerate() {
            for c in 0..ch {
                let (a, b) = (src[x0 * ch + c], src[x1 * ch + c]);
                row[ox * ch + c] = a + (b - a) * t;
            }
        }
    });
    out
}

fn transpose(w: usize, h: usize, ch: usize, img: &[f32]) -> Vec<f32> {
    let mut out = vec![0.0f32; img.len()];
    for y in 0..h {
        for x in 0..w {
            let (s, d) = ((y * w + x) * ch, (x * h + y) * ch);
            out[d..d + ch].copy_from_slice(&img[s..s + ch]);
        }
    }
    out
}

/// Plain bilinear resize (the non-content-aware part of the Amount blend).
pub fn resize_bilinear(w: usize, h: usize, ch: usize, img: &[f32], nw: usize, nh: usize) -> Vec<f32> {
    let mut out = vec![0.0f32; nw * nh * ch];
    if w == 0 || h == 0 || img.len() != w * h * ch {
        return out;
    }
    for y in 0..nh {
        let fy = ((y as f32 + 0.5) * h as f32 / nh as f32 - 0.5).clamp(0.0, (h - 1) as f32);
        let (y0, ty) = (fy.floor() as usize, fy.fract());
        let y1 = (y0 + 1).min(h - 1);
        for x in 0..nw {
            let fx = ((x as f32 + 0.5) * w as f32 / nw as f32 - 0.5).clamp(0.0, (w - 1) as f32);
            let (x0, tx) = (fx.floor() as usize, fx.fract());
            let x1 = (x0 + 1).min(w - 1);
            for c in 0..ch {
                let p = |xx: usize, yy: usize| img[(yy * w + xx) * ch + c];
                let top = p(x0, y0) + (p(x1, y0) - p(x0, y0)) * tx;
                let bot = p(x0, y1) + (p(x1, y1) - p(x0, y1)) * tx;
                out[(y * nw + x) * ch + c] = top + (bot - top) * ty;
            }
        }
    }
    out
}

/// Skin-tone protection map (1 = skin) for RGB(A) buffers: the explicit RGB rule of
/// J. Kovač, P. Peer, F. Solina, *Human Skin Colour Clustering for Face Detection*, EUROCON 2003.
pub fn skin_mask(w: usize, h: usize, ch: usize, img: &[f32]) -> Vec<f32> {
    let mut m = vec![0.0f32; w * h];
    if ch < 3 || img.len() < w * h * ch {
        return m;
    }
    for (i, v) in m.iter_mut().enumerate() {
        let p = &img[i * ch..i * ch + 3];
        let (r, g, b) = (p[0] * 255.0, p[1] * 255.0, p[2] * 255.0);
        let (mx, mn) = (r.max(g).max(b), r.min(g).min(b));
        if r > 95.0 && g > 40.0 && b > 20.0 && mx - mn > 15.0 && (r - g).abs() > 15.0 && r > g && r > b {
            *v = 1.0;
        }
    }
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(w: usize, h: usize, img: &[f32], protect: Option<&[f32]>, nw: usize, nh: usize) -> Vec<f32> {
        retarget_with(w, h, 1, img, protect, nw, nh, &Interrupt::NONE).unwrap()
    }

    /// A detailed band on a flat ground: the ground gives up the width, the band is copied.
    #[test]
    fn shrinking_keeps_the_detailed_band() {
        let (w, h) = (40, 12);
        let img: Vec<f32> = (0..w * h).map(|i| if (10..16).contains(&(i % w)) { ((i % w) % 2) as f32 } else { 0.5 }).collect();
        let out = run(w, h, &img, None, 24, h);
        assert_eq!(out.len(), 24 * h);
        let row = &out[..24];
        assert_eq!(row.iter().filter(|v| **v == 0.0 || **v == 1.0).count(), 6, "{row:?}");
    }

    #[test]
    fn enlarging_stretches_flat_areas_and_protection_holds() {
        let (w, h) = (30, 8);
        let img: Vec<f32> = (0..w * h).map(|i| if i % w < 10 { ((i % w) % 2) as f32 } else { 0.5 }).collect();
        let out = run(w, h, &img, None, 45, h);
        assert_eq!(&out[..10], &img[..10], "the detail keeps its size");
        // Protected flat columns keep theirs too; the unprotected ones take the change.
        let protect: Vec<f32> = (0..w * h).map(|i| if (10..20).contains(&(i % w)) { 1.0 } else { 0.0 }).collect();
        let s = column_scales(w, h, 1, &img, Some(&protect), 45);
        assert!(s[..20].iter().all(|v| *v == 1.0), "{s:?}");
        assert!((s.iter().sum::<f32>() - 45.0).abs() < 0.01);
    }

    #[test]
    fn height_lines_and_bad_input() {
        // Height goes through the same warp; a 1 px line repeats.
        let out = run(1, 6, &[1.0; 6], None, 4, 3);
        assert_eq!(out, vec![1.0; 12]);
        assert_eq!(run(0, 4, &[], None, 3, 2), vec![0.0; 6]);
        assert_eq!(run(2, 2, &[0.0; 3], None, 1, 1), vec![0.0]);
    }

    #[test]
    fn cancelled_stops() {
        let cancel = || true;
        let ctl = Interrupt::cancel_only(&cancel);
        assert!(retarget_with(8, 8, 1, &[0.0; 64], None, 4, 4, &ctl).is_err());
    }

    #[test]
    fn skin_rule() {
        let px = [0.86f32, 0.62, 0.5, 0.2, 0.4, 0.8];
        assert_eq!(skin_mask(2, 1, 3, &px), vec![1.0, 0.0]);
    }
}

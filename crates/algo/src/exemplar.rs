//! Exemplar-based hole filling: the hole is filled patch by patch from its edge inwards, strong
//! edges first, each patch copied from the best-matching fully-known patch outside the hole.
//! A large hole is first filled on a small copy of the image, searching all of it. Each larger
//! size then fills its hole again by the same process, with the smaller fill, scaled up, used
//! only as guide colours for the pixels not filled yet. That search looks up a few candidate
//! patches by their 3×3 block averages in a k-d tree, then keeps the closest by full patch
//! distance.
//!
//! Colour adaptation (`shift`) is Poisson seamless cloning (Pérez et al. 2003, as in
//! [`crate::poisson`]): where the copies meet the hole's edge, the difference between the edge and
//! what the copied source had next to it is spread smoothly over the hole, at most `shift` per
//! channel.

use std::cmp::Ordering;
use std::collections::BinaryHeap;

use photocraft_raster::{Cancelled, Interrupt};

use crate::inpaint::Px;

/// Patch radius (patches are `2R+1` square).
const R: i64 = 4;
/// The coarsest level's hole is at most this many pixels across.
const COARSE_HOLE: usize = 48;
/// Weight of a guide colour against a known pixel's in patch distances.
const GUIDE: f32 = 0.3;
/// At most this many patches go in the search tree (the rest are reached on a stride).
const MAX_POINTS: usize = 250_000;
/// Candidates a tree lookup returns, and how many tree points it may visit.
const CANDIDATES: usize = 8;
const VISITS: usize = 400;

/// Fill the `Px::Hole` pixels of `img` (`ch` channels per pixel). `Known` pixels guide the match,
/// `Source` pixels may also be copied, `Void` is ignored. `Ok(None)` when no patch is fully
/// copyable. `shift` is the most colour adaptation may move a value (0: copies are exact).
pub fn complete(w: usize, h: usize, ch: usize, img: &[f32], px: &[Px], shift: f32, ctl: &Interrupt) -> Result<Option<Vec<f32>>, Cancelled> {
    let n = w.saturating_mul(h);
    if ch == 0 || px.len() != n || img.len() != n.saturating_mul(ch) {
        return Ok(Some(img.to_vec()));
    }
    let Some((x0, y0, x1, y1)) = bounds(w, px) else { return Ok(Some(img.to_vec())) };
    let side = (2 * R + 1) as usize;
    let mut levels = vec![Level { w, h, img: img.to_vec(), px: px.to_vec() }];
    let mut extent = (x1 - x0).max(y1 - y0);
    while extent > COARSE_HOLE {
        let Some(last) = levels.last() else { break };
        if last.w < 4 * side || last.h < 4 * side {
            break;
        }
        ctl.check()?;
        let next = last.half(ch);
        levels.push(next);
        extent /= 2;
    }
    let mut guide: Option<Vec<f32>> = None;
    while let Some(mut level) = levels.pop() {
        ctl.check()?;
        let Some(s) = level.fill(ch, guide.as_deref(), ctl)? else { return Ok(None) };
        let Some(next) = levels.last() else {
            if shift > 0.0 {
                ctl.check()?;
                adapt(w, h, ch, &mut level.img, px, &s, shift);
            }
            return Ok(Some(level.img));
        };
        guide = Some(level.upsample(ch, next.w, next.h));
    }
    Ok(None)
}

/// Colour adaptation of a finished fill whose pixel `i` was copied from `src[i]`.
fn adapt(w: usize, h: usize, ch: usize, img: &mut [f32], px: &[Px], src: &[u32], shift: f32) {
    let Some((x0, y0, x1, y1)) = bounds(w, px) else { return };
    // The crop: the hole's bounds and a pixel around them.
    let (cx, cy) = (x0.saturating_sub(1), y0.saturating_sub(1));
    let (cw, chh) = ((x1 + 1).min(w) - cx, (y1 + 1).min(h) - cy);
    let mut sum = vec![0.0f32; cw * chh * ch];
    let mut count = vec![0u32; cw * chh];
    for y in y0..y1 {
        for x in x0..x1 {
            let i = y * w + x;
            let Some(&j) = src.get(i).filter(|j| **j != u32::MAX && px[i] == Px::Hole) else { continue };
            let (sx, sy) = ((j as usize % w) as i64, (j as usize / w) as i64);
            for (dx, dy) in [(1i64, 0i64), (-1, 0), (0, 1), (0, -1)] {
                let (qx, qy, tx, ty) = (x as i64 + dx, y as i64 + dy, sx + dx, sy + dy);
                if qx < 0 || qy < 0 || tx < 0 || ty < 0 || qx >= w as i64 || qy >= h as i64 || tx >= w as i64 || ty >= h as i64 {
                    continue;
                }
                let (q, t) = (qy as usize * w + qx as usize, ty as usize * w + tx as usize);
                if matches!(px[q], Px::Hole | Px::Void) {
                    continue;
                }
                let c = (qy as usize - cy) * cw + (qx as usize - cx);
                for k in 0..ch {
                    sum[c * ch + k] += img[q * ch + k] - img[t * ch + k];
                }
                count[c] += 1;
            }
        }
    }
    let free: Vec<bool> = count.iter().map(|n| *n == 0).collect();
    if free.iter().all(|f| *f) {
        return;
    }
    for k in 0..ch {
        let mut v: Vec<f32> = (0..cw * chh).map(|c| if count[c] > 0 { sum[c * ch + k] / count[c] as f32 } else { 0.0 }).collect();
        crate::poisson::solve_membrane(cw, chh, &free, &mut v);
        for (c, d) in v.iter().enumerate() {
            let i = (cy + c / cw) * w + cx + c % cw;
            if px[i] == Px::Hole {
                img[i * ch + k] += d.clamp(-shift, shift);
            }
        }
    }
}

fn bounds(w: usize, px: &[Px]) -> Option<(usize, usize, usize, usize)> {
    let mut b: Option<(usize, usize, usize, usize)> = None;
    for (i, p) in px.iter().enumerate() {
        if *p == Px::Hole {
            let (x, y) = (i % w, i / w);
            b = Some(b.map_or((x, y, x + 1, y + 1), |(a, c, d, e)| (a.min(x), c.min(y), d.max(x + 1), e.max(y + 1))));
        }
    }
    b
}

/// A fill-front pixel's priority (higher first); `version` drops stale entries.
struct Front {
    priority: f32,
    at: usize,
    version: u32,
}

impl PartialEq for Front {
    fn eq(&self, o: &Self) -> bool {
        self.priority.total_cmp(&o.priority) == Ordering::Equal
    }
}
impl Eq for Front {}
impl PartialOrd for Front {
    fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}
impl Ord for Front {
    fn cmp(&self, o: &Self) -> Ordering {
        self.priority.total_cmp(&o.priority).then(o.at.cmp(&self.at))
    }
}

struct Level {
    w: usize,
    h: usize,
    img: Vec<f32>,
    px: Vec<Px>,
}

/// What the fill knows while it runs.
struct State {
    known: Vec<bool>,
    conf: Vec<f32>,
    version: Vec<u32>,
    heap: BinaryHeap<Front>,
}

impl Level {
    /// Half size: a 2×2 block is a hole if any of it is, copyable if all of it is, ignored if all
    /// of it is, known otherwise.
    fn half(&self, ch: usize) -> Level {
        let (w, h) = (self.w.div_ceil(2), self.h.div_ceil(2));
        let mut img = vec![0.0; w * h * ch];
        let mut px = vec![Px::Void; w * h];
        let mut sum = vec![0.0f32; ch];
        for y in 0..h {
            for x in 0..w {
                sum.iter_mut().for_each(|s| *s = 0.0);
                let mut n = 0.0f32;
                let (mut hole, mut all_source, mut all_void) = (false, true, true);
                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    let (fx, fy) = (2 * x + dx, 2 * y + dy);
                    if fx >= self.w || fy >= self.h {
                        continue;
                    }
                    let i = fy * self.w + fx;
                    let p = self.px[i];
                    hole |= p == Px::Hole;
                    all_source &= p == Px::Source;
                    all_void &= p == Px::Void;
                    if matches!(p, Px::Known | Px::Source) {
                        for (c, s) in sum.iter_mut().enumerate() {
                            *s += self.img[i * ch + c];
                        }
                        n += 1.0;
                    }
                }
                let o = y * w + x;
                px[o] = if hole {
                    Px::Hole
                } else if all_void {
                    Px::Void
                } else if all_source {
                    Px::Source
                } else {
                    Px::Known
                };
                if n > 0.0 {
                    for (c, s) in sum.iter().enumerate() {
                        img[o * ch + c] = s / n;
                    }
                }
            }
        }
        Level { w, h, img, px }
    }

    fn inside(&self, x: i64, y: i64) -> bool {
        x >= 0 && y >= 0 && x < self.w as i64 && y < self.h as i64
    }

    /// Fill this level's hole. `guide`: colours for the hole (from a smaller fill), matched where
    /// nothing is known yet; without one the whole level is searched exhaustively. Returns where
    /// each pixel was copied from.
    fn fill(&mut self, ch: usize, guide: Option<&[f32]>, ctl: &Interrupt) -> Result<Option<Vec<u32>>, Cancelled> {
        let (w, h) = (self.w, self.h);
        let copyable = self.copyable_centres();
        if !copyable.iter().any(|c| *c) {
            return Ok(None);
        }
        let guide = guide.filter(|g| g.len() == self.img.len());
        let tree = match guide {
            Some(_) => Some(self.index(ch, &copyable, ctl)?),
            None => None,
        };
        let known: Vec<bool> = self.px.iter().map(|p| matches!(p, Px::Known | Px::Source)).collect();
        let conf = known.iter().map(|k| if *k { 1.0 } else { 0.0 }).collect();
        let mut st = State { known, conf, version: vec![0; w * h], heap: BinaryHeap::new() };
        for i in 0..w * h {
            self.push_if_front(ch, i, &mut st);
        }
        let mut src = vec![u32::MAX; w * h];
        let mut steps = 0usize;
        while let Some(f) = st.heap.pop() {
            if st.known[f.at] || f.version != st.version[f.at] {
                continue;
            }
            steps += 1;
            if steps.is_multiple_of(64) {
                ctl.check()?;
            }
            let t = f.at;
            let found = match (guide, &tree) {
                (Some(g), Some(tree)) => self.guided_source(ch, t, &st.known, &copyable, g, tree),
                _ => self.best_source(ch, t, &st.known, &copyable),
            };
            let Some(s) = found else { break };
            let c = self.patch_confidence(t, &st);
            let (tx, ty) = ((t % w) as i64, (t / w) as i64);
            let (sx, sy) = ((s % w) as i64, (s / w) as i64);
            for dy in -R..=R {
                for dx in -R..=R {
                    let (x, y) = (tx + dx, ty + dy);
                    if !self.inside(x, y) {
                        continue;
                    }
                    let i = y as usize * w + x as usize;
                    if st.known[i] || self.px[i] != Px::Hole {
                        continue;
                    }
                    let j = (sy + dy) as usize * w + (sx + dx) as usize;
                    for k in 0..ch {
                        self.img[i * ch + k] = self.img[j * ch + k];
                    }
                    st.known[i] = true;
                    st.conf[i] = c;
                    src[i] = j as u32;
                }
            }
            // The front moved: priorities around the patch change.
            for dy in -(2 * R + 1)..=2 * R + 1 {
                for dx in -(2 * R + 1)..=2 * R + 1 {
                    let (x, y) = (tx + dx, ty + dy);
                    if self.inside(x, y) {
                        self.push_if_front(ch, y as usize * w + x as usize, &mut st);
                    }
                }
            }
        }
        // What the copies couldn't reach (no copyable patch nearby) takes its nearest neighbour.
        if self.px.iter().zip(&st.known).any(|(p, k)| *p == Px::Hole && !k) {
            self.spread(ch, &mut st.known);
        }
        Ok(Some(src))
    }

    fn push_if_front(&self, ch: usize, i: usize, st: &mut State) {
        if st.known[i] || self.px[i] != Px::Hole {
            return;
        }
        let (x, y) = ((i % self.w) as i64, (i / self.w) as i64);
        let front =
            [(1, 0), (-1, 0), (0, 1), (0, -1)].iter().any(|(dx, dy)| self.inside(x + dx, y + dy) && st.known[(y + dy) as usize * self.w + (x + dx) as usize]);
        if !front {
            return;
        }
        st.version[i] = st.version[i].wrapping_add(1);
        let priority = self.patch_confidence(i, st) * (self.data_term(ch, i, &st.known) + 0.001);
        st.heap.push(Front { priority, at: i, version: st.version[i] });
    }

    /// Hole pixels nothing was copied to take a known neighbour's value, pass by pass.
    fn spread(&mut self, ch: usize, known: &mut [bool]) {
        let w = self.w;
        loop {
            let mut changed = false;
            for i in 0..w * self.h {
                if known[i] || self.px[i] != Px::Hole {
                    continue;
                }
                let (x, y) = ((i % w) as i64, (i / w) as i64);
                let from = [(1, 0), (-1, 0), (0, 1), (0, -1)]
                    .iter()
                    .map(|(dx, dy)| (x + dx, y + dy))
                    .find(|&(nx, ny)| self.inside(nx, ny) && known[ny as usize * w + nx as usize]);
                if let Some((nx, ny)) = from {
                    let j = ny as usize * w + nx as usize;
                    for k in 0..ch {
                        self.img[i * ch + k] = self.img[j * ch + k];
                    }
                    known[i] = true;
                    changed = true;
                }
            }
            if !changed {
                break;
            }
        }
    }

    /// Centres whose whole patch is copyable (`Source`), from a summed-area table.
    fn copyable_centres(&self) -> Vec<bool> {
        let (w, h) = (self.w, self.h);
        let stride = w + 1;
        let mut sat = vec![0u32; stride * (h + 1)];
        for y in 0..h {
            for x in 0..w {
                let v = u32::from(self.px[y * w + x] == Px::Source);
                sat[(y + 1) * stride + x + 1] = v + sat[y * stride + x + 1] + sat[(y + 1) * stride + x] - sat[y * stride + x];
            }
        }
        let r = R as usize;
        let full = ((2 * r + 1) * (2 * r + 1)) as u32;
        let mut out = vec![false; w * h];
        for y in r..h.saturating_sub(r) {
            for x in r..w.saturating_sub(r) {
                let (a, b, c, d) = (x - r, y - r, x + r + 1, y + r + 1);
                let n = sat[d * stride + c] + sat[b * stride + a] - sat[b * stride + c] - sat[d * stride + a];
                out[y * w + x] = n == full;
            }
        }
        out
    }

    /// How much of the patch around `t` is known, weighted by how sure each pixel is.
    fn patch_confidence(&self, t: usize, st: &State) -> f32 {
        let (tx, ty) = ((t % self.w) as i64, (t / self.w) as i64);
        let (mut sum, mut n) = (0.0, 0.0);
        for y in (ty - R).max(0)..=(ty + R).min(self.h as i64 - 1) {
            for x in (tx - R).max(0)..=(tx + R).min(self.w as i64 - 1) {
                let i = y as usize * self.w + x as usize;
                if self.px[i] == Px::Void {
                    continue;
                }
                if st.known[i] {
                    sum += st.conf[i];
                }
                n += 1.0;
            }
        }
        if n > 0.0 { sum / n } else { 0.0 }
    }

    /// How strongly an edge runs into the hole at `i`: the luminance gradient, turned along the
    /// edge, against the direction to the known neighbour.
    fn data_term(&self, ch: usize, i: usize, known: &[bool]) -> f32 {
        let w = self.w;
        let (x, y) = ((i % w) as i64, (i / w) as i64);
        let k = ch.min(3);
        let lum = |x: i64, y: i64| -> Option<f32> {
            if !self.inside(x, y) {
                return None;
            }
            let j = y as usize * w + x as usize;
            known[j].then(|| self.img[j * ch..j * ch + k].iter().sum::<f32>() / k as f32)
        };
        let diff = |a: Option<f32>, b: Option<f32>, c: f32| match (a, b) {
            (Some(a), Some(b)) => (b - a) / 2.0,
            (Some(a), None) => c - a,
            (None, Some(b)) => b - c,
            _ => 0.0,
        };
        let mut best = 0.0f32;
        for (ox, oy) in [(1i64, 0i64), (-1, 0), (0, 1), (0, -1)] {
            let (kx, ky) = (x + ox, y + oy);
            let Some(c) = lum(kx, ky) else { continue };
            let gx = diff(lum(kx - 1, ky), lum(kx + 1, ky), c);
            let gy = diff(lum(kx, ky - 1), lum(kx, ky + 1), c);
            // Edge direction (-gy, gx) against the front's normal (ox, oy).
            best = best.max((-gy * ox as f32 + gx * oy as f32).abs());
        }
        best
    }

    /// The target patch around `t`: each pixel's offset and weight, and its values (known, or
    /// else its guide colour at a lower weight).
    fn target(&self, ch: usize, t: usize, known: &[bool], guide: Option<&[f32]>) -> (Vec<(i64, i64, f32)>, Vec<f32>) {
        let w = self.w;
        let (tx, ty) = ((t % w) as i64, (t / w) as i64);
        let mut taps = Vec::with_capacity(((2 * R + 1) * (2 * R + 1)) as usize);
        let mut vals = Vec::with_capacity(taps.capacity() * ch);
        for dy in -R..=R {
            for dx in -R..=R {
                let (x, y) = (tx + dx, ty + dy);
                if !self.inside(x, y) {
                    continue;
                }
                let i = y as usize * w + x as usize;
                let (weight, from) = match guide {
                    _ if known[i] => (1.0, &self.img[..]),
                    Some(g) if self.px[i] == Px::Hole => (GUIDE, g),
                    _ => continue,
                };
                let Some(v) = from.get(i * ch..(i + 1) * ch) else { continue };
                taps.push((dx, dy, weight));
                vals.extend_from_slice(v);
            }
        }
        (taps, vals)
    }

    /// Weighted squared distance from the target patch to the copyable patch at `s`; stops once
    /// past `limit`.
    fn cost(&self, ch: usize, taps: &[(i64, i64, f32)], vals: &[f32], s: usize, limit: f32) -> f32 {
        let (sx, sy) = ((s % self.w) as i64, (s / self.w) as i64);
        let mut d = 0.0;
        for (n, &(dx, dy, weight)) in taps.iter().enumerate() {
            let j = (sy + dy) as usize * self.w + (sx + dx) as usize;
            let mut e2 = 0.0;
            for k in 0..ch {
                let e = vals[n * ch + k] - self.img[j * ch + k];
                e2 += e * e;
            }
            d += weight * e2;
            if d >= limit {
                break;
            }
        }
        d
    }

    /// The copyable patch most like the target's known part, searching every one.
    fn best_source(&self, ch: usize, t: usize, known: &[bool], copyable: &[bool]) -> Option<usize> {
        let (w, h) = (self.w, self.h);
        let (taps, vals) = self.target(ch, t, known, None);
        let per_row = crate::par::map(h, h > 16, |y| {
            let mut best: Option<(f32, usize)> = None;
            for (s, _) in copyable.iter().enumerate().skip(y * w).take(w).filter(|(_, c)| **c) {
                let c = self.cost(ch, &taps, &vals, s, best.map_or(f32::INFINITY, |b| b.0));
                if best.is_none_or(|(b, _)| c < b) {
                    best = Some((c, s));
                }
            }
            best
        });
        per_row.into_iter().flatten().min_by(|a, b| a.0.total_cmp(&b.0)).map(|(_, s)| s)
    }

    /// The best of a few tree candidates (and their neighbours between stride points) for the
    /// target patch with its guide colours.
    fn guided_source(&self, ch: usize, t: usize, known: &[bool], copyable: &[bool], guide: &[f32], tree: &Tree) -> Option<usize> {
        let (taps, vals) = self.target(ch, t, known, Some(guide));
        let q = describe(ch, &taps, &vals);
        let r = (tree.stride / 2) as i64;
        let mut best: Option<(f32, usize)> = None;
        for c in tree.nearest(&q, CANDIDATES, VISITS) {
            let (cx, cy) = ((c as usize % self.w) as i64, (c as usize / self.w) as i64);
            for y in cy - r..=cy + r {
                for x in cx - r..=cx + r {
                    if !self.inside(x, y) {
                        continue;
                    }
                    let s = y as usize * self.w + x as usize;
                    if !copyable[s] {
                        continue;
                    }
                    let d = self.cost(ch, &taps, &vals, s, best.map_or(f32::INFINITY, |b| b.0));
                    if best.is_none_or(|(b, _)| d < b) {
                        best = Some((d, s));
                    }
                }
            }
        }
        best.map(|(_, s)| s)
    }

    /// A search tree of the copyable patches' descriptors, on a stride when there are many.
    fn index(&self, ch: usize, copyable: &[bool], ctl: &Interrupt) -> Result<Tree, Cancelled> {
        let (w, h) = (self.w, self.h);
        let n = copyable.iter().filter(|c| **c).count();
        let mut stride = 1;
        while n / (stride * stride) > MAX_POINTS {
            stride += 1;
        }
        let full: Vec<(i64, i64, f32)> = (-R..=R).flat_map(|dy| (-R..=R).map(move |dx| (dx, dy, 1.0))).collect();
        let rows: Vec<usize> = (0..h).step_by(stride).collect();
        let per_row = crate::par::map(rows.len(), true, |r| {
            let y = rows[r];
            let (mut ids, mut desc) = (Vec::new(), Vec::new());
            let mut vals = vec![0.0; full.len() * ch];
            for x in (0..w).step_by(stride) {
                let s = y * w + x;
                if !copyable[s] {
                    continue;
                }
                for (n, &(dx, dy, _)) in full.iter().enumerate() {
                    let j = (y as i64 + dy) as usize * w + (x as i64 + dx) as usize;
                    vals[n * ch..(n + 1) * ch].copy_from_slice(&self.img[j * ch..(j + 1) * ch]);
                }
                desc.extend(describe(ch, &full, &vals));
                ids.push(s as u32);
            }
            (ids, desc)
        });
        ctl.check()?;
        let (mut ids, mut pts) = (Vec::with_capacity(n), Vec::new());
        for (i, d) in per_row {
            ids.extend(i);
            pts.extend(d);
        }
        Ok(Tree::build(CELLS * CELLS * ch, pts, ids, stride))
    }

    /// This level's colours scaled up (bilinear) to `w`×`h`, about twice its size; `Void` is skipped.
    fn upsample(&self, ch: usize, w: usize, h: usize) -> Vec<f32> {
        let mut out = vec![0.0; w * h * ch];
        let (cw, chh) = (self.w, self.h);
        if cw == 0 || chh == 0 {
            return out;
        }
        let at = |o: usize, n: usize| {
            let v = ((o as f32 + 0.5) / 2.0 - 0.5).clamp(0.0, (n - 1) as f32);
            let a = v as usize;
            (a, (a + 1).min(n - 1), v - a as f32)
        };
        let mut acc = vec![0.0f32; ch];
        for y in 0..h {
            let (y0, y1, fy) = at(y, chh);
            for x in 0..w {
                let (x0, x1, fx) = at(x, cw);
                acc.iter_mut().for_each(|a| *a = 0.0);
                let mut total = 0.0;
                for (cx, cy, wt) in [(x0, y0, (1.0 - fx) * (1.0 - fy)), (x1, y0, fx * (1.0 - fy)), (x0, y1, (1.0 - fx) * fy), (x1, y1, fx * fy)] {
                    let i = cy * cw + cx;
                    if wt <= 0.0 || self.px[i] == Px::Void {
                        continue;
                    }
                    for (k, a) in acc.iter_mut().enumerate() {
                        *a += wt * self.img[i * ch + k];
                    }
                    total += wt;
                }
                if total > 0.0 {
                    let o = (y * w + x) * ch;
                    for (k, a) in acc.iter().enumerate() {
                        out[o + k] = a / total;
                    }
                }
            }
        }
        out
    }
}

/// Cells per side of a patch descriptor.
const CELLS: usize = 3;

/// A patch's descriptor: the weighted mean of each channel over each of its 3×3 cells (an empty
/// cell takes the whole patch's mean).
fn describe(ch: usize, taps: &[(i64, i64, f32)], vals: &[f32]) -> Vec<f32> {
    let side = (2 * R + 1) as usize;
    let mut sum = vec![0.0f32; CELLS * CELLS * ch];
    let mut wt = [0.0f32; CELLS * CELLS];
    let mut all = vec![0.0f32; ch];
    let mut all_wt = 0.0;
    for (n, &(dx, dy, weight)) in taps.iter().enumerate() {
        let cx = ((dx + R) as usize * CELLS / side).min(CELLS - 1);
        let cy = ((dy + R) as usize * CELLS / side).min(CELLS - 1);
        let c = cy * CELLS + cx;
        for k in 0..ch {
            let v = weight * vals.get(n * ch + k).copied().unwrap_or(0.0);
            sum[c * ch + k] += v;
            all[k] += v;
        }
        wt[c] += weight;
        all_wt += weight;
    }
    for c in 0..CELLS * CELLS {
        for k in 0..ch {
            sum[c * ch + k] = if wt[c] > 0.0 {
                sum[c * ch + k] / wt[c]
            } else if all_wt > 0.0 {
                all[k] / all_wt
            } else {
                0.0
            };
        }
    }
    sum
}

/// Points in a k-d tree leaf.
const LEAF: usize = 8;

/// A k-d tree over patch descriptors, stored implicitly: each range's middle point splits it.
struct Tree {
    dim: usize,
    stride: usize,
    pts: Vec<f32>,
    ids: Vec<u32>,
    axis: Vec<u16>,
}

impl Tree {
    fn build(dim: usize, pts: Vec<f32>, ids: Vec<u32>, stride: usize) -> Tree {
        let n = ids.len().min(pts.len() / dim.max(1));
        let mut order: Vec<usize> = (0..n).collect();
        let mut axis = vec![0u16; n];
        let at = |p: usize, d: usize| pts[p * dim + d];
        let mut stack = vec![(0usize, n)];
        while let Some((lo, hi)) = stack.pop() {
            if hi - lo <= LEAF {
                continue;
            }
            // Split on the widest dimension, judged on a sample.
            let step = ((hi - lo) / 256).max(1);
            let mut widest = (0usize, f32::NEG_INFINITY);
            for d in 0..dim {
                let (mut lo_v, mut hi_v) = (f32::INFINITY, f32::NEG_INFINITY);
                for &p in order[lo..hi].iter().step_by(step) {
                    lo_v = lo_v.min(at(p, d));
                    hi_v = hi_v.max(at(p, d));
                }
                if hi_v - lo_v > widest.1 {
                    widest = (d, hi_v - lo_v);
                }
            }
            let ax = widest.0;
            let mid = (lo + hi) / 2;
            order[lo..hi].select_nth_unstable_by(mid - lo, |a, b| at(*a, ax).total_cmp(&at(*b, ax)));
            axis[mid] = ax as u16;
            stack.push((lo, mid));
            stack.push((mid + 1, hi));
        }
        let sorted = order.iter().flat_map(|&p| pts[p * dim..(p + 1) * dim].iter().copied()).collect();
        let ids = order.iter().map(|&p| ids[p]).collect();
        Tree { dim, stride, pts: sorted, ids, axis }
    }

    /// Up to `k` ids whose descriptors are near `q`, looking at about `visits` points.
    fn nearest(&self, q: &[f32], k: usize, visits: usize) -> Vec<u32> {
        let mut best: Vec<(f32, usize)> = Vec::with_capacity(k + 1);
        let mut budget = visits;
        if q.len() == self.dim && k > 0 {
            self.visit(0, self.ids.len(), q, k, &mut best, &mut budget);
        }
        best.into_iter().filter_map(|(_, p)| self.ids.get(p).copied()).collect()
    }

    fn visit(&self, lo: usize, hi: usize, q: &[f32], k: usize, best: &mut Vec<(f32, usize)>, budget: &mut usize) {
        if *budget == 0 || lo >= hi {
            return;
        }
        if hi - lo <= LEAF {
            for p in lo..hi {
                self.offer(p, q, k, best);
            }
            *budget = budget.saturating_sub(hi - lo);
            return;
        }
        let mid = (lo + hi) / 2;
        self.offer(mid, q, k, best);
        *budget = budget.saturating_sub(1);
        let ax = usize::from(self.axis[mid]);
        let diff = q[ax] - self.pts[mid * self.dim + ax];
        let (near, far) = if diff < 0.0 { ((lo, mid), (mid + 1, hi)) } else { ((mid + 1, hi), (lo, mid)) };
        self.visit(near.0, near.1, q, k, best, budget);
        if diff * diff < worst(best, k) {
            self.visit(far.0, far.1, q, k, best, budget);
        }
    }

    fn offer(&self, p: usize, q: &[f32], k: usize, best: &mut Vec<(f32, usize)>) {
        let limit = worst(best, k);
        let mut d = 0.0;
        for (a, b) in q.iter().zip(&self.pts[p * self.dim..(p + 1) * self.dim]) {
            d += (a - b) * (a - b);
            if d >= limit {
                return;
            }
        }
        let at = best.partition_point(|(e, _)| *e <= d);
        best.insert(at, (d, p));
        best.truncate(k);
    }
}

fn worst(best: &[(f32, usize)], k: usize) -> f32 {
    if best.len() < k { f32::INFINITY } else { best.last().map_or(f32::INFINITY, |b| b.0) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stripes(w: usize, h: usize) -> Vec<f32> {
        (0..w * h).map(|i| if (i % w / 4).is_multiple_of(2) { 0.1 } else { 0.9 }).collect()
    }

    fn square_hole(w: usize, h: usize, x: std::ops::Range<usize>, y: std::ops::Range<usize>) -> Vec<Px> {
        (0..w * h).map(|i| if x.contains(&(i % w)) && y.contains(&(i / w)) { Px::Hole } else { Px::Source }).collect()
    }

    #[test]
    fn stripes_continue_through_the_hole() {
        let (w, h) = (64, 64);
        let img = stripes(w, h);
        let px = square_hole(w, h, 24..40, 24..40);
        let holed: Vec<f32> = img.iter().zip(&px).map(|(v, p)| if *p == Px::Hole { 0.5 } else { *v }).collect();
        let out = complete(w, h, 1, &holed, &px, 0.0, &Interrupt::NONE).unwrap().unwrap();
        let wrong = (0..w * h).filter(|&i| px[i] == Px::Hole && (out[i] - img[i]).abs() > 0.2).count();
        assert!(wrong < 26, "{wrong} of 256 hole pixels off the stripes");
        assert!((0..w * h).all(|i| px[i] == Px::Hole || out[i] == holed[i]), "outside the hole is untouched");
    }

    #[test]
    fn a_large_hole_is_filled_coarse_to_fine() {
        let (w, h) = (300, 200);
        let img = stripes(w, h);
        let px = square_hole(w, h, 100..220, 50..150);
        let out = complete(w, h, 1, &img, &px, 0.0, &Interrupt::NONE).unwrap().unwrap();
        let wrong = (0..w * h).filter(|&i| px[i] == Px::Hole && (out[i] - img[i]).abs() > 0.2).count();
        assert!(wrong < 120 * 100 / 5, "{wrong} hole pixels off the stripes");
    }

    #[test]
    fn an_edge_runs_on_through_a_large_hole() {
        let (w, h, ch) = (400, 400, 3);
        // Two textured regions split by a diagonal edge.
        let img: Vec<f32> = (0..w * h * ch)
            .map(|i| {
                let (x, y, k) = ((i / ch) % w, (i / ch) / w, i % ch);
                let side = if x + y / 2 < 300 { 0.2 } else { 0.7 };
                side + 0.05 * ((x * 3 + y * 5 + k) % 4) as f32
            })
            .collect();
        let px = square_hole(w, h, 140..260, 140..260);
        let out = complete(w, h, ch, &img, &px, 0.0, &Interrupt::NONE).unwrap().unwrap();
        let wrong = (0..w * h).filter(|&i| px[i] == Px::Hole && (out[i * ch] - img[i * ch]).abs() > 0.3).count();
        assert!(wrong < 120 * 120 / 8, "{wrong} hole pixels on the wrong side of the edge");
    }

    #[test]
    fn nothing_to_copy_from_no_hole_and_bad_sizes() {
        let (w, h) = (20, 20);
        let img = vec![0.5; w * h];
        assert!(complete(w, h, 1, &img, &vec![Px::Hole; w * h], 0.0, &Interrupt::NONE).unwrap().is_none());
        let mut px = vec![Px::Source; w * h];
        px[0] = Px::Void;
        assert_eq!(complete(w, h, 1, &img, &px, 0.0, &Interrupt::NONE).unwrap().unwrap(), img, "no hole: unchanged");
        assert_eq!(complete(w, h, 1, &img[..10], &px, 0.0, &Interrupt::NONE).unwrap().unwrap(), img[..10].to_vec());
    }

    /// Copies from a darker area are brought up to the hole's surroundings, by at most `shift`.
    #[test]
    fn colour_adaptation_matches_the_surroundings() {
        let (w, h) = (40, 20);
        let hole = |i: usize| (26..34).contains(&(i % w)) && (6..14).contains(&(i / w));
        let px: Vec<Px> = (0..w * h).map(|i| if hole(i) { Px::Hole } else { Px::Source }).collect();
        let src: Vec<u32> = (0..w * h).map(|i| if hole(i) { (i - 20) as u32 } else { u32::MAX }).collect();
        for (shift, want) in [(0.14, 0.5), (0.04, 0.44)] {
            let mut img: Vec<f32> = (0..w * h).map(|i| if i % w < 20 || hole(i) { 0.4 } else { 0.5 }).collect();
            adapt(w, h, 1, &mut img, &px, &src, shift);
            let worst = (0..w * h).filter(|i| hole(*i)).map(|i| (img[i] - want).abs()).fold(0.0f32, f32::max);
            assert!(worst < 0.01, "shift {shift}: off by {worst}");
        }
    }

    /// `cargo test --release -p photocraft-algo --lib exemplar::tests::timing -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn timing() {
        let (w, h, ch) = (1500, 1500, 3);
        let img: Vec<f32> = (0..w * h * ch)
            .map(|i| {
                let (x, y, k) = ((i / ch) % w, (i / ch) / w, i % ch);
                (((x + 2 * y) / 9 % 2) as f32 * 0.6 + 0.2 + 0.1 * ((x * 7 + y * 13 + k * 5) % 11) as f32 / 11.0).min(1.0)
            })
            .collect();
        let px = square_hole(w, h, 600..900, 600..900);
        let t = std::time::Instant::now();
        let out = complete(w, h, ch, &img, &px, 0.1, &Interrupt::NONE).unwrap().unwrap();
        let err = (0..w * h).filter(|&i| px[i] == Px::Hole).map(|i| (out[i * ch] - img[i * ch]).abs()).sum::<f32>() / 90000.0;
        eprintln!("300x300 hole in 1500x1500: {:?}, mean error {err:.3}", t.elapsed());
    }
}

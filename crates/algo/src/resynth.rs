//! Spot Healing's Match Nearby: per-pixel resynthesis from the spot's surroundings, after
//! P. Harrison, *A non-hierarchical procedure for re-synthesis of complex textures*, WSCG 2001
//! (the method of Resynthesizer's Heal Selection; none of its code is used).
//!
//! Hole pixels are filled one at a time from the edge inwards, in a lightly shuffled order. Each
//! pixel compares its nearest already-set neighbours with the same pattern around candidate
//! source pixels and takes the best one's value. Candidates are the sources the neighbours took,
//! shifted by the neighbour's offset (so texture continues), plus random pixels near the hole.
//! A second pass redoes every pixel with its neighbourhood complete. Every pixel picks its own
//! source; nothing chooses one region to copy.

use crate::inpaint::Rng;
use crate::selection::edt;

/// Neighbours compared per pixel.
const NEIGHBOURS: usize = 24;
/// How far neighbours are looked for, px.
const REACH: i32 = 5;
/// Random candidates per pixel.
const RANDOM: usize = 24;
/// Scale of the robust colour difference (normalised values).
const SIGMA: f32 = 0.08;

/// Fill `hole` in `img` (`w × h × ch`) from the pixels around it. `None` when nothing outside
/// the hole can be copied.
pub fn heal(w: usize, h: usize, ch: usize, img: &[f32], hole: &[bool], seed: u64) -> Option<Vec<f32>> {
    let n = w.checked_mul(h)?;
    if ch == 0 || hole.len() != n || img.len() != n.checked_mul(ch)? {
        return None;
    }
    let known: Vec<bool> = hole.iter().map(|h| !h).collect();
    // Hole pixels by distance to the edge, nearest first.
    let dist = edt(&known, w, h);
    let mut rng = Rng::new(seed);
    let mut order: Vec<(f32, usize)> = (0..n).filter(|i| hole[*i]).map(|i| (dist.get(i).copied().unwrap_or(0.0) + 0.5 * unit(&mut rng), i)).collect();
    if order.is_empty() {
        return Some(img.to_vec());
    }
    order.sort_by(|a, b| a.0.total_cmp(&b.0));
    let order: Vec<usize> = order.into_iter().map(|(_, i)| i).collect();
    // Sources: known pixels near the hole (its bounds grown by its size, 16 px at least).
    let (mut x0, mut y0, mut x1, mut y1) = (w, h, 0, 0);
    for &i in &order {
        let (x, y) = (i % w, i / w);
        (x0, y0, x1, y1) = (x0.min(x), y0.min(y), x1.max(x), y1.max(y));
    }
    let grow = (x1 - x0).max(y1 - y0).max(16);
    let near: Vec<usize> = (y0.saturating_sub(grow)..=(y1 + grow).min(h - 1))
        .flat_map(|y| (x0.saturating_sub(grow)..=(x1 + grow).min(w - 1)).map(move |x| y * w + x))
        .filter(|i| known[*i])
        .collect();
    if near.is_empty() {
        return None;
    }
    let mut offsets: Vec<(i32, i32)> = (-REACH..=REACH).flat_map(|dy| (-REACH..=REACH).map(move |dx| (dx, dy))).filter(|d| *d != (0, 0)).collect();
    offsets.sort_by_key(|(dx, dy)| dx * dx + dy * dy);

    let mut out = img.to_vec();
    let mut set = known.clone();
    // Where each pixel's value came from (known pixels: themselves).
    let mut src: Vec<usize> = (0..n).collect();
    let at = |i: usize, dx: i32, dy: i32| -> Option<usize> {
        let (x, y) = ((i % w) as i32 + dx, (i / w) as i32 + dy);
        (x >= 0 && y >= 0 && (x as usize) < w && (y as usize) < h).then(|| y as usize * w + x as usize)
    };
    for _pass in 0..2 {
        for &t in &order {
            let neigh: Vec<(i32, i32, usize)> =
                offsets.iter().filter_map(|&(dx, dy)| at(t, dx, dy).filter(|j| set[*j]).map(|j| (dx, dy, j))).take(NEIGHBOURS).collect();
            let mut cands: Vec<usize> = neigh.iter().filter_map(|&(dx, dy, j)| at(src[j], -dx, -dy)).filter(|c| known[*c]).collect();
            for _ in 0..RANDOM {
                cands.push(near[(rng.next() % near.len() as u64) as usize]);
            }
            let mut best: Option<(f32, usize)> = None;
            for &c in &cands {
                let mut cost = 0.0f32;
                for &(dx, dy, j) in &neigh {
                    let Some(s) = at(c, dx, dy).filter(|s| known[*s]) else {
                        cost += 1.0;
                        continue;
                    };
                    for k in 0..ch {
                        let d = (out[j * ch + k] - img[s * ch + k]) / SIGMA;
                        cost += (1.0 + d * d).ln();
                    }
                }
                if best.is_none_or(|(b, _)| cost < b) {
                    best = Some((cost, c));
                }
            }
            if let Some((_, c)) = best {
                out[t * ch..(t + 1) * ch].copy_from_slice(&img[c * ch..(c + 1) * ch]);
                src[t] = c;
                set[t] = true;
            }
        }
    }
    Some(out)
}

fn unit(rng: &mut Rng) -> f32 {
    (rng.next() >> 40) as f32 / (1u64 << 24) as f32
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Vertical stripes continue through the hole, and every filled value comes from the image.
    #[test]
    fn stripes_continue_through_a_spot() {
        let (w, h) = (48, 32);
        let img: Vec<f32> = (0..w * h).map(|i| if (i % w) / 3 % 2 == 0 { 0.2 } else { 0.8 }).collect();
        let hole: Vec<bool> = (0..w * h).map(|i| (20..28).contains(&(i % w)) && (12..20).contains(&(i / w))).collect();
        let out = heal(w, h, 1, &img, &hole, 1).unwrap();
        let wrong = (0..w * h).filter(|i| hole[*i] && (out[*i] - img[*i]).abs() > 0.01).count();
        assert!(wrong <= 4, "{wrong} of 64 off the stripes");
        assert_eq!(heal(w, h, 1, &img, &vec![true; w * h], 1), None, "nothing to copy");
        assert_eq!(heal(w, h, 1, &img[..5], &hole, 1), None);
    }
}

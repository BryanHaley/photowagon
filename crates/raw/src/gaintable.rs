//! DNG ProfileGainTableMap (1.6) and ProfileGainTableMap2 (1.7): the local tone mapping phones
//! (Apple ProRAW, Samsung Expert RAW) write for their default look.
//!
//! The fields are in the file's byte order (Apple writes big-endian files, Adobe little-endian;
//! big-endian is tried as a fallback): MapPointsV, MapPointsH (u32), MapSpacingV, MapSpacingH,
//! MapOriginV, MapOriginH (f64, relative to the active area), MapPointsN (u32), MapInputWeights
//! (5 × f32: R, G, B, min, max). Version 1 then holds `V × H × N` f32 gains; version 2 adds
//! DataType (u32: u8, u16, f16, f32), Gamma, GainMin and GainMax (f32) first, integer gains
//! spanning GainMin..=GainMax.
//!
//! A pixel's input is `clamp(weights · (R, G, B, min, max), 0, 1) ^ gamma` in linear ProPhoto after
//! BaselineExposure; its gain is the table at `input × MapPointsN` (clamped to the last point),
//! the four tables around it interpolated bilinearly.

/// A parsed ProfileGainTableMap or ProfileGainTableMap2.
#[derive(Debug, Clone, PartialEq)]
pub struct GainTable {
    points_v: usize,
    points_h: usize,
    spacing_v: f64,
    spacing_h: f64,
    origin_v: f64,
    origin_h: f64,
    points_n: usize,
    weights: [f32; 5],
    gamma: f32,
    gains: Vec<f32>,
}

/// Most tables in the grid, and most gains in all.
const MAX_TABLES: usize = 1 << 12;
const MAX_GAINS: usize = 1 << 22;

impl GainTable {
    /// `None` for anything malformed: the wrong size, non-finite or negative values, zero spacing.
    pub fn parse(b: &[u8], le: bool, version2: bool) -> Option<Self> {
        Self::parse_in(b, le, version2).or_else(|| if le { Self::parse_in(b, false, version2) } else { None })
    }

    fn parse_in(b: &[u8], le: bool, version2: bool) -> Option<Self> {
        let bytes = |at: usize, n: usize| b.get(at..at.checked_add(n)?);
        let u16_at = |at: usize| bytes(at, 2).map(|s| if le { u16::from_le_bytes([s[0], s[1]]) } else { u16::from_be_bytes([s[0], s[1]]) });
        let u32_at = |at: usize| {
            let s = <[u8; 4]>::try_from(bytes(at, 4)?).ok()?;
            Some(if le { u32::from_le_bytes(s) } else { u32::from_be_bytes(s) })
        };
        let f32_at = |at: usize| u32_at(at).map(f32::from_bits);
        let f64_at = |at: usize| {
            let s = <[u8; 8]>::try_from(bytes(at, 8)?).ok()?;
            Some(if le { f64::from_le_bytes(s) } else { f64::from_be_bytes(s) })
        };
        let (points_v, points_h) = (u32_at(0)? as usize, u32_at(4)? as usize);
        let (spacing_v, spacing_h, origin_v, origin_h) = (f64_at(8)?, f64_at(16)?, f64_at(24)?, f64_at(32)?);
        let points_n = u32_at(40)? as usize;
        let mut weights = [0f32; 5];
        for (i, w) in weights.iter_mut().enumerate() {
            *w = f32_at(44 + i * 4)?;
        }
        let tables = points_v.checked_mul(points_h).filter(|t| (1..=MAX_TABLES).contains(t))?;
        let count = tables.checked_mul(points_n).filter(|c| (1..=MAX_GAINS).contains(c))?;
        let spacing = |s: f64, n: usize| s.is_finite() && (s > 0.0 || n == 1);
        if !spacing(spacing_v, points_v)
            || !spacing(spacing_h, points_h)
            || !origin_v.is_finite()
            || !origin_h.is_finite()
            || !weights.iter().all(|w| w.is_finite())
        {
            return None;
        }
        let (header, data_type, gamma, gain_min, gain_max) =
            if version2 { (80, u32_at(64)?, f32_at(68)?, f32_at(72)?, f32_at(76)?) } else { (64, 3, 1.0, 0.0, 1.0) };
        if !(0.25..=4.0).contains(&gamma) || !gain_min.is_finite() || !gain_max.is_finite() {
            return None;
        }
        let width = match data_type {
            0 => 1,
            1 | 2 => 2,
            3 => 4,
            _ => return None,
        };
        if b.len() != count.checked_mul(width)?.checked_add(header)? {
            return None;
        }
        let scaled = |q: f32, max: f32| gain_min + q / max * (gain_max - gain_min);
        let gains = (0..count)
            .map(|i| {
                let at = header + i * width;
                match data_type {
                    0 => b.get(at).map(|&q| scaled(f32::from(q), 255.0)),
                    1 => u16_at(at).map(|q| scaled(f32::from(q), 65535.0)),
                    2 => u16_at(at).map(half),
                    _ => f32_at(at),
                }
            })
            .collect::<Option<Vec<f32>>>()?;
        if !gains.iter().all(|g| g.is_finite() && *g >= 0.0) {
            return None;
        }
        Some(GainTable { points_v, points_h, spacing_v, spacing_h, origin_v, origin_h, points_n, weights, gamma, gains })
    }

    /// The gain for linear ProPhoto `p` (after BaselineExposure) at `(u, v)`, relative to the
    /// active area (0..1 across, down).
    pub fn gain(&self, u: f64, v: f64, p: [f32; 3]) -> f32 {
        let w = &self.weights;
        let lo = p[0].min(p[1]).min(p[2]);
        let hi = p[0].max(p[1]).max(p[2]);
        let input = (w[0] * p[0] + w[1] * p[1] + w[2] * p[2] + w[3] * lo + w[4] * hi).clamp(0.0, 1.0).powf(self.gamma);
        let last = self.points_n - 1;
        let k = (input * self.points_n as f32).min(last as f32);
        let (k0, kt) = (k.floor() as usize, k.fract());
        let k1 = (k0 + 1).min(last);
        // Grid position, clamped to the outermost tables.
        let grid = |t: f64, origin: f64, spacing: f64, n: usize| {
            let g = if n > 1 { ((t - origin) / spacing).clamp(0.0, (n - 1) as f64) } else { 0.0 };
            let g0 = (g.floor() as usize).min(n - 1);
            (g0, (g0 + 1).min(n - 1), (g - g0 as f64) as f32)
        };
        let (r0, r1, rt) = grid(v, self.origin_v, self.spacing_v, self.points_v);
        let (c0, c1, ct) = grid(u, self.origin_h, self.spacing_h, self.points_h);
        let at = |r: usize, c: usize| {
            let base = (r * self.points_h + c) * self.points_n;
            let g = |i: usize| self.gains.get(base + i).copied().unwrap_or(1.0);
            g(k0) + (g(k1) - g(k0)) * kt
        };
        let top = at(r0, c0) + (at(r0, c1) - at(r0, c0)) * ct;
        let bottom = at(r1, c0) + (at(r1, c1) - at(r1, c0)) * ct;
        top + (bottom - top) * rt
    }
}

/// IEEE 754 half precision to f32.
fn half(h: u16) -> f32 {
    let sign = if h & 0x8000 != 0 { -1.0 } else { 1.0 };
    let exp = i32::from((h >> 10) & 0x1f);
    let frac = f32::from(h & 0x3ff);
    sign * match exp {
        0 => frac * 2f32.powi(-24),
        31 if frac == 0.0 => f32::INFINITY,
        31 => f32::NAN,
        e => (1.0 + frac / 1024.0) * 2f32.powi(e - 15),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table(v: u32, h: u32, n: u32, weights: [f32; 5], gains: &[f32]) -> Vec<u8> {
        let mut b = Vec::new();
        b.extend(v.to_be_bytes());
        b.extend(h.to_be_bytes());
        for x in [1.0, 1.0, 0.0, 0.0f64] {
            b.extend(x.to_be_bytes());
        }
        b.extend(n.to_be_bytes());
        for w in weights {
            b.extend(w.to_be_bytes());
        }
        for g in gains {
            b.extend(g.to_be_bytes());
        }
        b
    }

    impl GainTable {
        fn parse_be(b: &[u8]) -> Option<Self> {
            Self::parse(b, false, false)
        }
    }

    #[test]
    fn little_endian_files_store_it_little_endian() {
        let be = table(1, 1, 2, [0.0, 0.0, 0.0, 0.0, 1.0], &[3.0, 3.0]);
        // The same fields, each value's bytes reversed.
        let mut le = Vec::new();
        for (at, len) in [(0, 4), (4, 4), (8, 8), (16, 8), (24, 8), (32, 8), (40, 4)].into_iter().chain((44..be.len()).step_by(4).map(|a| (a, 4))) {
            le.extend(be[at..at + len].iter().rev());
        }
        assert_eq!(GainTable::parse(&le, true, false), GainTable::parse(&be, false, false));
        assert!(GainTable::parse(&le, false, false).is_none(), "read the wrong way round it is nonsense");
        assert!(GainTable::parse(&be, true, false).is_some(), "big-endian is the fallback");
    }

    #[test]
    fn gains_interpolate_by_the_weighted_value_and_position() {
        // 2 × 2 points, 2 entries each: dark pixels get the first gain, bright ones the second.
        let gains = [2.0, 1.0, 2.0, 1.0, 4.0, 1.0, 4.0, 1.0];
        let t = GainTable::parse_be(&table(2, 2, 2, [0.0, 0.0, 0.0, 0.0, 1.0], &gains)).unwrap();
        assert_eq!(t.gain(0.0, 0.0, [0.0; 3]), 2.0);
        assert_eq!(t.gain(0.0, 1.0, [0.0; 3]), 4.0, "the bottom row");
        assert_eq!(t.gain(0.0, 0.5, [0.0; 3]), 3.0, "halfway down");
        assert_eq!(t.gain(0.0, 0.0, [0.25, 0.0, 0.0]), 1.5, "the max weight sees the brightest channel; index = input × N");
        assert_eq!(t.gain(0.0, 0.0, [9.0; 3]), 1.0, "the input clamps to the table's end");
        assert_eq!(t.gain(-5.0, 7.0, [0.0; 3]), 4.0, "outside the grid: the nearest point");
    }

    #[test]
    fn version_2_scales_integer_gains_and_raises_the_input_to_its_gamma() {
        // One table of two u8 gains spanning 1..=3: 0 → 1, 255 → 3. Gamma 2.
        let mut b = table(1, 1, 2, [1.0, 0.0, 0.0, 0.0, 0.0], &[]);
        for v in [0u32.to_be_bytes(), 2f32.to_be_bytes(), 1f32.to_be_bytes(), 3f32.to_be_bytes()] {
            b.extend(v);
        }
        b.extend([0u8, 255]);
        let t = GainTable::parse(&b, false, true).unwrap();
        assert_eq!(t.gain(0.0, 0.0, [0.0; 3]), 1.0);
        assert_eq!(t.gain(0.0, 0.0, [0.5, 0.0, 0.0]), 2.0, "0.5² × 2 = index 0.5: halfway");
        assert!(GainTable::parse(&b, false, false).is_none(), "read as version 1 the size is wrong");
        assert_eq!([half(0x3c00), half(0x4000), half(0x3800), half(0)], [1.0, 2.0, 0.5, 0.0]);
    }

    #[test]
    fn malformed_tables_are_rejected() {
        let good = table(1, 1, 2, [1.0, 0.0, 0.0, 0.0, 0.0], &[1.0, 1.0]);
        assert!(GainTable::parse_be(&good).is_some());
        assert!(GainTable::parse_be(&good[..good.len() - 1]).is_none(), "truncated");
        assert!(GainTable::parse_be(&table(0, 1, 2, [0.0; 5], &[])).is_none(), "no points");
        assert!(GainTable::parse_be(&table(1, 1, 2, [f32::NAN, 0.0, 0.0, 0.0, 0.0], &[1.0, 1.0])).is_none());
        assert!(GainTable::parse_be(&table(1, 1, 2, [0.0; 5], &[1.0, f32::INFINITY])).is_none());
        assert!(GainTable::parse_be(&table(u32::MAX, u32::MAX, u32::MAX, [0.0; 5], &[])).is_none(), "absurd sizes");
        assert!(GainTable::parse_be(&[]).is_none());
    }
}

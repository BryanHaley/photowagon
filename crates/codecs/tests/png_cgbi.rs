//! Apple's iPhone PNG (CgBI): a `CgBI` chunk first, raw deflate image data, BGRA premultiplied.

use photocraft_codecs::{ChannelLayout, EncodeOptions, Format, Image, decode, detect, encode};

/// `straight` (RGBA) written as Xcode writes it: from a standard PNG of its BGRA premultiplied
/// pixels, with the zlib wrapper taken off the image data and a `CgBI` chunk put in front.
fn cgbi(w: u32, h: u32, straight: &[u8]) -> Vec<u8> {
    let stored: Vec<u8> = straight
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|p| {
            let a = u32::from(p[3]);
            let pm = |c: u8| ((u32::from(c) * a + 127) / 255) as u8;
            [pm(p[2]), pm(p[1]), pm(p[0]), p[3]]
        })
        .collect();
    let png = encode(&Image::from_u8(w, h, ChannelLayout::Rgba, stored).unwrap(), Format::Png, &EncodeOptions::default()).unwrap();
    let chunk = |ty: &[u8], data: &[u8]| {
        let mut c = (data.len() as u32).to_be_bytes().to_vec();
        c.extend_from_slice(ty);
        c.extend_from_slice(data);
        c.extend([0, 0, 0, 0]);
        c
    };
    let mut out = png[..8].to_vec();
    out.extend(chunk(b"CgBI", &[0x50, 0x00, 0x20, 0x02]));
    let mut at = 8;
    while at + 12 <= png.len() {
        let len = u32::from_be_bytes(png[at..at + 4].try_into().unwrap()) as usize;
        let (ty, data) = (&png[at + 4..at + 8], &png[at + 8..at + 8 + len]);
        out.extend(if ty == b"IDAT" { chunk(ty, &data[2..data.len() - 4]) } else { png[at..at + 12 + len].to_vec() });
        at += 12 + len;
    }
    out
}

#[test]
fn cgbi_opens_as_straight_rgba() {
    let straight = [255, 0, 0, 255, 0, 0, 255, 128, 10, 20, 30, 0, 200, 100, 50, 64];
    let file = cgbi(2, 2, &straight);
    assert_eq!(detect(&file), Some(Format::Png));
    let img = decode(&file).unwrap().convert(ChannelLayout::Rgba, photocraft_codecs::SampleType::U8);
    let px = img.data();
    assert_eq!(&px[..4], &[255, 0, 0, 255], "red, not blue");
    assert_eq!(&px[4..8], &[0, 0, 255, 128], "half-transparent blue, its colour full again");
    assert_eq!(px[11], 0);
    for (got, want) in px[12..15].iter().zip([200u8, 100, 50]) {
        assert!(got.abs_diff(want) <= 4, "{:?}", &px[12..16]);
    }
}

#[test]
fn a_broken_cgbi_is_an_error() {
    let mut file = cgbi(2, 2, &[0; 16]);
    file.truncate(40);
    assert!(decode(&file).is_err());
}

/// A file Xcode's own `pngcrush -iphone` wrote (`PNG_CGBI_SAMPLE`, with the standard PNG it came
/// from as `PNG_CGBI_SOURCE`), when given: the same pixels come back.
#[test]
fn an_xcode_cgbi_matches_its_source() {
    let (Ok(cgbi), Ok(source)) = (std::env::var("PNG_CGBI_SAMPLE"), std::env::var("PNG_CGBI_SOURCE")) else { return };
    let rgba = |b: Vec<u8>| decode(&b).unwrap().convert(ChannelLayout::Rgba, photocraft_codecs::SampleType::U8).data().to_vec();
    let (a, b) = (rgba(std::fs::read(cgbi).unwrap()), rgba(std::fs::read(source).unwrap()));
    assert_eq!(a.len(), b.len());
    let worst = a
        .as_chunks::<4>()
        .0
        .iter()
        .zip(b.as_chunks::<4>().0)
        .filter(|(_, q)| q[3] > 0)
        .map(|(p, q)| (0..4).map(|i| p[i].abs_diff(q[i])).max().unwrap())
        .max()
        .unwrap();
    assert!(worst <= 8, "worst channel difference {worst}");
}

#!/usr/bin/env python3
"""Writes corpus/formats: our own test chart in every format and option we import, each with a
reference decode by the format's own library (ImageMagick on libtiff, libjpeg-turbo, libwebp,
OpenEXR…, or heif-dec / avifdec / djxl), for crates/io/tests/format_matrix.rs to compare against.

    python3 -I scripts/format_samples.py [corpus/formats]

Needs ImageMagick 7 (HDRI), cwebp, img2webp, avifenc, avifdec, heif-enc, heif-dec, cjxl, djxl,
cjpeg, exiftool and ffmpeg. A sample whose tool is missing or fails is left out and listed.
Our samples are generated, so they can be shared freely (CC0). Public test images from
permissively licensed projects are fetched too, at pinned commits and checked against
scripts/format_suites.sha256: libtiff's test/images (LibTIFF licence) and libjpeg-turbo's
testimages (IJG / BSD licences), and the JPEG XL conformance inputs (BSD-3-Clause).
"""

import json
import os
import shutil
import struct
import subprocess
import sys
import zipfile

OUT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "corpus/formats")
W, H = 131, 87  # odd sizes catch row padding and edge blocks
BW, BH = 517, 389  # for tiles, strips and restart intervals


def chart(x, y, w, h, alpha):
    """Gradients, a fine pattern, saturated patches and (with `alpha`) an alpha ramp and a hole."""
    r, g = x / (w - 1), y / (h - 1)
    b = ((x * 3 + y * 5) % 17) / 16
    if x < w // 4 and y > h * 2 // 3:
        r, g, b = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0)][(x * 4 // (w // 4)) % 4]
    a = 1.0
    if alpha and x > w * 2 // 3:
        a = 0.2 + 0.8 * y / (h - 1)
    if alpha and w // 2 <= x < w // 2 + 6 and 4 <= y < 10:
        a = 0.0
    return r, g, b, a


def write_pam(path, w, h, alpha):
    rows = bytearray()
    for y in range(h):
        for x in range(w):
            px = chart(x, y, w, h, alpha)
            for v in px[: 4 if alpha else 3]:
                rows += struct.pack(">H", round(v * 65535))
    tupl = "RGB_ALPHA" if alpha else "RGB"
    head = f"P7\nWIDTH {w}\nHEIGHT {h}\nDEPTH {4 if alpha else 3}\nMAXVAL 65535\nTUPLTYPE {tupl}\nENDHDR\n"
    with open(path, "wb") as f:
        f.write(head.encode() + rows)


def write_pfm(path, w, h):
    """An HDR chart: the same picture scaled up to 4.0, so values above 1 must survive."""
    data = bytearray()
    for y in reversed(range(h)):  # PFM rows go bottom-up
        for x in range(w):
            r, g, b, _ = chart(x, y, w, h, False)
            data += struct.pack("<3f", r * 4, g * 2, b * 0.5)
    with open(path, "wb") as f:
        f.write(f"PF\n{w} {h}\n-1.0\n".encode() + data)


SAMPLES = []  # filled by the format sections below


def sample(fmt, name, ext, make, ref=None, tol="exact", ref_ext=".png", **expect):
    """`make(src, out)` returns commands writing `out`; `ref(out, tmp)` commands writing a 16-bit
    PNG or PAM `tmp` when ImageMagick can't read the format; `tol` is exact / lossy / loose."""
    SAMPLES.append(dict(fmt=fmt, name=name, ext=ext, make=make, ref=ref, tol=tol, ref_ext=ref_ext, expect=expect))


M = "magick"
RGBA, RGB, BIG = "rgba.pam", "rgb.pam", "big.pam"
src = {"a": RGBA, "o": RGB, "b": BIG, "f": "hdr.pfm"}


def mk(source, *args):
    """ImageMagick from a chart; a last argument like "BMP3:-" picks the coder for the output."""
    if args and args[-1].endswith(":-"):
        *args, coder = args
        return lambda d, out: [[M, os.path.join(d, src[source]), *args, coder[:-1] + out]]
    return lambda d, out: [[M, os.path.join(d, src[source]), *args, out]]


def mk2(source, cmd):
    """An external encoder that reads a PNG: `cmd(png, out)`."""

    def f(d, out):
        png = out + ".src.png"
        return [[M, os.path.join(d, src[source]), png], cmd(png, out)]

    return f


# ---------------------------------------------------------------- PNG (PngSuite covers the rest)
sample("png", "rgba16", "png", mk("a", "-depth", "16"), depth=16, alpha=True)
sample("png", "rgb8", "png", mk("o", "-depth", "8"), depth=8)
sample("png", "gray16", "png", mk("o", "-colorspace", "Gray", "-depth", "16"), depth=16, mode="Grayscale")
sample("png", "graya8", "png", mk("a", "-colorspace", "Gray", "-depth", "8", "PNG32:-"), depth=8, alpha=True)
sample("png", "palette-trns", "png", mk("a", "-colors", "200", "PNG8:-"), depth=8, alpha=True)
sample("png", "interlaced", "png", mk("a", "-interlace", "PNG", "-depth", "8"), depth=8, alpha=True)
sample("png", "apng-frame1", "png", lambda d, out: [["ffmpeg", "-loglevel", "error", "-y", "-i", os.path.join(d, "rgb8.png"), "-i", os.path.join(d, "rgb8.png"), "-filter_complex", "[0][1]concat=n=2:v=1", "-plays", "0", "-f", "apng", out]], depth=8)

# ---------------------------------------------------------------- JPEG
sample("jpeg", "444", "jpg", mk("o", "-quality", "92", "-sampling-factor", "4:4:4"), tol="lossy", depth=8)
sample("jpeg", "420", "jpg", mk("o", "-quality", "92", "-sampling-factor", "4:2:0"), tol="lossy", depth=8)
sample("jpeg", "422", "jpg", mk("o", "-quality", "92", "-sampling-factor", "4:2:2"), tol="lossy", depth=8)
sample("jpeg", "440", "jpg", mk("o", "-quality", "92", "-sampling-factor", "1x2"), tol="lossy", depth=8)
sample("jpeg", "progressive", "jpg", mk("b", "-quality", "90", "-interlace", "JPEG"), tol="lossy", depth=8)
sample("jpeg", "gray", "jpg", mk("o", "-colorspace", "Gray", "-quality", "92"), tol="lossy", depth=8, mode="Grayscale")
sample("jpeg", "cmyk", "jpg", mk("o", "-colorspace", "CMYK", "-quality", "92"), tol="lossy", depth=8, mode="Cmyk")
sample("jpeg", "restart", "jpg", mk2("b", lambda p, o: ["cjpeg", "-quality", "90", "-restart", "3", "-outfile", o, p]), tol="lossy", depth=8)
sample("jpeg", "arithmetic", "jpg", mk2("b", lambda p, o: ["cjpeg", "-quality", "90", "-arithmetic", "-outfile", o, p]), tol="lossy", depth=8)
sample("jpeg", "optimized-huffman", "jpg", mk2("b", lambda p, o: ["cjpeg", "-quality", "90", "-optimize", "-outfile", o, p]), tol="lossy", depth=8)
sample("jpeg", "12bit", "jpg", mk2("o", lambda p, o: ["cjpeg", "-precision", "12", "-quality", "95", "-outfile", o, p]), tol="lossy")
for o in (2, 3, 6, 8):
    sample("jpeg", f"exif-orientation-{o}", "jpg", lambda d, out, o=o: [[M, os.path.join(d, RGB), "-quality", "92", out], ["exiftool", "-q", "-overwrite_original", f"-Orientation#={o}", out]], tol="lossy", depth=8, orient=True)
sample("jpeg", "icc-p3", "jpg", lambda d, out: [[M, os.path.join(d, RGB), "-quality", "92", out], ["exiftool", "-q", "-overwrite_original", "-icc_profile<=/System/Library/ColorSync/Profiles/Display P3.icc", out]], tol="lossy", depth=8, icc=True)

# ---------------------------------------------------------------- TIFF
for c in ("None", "LZW", "Zip", "RLE", "JPEG", "ZSTD", "LZMA"):
    lossy = c == "JPEG"
    sample("tiff", f"rgb8-{c.lower()}", "tif", mk("o", "-depth", "8", "-compress", c), tol="lossy" if lossy else "exact", depth=8)
sample("tiff", "rgb8-webp", "tif", lambda d, out: [[M, os.path.join(d, RGB), "-depth", "8", out + ".src.tif"], ["tiffcp", "-c", "webp:p90", out + ".src.tif", out]], tol="lossy", depth=8)
sample("tiff", "rgba8-webp", "tif", lambda d, out: [[M, os.path.join(d, RGBA), "-depth", "8", out + ".src.tif"], ["tiffcp", "-c", "webp:p90", out + ".src.tif", out]], tol="lossy", depth=8, alpha=True)
sample("tiff", "rgba16-lzw-predictor", "tif", mk("a", "-depth", "16", "-compress", "LZW", "-define", "tiff:predictor=2"), depth=16, alpha=True)
# ImageMagick premultiplies the alpha channel by itself too when it writes associated alpha: Pillow's
# RGBa mode writes it right (8-bit).
# ImageMagick premultiplies the alpha channel by itself too when it writes associated alpha, and
# Pillow can't write it: written here, with the reference straight from the stored samples.
sample("tiff", "rgba16-associated", "tif", lambda d, out: [["ASSOC_TIFF", out]], ref=lambda f, t: [["ASSOC_REF", f, t]], depth=16, alpha=True)
sample("tiff", "rgba8-unassociated", "tif", mk("a", "-depth", "8", "-define", "tiff:alpha=unassociated"), depth=8, alpha=True)
sample("tiff", "float32-zip-predictor3", "tif", mk("f", "-define", "quantum:format=floating-point", "-depth", "32", "-compress", "Zip", "-define", "tiff:predictor=3"), depth=32)
sample("tiff", "float16", "tif", mk("f", "-define", "quantum:format=floating-point", "-depth", "16"), depth=32)
sample("tiff", "gray16", "tif", mk("o", "-colorspace", "Gray", "-depth", "16"), depth=16, mode="Grayscale")
sample("tiff", "gray8-alpha", "tif", mk("a", "-colorspace", "Gray", "-depth", "8"), depth=8, mode="Grayscale", alpha=True)
sample("tiff", "bilevel-g4", "tif", mk("o", "-colorspace", "Gray", "-threshold", "50%", "-monochrome", "-compress", "Group4"), mode="Bitmap")
sample("tiff", "bilevel-g3", "tif", mk("o", "-colorspace", "Gray", "-threshold", "50%", "-monochrome", "-compress", "Fax"), mode="Bitmap")
sample("tiff", "palette8", "tif", mk("o", "-colors", "200", "-type", "Palette"), depth=8)
sample("tiff", "cmyk8", "tif", mk("o", "-colorspace", "CMYK", "-depth", "8"), depth=8, mode="Cmyk")
sample("tiff", "cmyk16", "tif", mk("o", "-colorspace", "CMYK", "-depth", "16"), depth=16, mode="Cmyk")
sample("tiff", "rgb16-planar", "tif", mk("o", "-depth", "16", "-interlace", "Plane"), depth=16)
sample("tiff", "rgba8-planar", "tif", lambda d, out: [[M, os.path.join(d, RGBA), "-depth", "8", out + ".src.tif"], ["tiffcp", "-p", "separate", out + ".src.tif", out]], depth=8, alpha=True)
# ImageMagick misreads planar gray + alpha (it shows white): the reference is the interleaved
# file the sample was copied from.
sample("tiff", "graya8-planar", "tif", lambda d, out: [[M, os.path.join(d, RGBA), "-colorspace", "Gray", "-depth", "8", out + ".src.tif"], ["tiffcp", "-p", "separate", out + ".src.tif", out]], ref=lambda f, t: [[M, f + ".src.tif", "-depth", "16", f"PNG:{t}"]], depth=8, mode="Grayscale", alpha=True)
sample("tiff", "rgb8-tiled", "tif", mk("b", "-depth", "8", "-define", "tiff:tile-geometry=64x64", "-compress", "Zip"), depth=8)
sample("tiff", "rgb8-strips", "tif", mk("b", "-depth", "8", "-define", "tiff:rows-per-strip=7", "-compress", "LZW"), depth=8)
sample("tiff", "rgb8-bigendian", "tif", mk("o", "-depth", "8", "-endian", "MSB", "-compress", "LZW"), depth=8)
sample("tiff", "bigtiff", "tif", lambda d, out: [[M, os.path.join(d, RGB), "-depth", "8", f"TIFF64:{out}"]], depth=8)
sample("tiff", "ycbcr-jpeg", "tif", lambda d, out: [[M, os.path.join(d, RGB), "-depth", "8", out + ".src.tif"], ["tiffcp", "-c", "jpeg:90", "-r", "16", out + ".src.tif", out]], tol="lossy", depth=8)
sample("tiff", "multipage-first", "tif", lambda d, out: [[M, os.path.join(d, RGB), os.path.join(d, BIG), "-depth", "8", out]], depth=8)

# ---------------------------------------------------------------- WebP
sample("webp", "lossy", "webp", mk2("o", lambda p, o: ["cwebp", "-quiet", "-q", "85", p, "-o", o]), ref=lambda f, t: [["dwebp", "-quiet", f, "-o", t]], tol="lossy", depth=8)
sample("webp", "lossy-alpha", "webp", mk2("a", lambda p, o: ["cwebp", "-quiet", "-q", "85", "-exact", p, "-o", o]), ref=lambda f, t: [["dwebp", "-quiet", f, "-o", t]], tol="lossy", depth=8, alpha=True)
sample("webp", "lossless", "webp", mk2("a", lambda p, o: ["cwebp", "-quiet", "-lossless", "-exact", p, "-o", o]), depth=8, alpha=True)
sample("webp", "near-lossless", "webp", mk2("o", lambda p, o: ["cwebp", "-quiet", "-near_lossless", "60", p, "-o", o]), ref=lambda f, t: [["dwebp", "-quiet", f, "-o", t]], tol="lossy", depth=8)
sample("webp", "animated-frame1", "webp", lambda d, out: [[M, os.path.join(d, RGB), "-depth", "8", out + ".a.png"], [M, os.path.join(d, RGB), "-negate", "-depth", "8", out + ".b.png"], ["img2webp", "-lossless", out + ".a.png", out + ".b.png", "-o", out]], depth=8)

# ---------------------------------------------------------------- GIF
sample("gif", "palette", "gif", mk("o", "-colors", "256"), depth=8)
sample("gif", "transparent", "gif", mk("a", "-channel", "A", "-threshold", "50%", "+channel", "-colors", "128"), depth=8, alpha=True)
sample("gif", "interlaced", "gif", mk("o", "-colors", "64", "-interlace", "GIF"), depth=8)
sample("gif", "animated-frame1", "gif", lambda d, out: [[M, os.path.join(d, RGB), "(", os.path.join(d, RGB), "-negate", ")", "-colors", "256", "-delay", "20", out]], depth=8)

# ---------------------------------------------------------------- BMP (bmpsuite covers the odd ones)
sample("bmp", "rgb24", "bmp", mk("o", "-type", "TrueColor", "BMP3:-"), depth=8)
sample("bmp", "rgba32-v5", "bmp", mk("a", "-depth", "8", "BMP:-"), depth=8, alpha=True)
sample("bmp", "palette8", "bmp", mk("o", "-colors", "256", "-type", "Palette", "BMP3:-"), depth=8)
sample("bmp", "palette4-rle", "bmp", mk("o", "-colors", "16", "-type", "Palette", "-compress", "RLE", "BMP3:-"), depth=8)
sample("bmp", "palette1", "bmp", mk("o", "-colorspace", "Gray", "-monochrome", "BMP3:-"), depth=8)
sample("bmp", "os2-v2", "bmp", mk("o", "-type", "TrueColor", "BMP2:-"), depth=8)

# ---------------------------------------------------------------- TGA
sample("tga", "rgb24", "tga", mk("o", "-depth", "8", "-compress", "None"), depth=8)
sample("tga", "rgba32-rle", "tga", mk("a", "-depth", "8", "-compress", "RLE"), depth=8, alpha=True)
sample("tga", "rgba32", "tga", mk("a", "-depth", "8", "-compress", "None"), depth=8, alpha=True)
sample("tga", "rgba32-rle-bottom-left", "tga", mk("a", "-depth", "8", "-compress", "RLE", "-orient", "BottomLeft"), depth=8, alpha=True)
sample("tga", "gray8", "tga", mk("o", "-colorspace", "Gray", "-depth", "8"), depth=8, mode="Grayscale")
sample("tga", "palette8", "tga", mk("o", "-colors", "200", "-type", "Palette", "-compress", "None"), depth=8)
sample("tga", "top-left-origin", "tga", mk("o", "-depth", "8", "-orient", "TopLeft"), depth=8)

# ---------------------------------------------------------------- ICO, Netpbm, PCX, XPM, QOI, DDS
sample("ico", "png-entry", "ico", lambda d, out: [[M, os.path.join(d, RGBA), "-resize", "64x64!", "-depth", "8", "-define", "icon:format=png", out]], depth=8, alpha=True)
sample("ico", "bmp-entry", "ico", lambda d, out: [[M, os.path.join(d, RGBA), "-resize", "48x48!", "-depth", "8", "-define", "icon:format=bmp", out]], depth=8, alpha=True)
for kind, args, exp in [
    ("pbm-ascii", ["-monochrome", "-compress", "None", "PBM:-"], dict(mode="Bitmap")),
    ("pbm", ["-monochrome", "PBM:-"], dict(mode="Bitmap")),
    ("pgm16", ["-colorspace", "Gray", "-depth", "16", "PGM:-"], dict(depth=16, mode="Grayscale")),
    ("pgm-ascii", ["-colorspace", "Gray", "-depth", "8", "-compress", "None", "PGM:-"], dict(depth=8, mode="Grayscale")),
    ("ppm16", ["-depth", "16", "PPM:-"], dict(depth=16)),
    ("ppm-ascii", ["-depth", "8", "-compress", "None", "PPM:-"], dict(depth=8)),
]:
    sample("pnm", kind, kind.split("-")[0].rstrip("16") or "pnm", mk("o", *args), **exp)
sample("pnm", "pam-rgba16", "pam", mk("a", "-depth", "16"), depth=16, alpha=True)
sample("pnm", "pfm-rgb", "pfm", mk("f"), depth=32)
sample("pnm", "pfm-gray-bigendian", "pfm", mk("f", "-colorspace", "Gray", "-endian", "MSB"), depth=32, mode="Grayscale")
sample("pcx", "rgb24", "pcx", mk("o", "-type", "TrueColor"), depth=8)
sample("pcx", "palette8", "pcx", mk("o", "-colors", "256", "-type", "Palette"), depth=8)
# ImageMagick writes (and reads) 1-bit PCX inverted: 1 = black. Pillow follows ZSoft (1 = white).
sample("pcx", "bilevel", "pcx", lambda d, out: [[M, os.path.join(d, RGB), "-depth", "8", out + ".src.png"], ["PILLOW", out + ".src.png", out, "1"]], ref=lambda f, t: [["PILLOW_REF", f, t]], depth=8)
sample("xpm", "palette", "xpm", mk("a", "-colors", "64"), depth=8, alpha=True)
sample("qoi", "rgba", "qoi", mk("a", "-depth", "8"), depth=8, alpha=True)
sample("qoi", "rgb", "qoi", mk("o", "-depth", "8"), depth=8)
sample("dds", "rgba-uncompressed", "dds", mk("a", "-define", "dds:compression=none"), depth=8, alpha=True)
sample("dds", "dxt1", "dds", mk("o", "-define", "dds:compression=dxt1"), tol="lossy", depth=8)
sample("dds", "dxt3", "dds", mk("a", "-define", "dds:compression=dxt3"), tol="lossy", depth=8, alpha=True)
sample("dds", "dxt5", "dds", mk("a", "-define", "dds:compression=dxt5"), tol="lossy", depth=8, alpha=True)
sample("dds", "mipmaps", "dds", mk("a", "-define", "dds:compression=none", "-define", "dds:mipmaps=3"), depth=8, alpha=True)

# ---------------------------------------------------------------- HDR and film
for c in ("None", "RLE", "Zip", "ZipS", "Piz", "Pxr24", "B44", "B44A", "DWAA"):
    lossy = c in ("Pxr24", "B44", "B44A", "DWAA")
    sample("exr", f"half-{c.lower()}", "exr", mk("f", "-compress", c), tol="lossy" if lossy else "exact", depth=32)
sample("exr", "float-zip", "exr", mk("f", "-define", "exr:color-type=RGB", "-define", "quantum:format=floating-point", "-depth", "32", "-compress", "Zip"), depth=32)
sample("hdr", "rle", "hdr", mk("f"), tol="loose", depth=32)
sample("fits", "bitpix8", "fits", mk("o", "-colorspace", "Gray", "-depth", "8"), depth=8, mode="Grayscale")
sample("fits", "bitpix16", "fits", mk("o", "-colorspace", "Gray", "-depth", "16"), depth=16, mode="Grayscale")
# ImageMagick's float FITS carries an integer-style BZERO it can't read back, and it reads only the
# first plane of a cube: these are written here to the FITS standard, referenced from the chart.
# Floats up to 2 read as already normalised; larger ones as ADU, scaled by 65535 (fits.rs).
for bitpix in (-32, -64, 32):
    sample("fits", f"bitpix{bitpix}", "fits", lambda d, out, b=bitpix: [["FITS", out, b, 1]], ref=lambda f, t, b=bitpix: [["FITS_REF", t, b, 1]], depth=32, mode="Grayscale")
sample("fits", "bitpix-32-adu", "fits", lambda d, out: [["FITS", out, -32, 1, 30000.0]], ref=lambda f, t: [["FITS_REF", t, -32, 1, 30000.0 / 65535]], depth=32, mode="Grayscale")
sample("fits", "rgb-cube16", "fits", lambda d, out: [["FITS", out, 16, 3]], ref=lambda f, t: [["FITS_REF", t, 16, 3]], depth=16)
sample("dpx", "rgb10", "dpx", mk("o", "-depth", "10"), depth=16)
sample("dpx", "rgb16-bigendian", "dpx", mk("o", "-depth", "16", "-endian", "MSB"), depth=16)
sample("dpx", "rgb8", "dpx", mk("o", "-depth", "8"), depth=8)
sample("dpx", "rgba16", "dpx", mk("a", "-depth", "16"), depth=16, alpha=True)
# Cineon holds log codes and opens with them unchanged (labelled log, as DPX): the reference is the
# file's own codes, not ImageMagick's log-to-linear conversion.
sample("cineon", "rgb10", "cin", mk("o", "-depth", "10"), ref=lambda f, t: [["CIN_REF", f, t]], depth=16)

# ---------------------------------------------------------------- HEIF, AVIF, JPEG XL
# HEIC through Apple's own encoder and decoder (sips): 8-bit, as iPhones write it. The 10-bit,
# 4:4:4 and lossless variants are in the pinned HEIF corpus (heic-rs and pillow-heif samples).
heif_ref = lambda f, t: [["sips", "-s", "format", "png", f, "--out", t]]
avif_ref = lambda f, t: [["avifdec", "--depth", "16", f, t]]
jxl_ref = lambda f, t: [["djxl", "--quiet", "--bits_per_sample=16", f, t]]
# Apple writes HEIC as 10-bit HEVC (Main 10), which opens as 16-bit.
sample("heif", "apple", "heic", mk2("o", lambda p, o: ["sips", "-s", "format", "heic", "-s", "formatOptions", "90", p, "--out", o]), ref=heif_ref, tol="lossy", depth=16)
sample("heif", "apple-alpha", "heic", mk2("a", lambda p, o: ["sips", "-s", "format", "heic", "-s", "formatOptions", "90", p, "--out", o]), ref=heif_ref, tol="lossy", depth=16, alpha=True)
for name, args, exp in [
    ("8bit-420", ["-d", "8", "-y", "420", "-q", "80"], dict(depth=8)),
    ("8bit-444", ["-d", "8", "-y", "444", "-q", "80"], dict(depth=8)),
    ("10bit", ["-d", "10", "-y", "444", "-q", "80"], dict(depth=16)),
    ("12bit", ["-d", "12", "-y", "444", "-q", "80"], dict(depth=16)),
    ("gray-400", ["-d", "8", "-y", "400", "-q", "80"], dict(depth=8, mode="Grayscale")),
    ("lossless", ["-l", "-d", "8"], dict(depth=8)),
]:
    sample("avif", name, "avif", lambda d, out, args=args: [[M, os.path.join(d, RGB), "-depth", "16", out + ".src.png"], ["avifenc", "-j", "1", *args, out + ".src.png", out]], ref=avif_ref, tol="lossy", **exp)
sample("avif", "alpha", "avif", lambda d, out: [[M, os.path.join(d, RGBA), "-depth", "8", out + ".src.png"], ["avifenc", "-j", "1", "-q", "80", out + ".src.png", out]], ref=avif_ref, tol="lossy", depth=8, alpha=True)
sample("jxl", "lossless", "jxl", mk2("a", lambda p, o: ["cjxl", "--quiet", "-d", "0", p, o]), ref=jxl_ref, depth=8, alpha=True, apple=True)
sample("jxl", "lossy", "jxl", mk2("o", lambda p, o: ["cjxl", "--quiet", "-d", "1", p, o]), ref=jxl_ref, tol="lossy", depth=8, apple=True)
sample("jxl", "8bit-lossless", "jxl", lambda d, out: [[M, os.path.join(d, RGBA), "-depth", "8", out + ".src.png"], ["cjxl", "--quiet", "-d", "0", out + ".src.png", out]], ref=jxl_ref, depth=8, alpha=True, apple=True)
sample("jxl", "gray-lossless", "jxl", lambda d, out: [[M, os.path.join(d, RGB), "-colorspace", "Gray", "-depth", "8", out + ".src.png"], ["cjxl", "--quiet", "-d", "0", out + ".src.png", out]], ref=jxl_ref, depth=8, mode="Grayscale", apple=True)
sample("jxl", "hdr-float", "jxl", lambda d, out: [["cjxl", "--quiet", "-d", "0", os.path.join(d, "hdr.pfm"), out]], ref=lambda f, t: [["djxl", "--quiet", f, t]], ref_ext=".pfm", depth=32, apple=True)
sample("jxl", "animated-frame1", "jxl", lambda d, out: [["ffmpeg", "-loglevel", "error", "-y", "-i", os.path.join(d, "rgb8.png"), "-i", os.path.join(d, "rgb8.png"), "-filter_complex", "[0][1]concat=n=2:v=1", "-plays", "0", "-f", "apng", out + ".src.png"], ["cjxl", "--quiet", "-d", "0", out + ".src.png", out]], ref=lambda f, t: [[M, os.path.join(os.path.dirname(os.path.dirname(f)), "rgb8.png"), t]], depth=8, apple=True)
sample("jxl", "16bit-lossless", "jxl", lambda d, out: [[M, os.path.join(d, RGB), "-depth", "16", out + ".src.png"], ["cjxl", "--quiet", "-d", "0", out + ".src.png", out]], ref=jxl_ref, depth=16, apple=True)


# ---------------------------------------------------------------- OpenRaster (spec: openraster.org)
def ora(d, out):
    """Two layers: the chart, and a half-transparent red square on top at an offset."""
    base, top = out + ".base.png", out + ".top.png"
    return [[M, os.path.join(d, RGB), "-depth", "8", f"PNG24:{base}"], [M, "-size", "40x30", "xc:#ff000080", f"PNG32:{top}"], ["ORA", base, top, out]]


sample("ora", "two-layers", "ora", ora, ref=lambda f, t: [[M, f + ".base.png", f + ".top.png", "-geometry", "+20+15", "-composite", "-depth", "16", t]], depth=8, layers=2)


def write_ora(base, top, out):
    stack = f"""<?xml version='1.0' encoding='UTF-8'?>
<image version="0.0.3" w="{W}" h="{H}">
 <stack>
  <layer name="top" src="data/top.png" x="20" y="15" opacity="1.0" composite-op="svg:src-over"/>
  <layer name="base" src="data/base.png" x="0" y="0" opacity="1.0"/>
 </stack>
</image>
"""
    with zipfile.ZipFile(out, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "image/openraster", compress_type=zipfile.ZIP_STORED)
        z.writestr("stack.xml", stack)
        z.write(base, "data/base.png")
        z.write(top, "data/top.png")


def premultiplied(w, h):
    """The RGBA chart premultiplied, as 16-bit samples."""
    out = []
    for y in range(h):
        for x in range(w):
            r, g, b, a = chart(x, y, w, h, True)
            out.append((round(r * a * 65535), round(g * a * 65535), round(b * a * 65535), round(a * 65535)))
    return out


def write_associated_tiff(out):
    px = premultiplied(W, H)
    data = b"".join(struct.pack("<4H", *p) for p in px)
    tags = [(256, 3, 1, W), (257, 3, 1, H), (258, 3, 4, None), (259, 3, 1, 1), (262, 3, 1, 2), (273, 4, 1, None), (277, 3, 1, 4), (278, 3, 1, H), (279, 4, 1, len(data)), (284, 3, 1, 1), (338, 3, 1, 1)]
    ifd_at = 8
    extra_at = ifd_at + 2 + len(tags) * 12 + 4
    data_at = extra_at + 8
    ifd = struct.pack("<H", len(tags))
    for tag, typ, count, value in tags:
        if tag == 258:
            ifd += struct.pack("<HHII", tag, typ, count, extra_at)
        elif tag == 273:
            ifd += struct.pack("<HHII", tag, typ, count, data_at)
        elif typ == 3:
            ifd += struct.pack("<HHIHH", tag, typ, count, value, 0)
        else:
            ifd += struct.pack("<HHII", tag, typ, count, value)
    with open(out, "wb") as f:
        f.write(b"II*\0" + struct.pack("<I", ifd_at) + ifd + struct.pack("<I", 0) + struct.pack("<4H", 16, 16, 16, 16) + data)


def write_straight_pam(t):
    rows = bytearray()
    for r, g, b, a in premultiplied(W, H):
        for c in (r, g, b):
            rows += struct.pack(">H", min(65535, round(c * 65535 / a)) if a else 0)
        rows += struct.pack(">H", a)
    with open(t, "wb") as f:
        f.write(f"P7\nWIDTH {W}\nHEIGHT {H}\nDEPTH 4\nMAXVAL 65535\nTUPLTYPE RGB_ALPHA\nENDHDR\n".encode() + rows)


def fits_values(bitpix, planes):
    """Plane-major rows, top row first: grey from the HDR chart, kept under 2 (floats), or the
    16-bit chart."""
    out = []
    for p in range(planes):
        for y in range(H):
            for x in range(W):
                r, g, b, _ = chart(x, y, W, H, False)
                if bitpix < 0:
                    out.append(0.8 * (0.2126 * r * 4 + 0.7152 * g * 2 + 0.0722 * b * 0.5))
                elif bitpix == 32:
                    out.append(round((0.2126 * r + 0.7152 * g + 0.0722 * b) * 65535))
                else:
                    out.append(round((r, g, b)[p] * 65535))
    return out


def write_fits(out, bitpix, planes, scale=1.0):
    cards = ["SIMPLE  =                    T", f"BITPIX  = {bitpix:>20}", f"NAXIS   = {3 if planes > 1 else 2:>20}", f"NAXIS1  = {W:>20}", f"NAXIS2  = {H:>20}"]
    if planes > 1:
        cards.append(f"NAXIS3  = {planes:>20}")
    if bitpix == 16:
        cards += ["BZERO   =              32768.0", "BSCALE  =                  1.0"]
    cards.append("END")
    head = "".join(c.ljust(80) for c in cards)
    head = head.ljust((len(head) + 2879) // 2880 * 2880)
    v = [x * scale for x in fits_values(bitpix, planes)] if bitpix < 0 else fits_values(bitpix, planes)
    # FITS rows run bottom-up: the first row stored is the bottom one.
    rows = [v[p * W * H + y * W : p * W * H + (y + 1) * W] for p in range(planes) for y in reversed(range(H))]
    fmt = {-32: ">f", -64: ">d", 32: ">i", 16: ">h"}[bitpix]
    data = b"".join(struct.pack(fmt, (x - 32768) if bitpix == 16 else x) for row in rows for x in row)
    data = data.ljust((len(data) + 2879) // 2880 * 2880, b"\0")
    with open(out, "wb") as f:
        f.write(head.encode() + data)


def write_fits_ref(t, bitpix, planes, scale=1.0):
    """The values the file holds (times `scale`), as a PFM (floats) or 16-bit PAM, top row first."""
    v = [x * scale for x in fits_values(bitpix, planes)] if bitpix < 0 else fits_values(bitpix, planes)
    if bitpix < 0:
        data = b"".join(struct.pack("<3f", *(v[y * W + x],) * 3) for y in reversed(range(H)) for x in range(W))
        with open(t, "wb") as f:
            f.write(f"PF\n{W} {H}\n-1.0\n".encode() + data)
        return
    rows = bytearray()
    for y in range(H):
        for x in range(W):
            for p in range(3):
                q = v[(p if planes > 1 else 0) * W * H + y * W + x]
                rows += struct.pack(">H", min(65535, q))
    with open(t, "wb") as f:
        f.write(f"P7\nWIDTH {W}\nHEIGHT {H}\nDEPTH 3\nMAXVAL 65535\nTUPLTYPE RGB\nENDHDR\n".encode() + rows)


def write_cineon_ref(cin, t):
    """10-bit RGB codes, three to a big-endian word with the padding at the bottom, as 16-bit."""
    with open(cin, "rb") as f:
        b = f.read()
    off, w, h = struct.unpack(">I", b[4:8])[0], struct.unpack(">I", b[200:204])[0], struct.unpack(">I", b[204:208])[0]
    rows = bytearray()
    for y in range(h):
        for x in range(w):
            v = struct.unpack(">I", b[off + (y * w + x) * 4 : off + (y * w + x) * 4 + 4])[0]
            for c in ((v >> 22) & 1023, (v >> 12) & 1023, (v >> 2) & 1023):
                rows += struct.pack(">H", round(c * 65535 / 1023))
    with open(t, "wb") as f:
        f.write(f"P7\nWIDTH {w}\nHEIGHT {h}\nDEPTH 3\nMAXVAL 65535\nTUPLTYPE RGB\nENDHDR\n".encode() + rows)


def run(cmd, log):
    if cmd[0] in ("PILLOW", "PILLOW_REF"):
        from PIL import Image

        if cmd[0] == "PILLOW":
            Image.open(cmd[1]).convert(cmd[3]).save(cmd[2])
        else:
            Image.open(cmd[1]).convert("RGB").save(cmd[2])
        return True
    if cmd[0] == "CIN_REF":
        write_cineon_ref(*cmd[1:])
        return True
    if cmd[0] == "FITS":
        write_fits(*cmd[1:])
        return True
    if cmd[0] == "FITS_REF":
        write_fits_ref(*cmd[1:])
        return True
    if cmd[0] == "ORA":
        write_ora(*cmd[1:])
        return True
    if cmd[0] == "ASSOC_TIFF":
        write_associated_tiff(cmd[1])
        return True
    if cmd[0] == "ASSOC_REF":
        write_straight_pam(cmd[2])
        return True
    if not shutil.which(cmd[0]):
        log.append(f"missing tool {cmd[0]}")
        return False
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        log.append(f"{' '.join(cmd)}: {p.stderr.strip()[:300]}")
        return False
    return True


SUITES = {
    # Directory: URL prefix at a pinned commit.
    "libtiff": "https://gitlab.com/libtiff/libtiff/-/raw/d23249978a7a99ea2e0752a476611914501577de/test/images/",
    "libjpeg-turbo": "https://raw.githubusercontent.com/libjpeg-turbo/libjpeg-turbo/36956793b60deb2d1169d1432be6d19871f5ecb1/testimages/",
    # The JPEG XL conformance inputs (BSD-3-Clause): layers, blend modes, CMYK, spot colours,
    # animation, orientation, premultiplied alpha, floats. Referenced by djxl (libjxl).
    "jxl-conformance": "https://raw.githubusercontent.com/libjxl/conformance/b1d0f990b03e57bf6d137c365cd5dc8b470b9191/testcases/",
}


def planar_graya_packbits_ref(path, t):
    """libtiff's minisblack-2c-8b-alpha.tiff by hand (ImageMagick misreads planar gray + alpha, and
    Pillow and tiffcp can't read it): two PackBits planes, associated alpha made straight."""
    def tag(name):
        return [int(v) for v in subprocess.check_output(["exiftool", "-m", "-s", "-s", "-s", f"-{name}", path], text=True).split()]

    def unpack(d):
        out, i = bytearray(), 0
        while i < len(d):
            n = d[i]
            i += 1
            if n < 128:
                out += d[i : i + n + 1]
                i += n + 1
            elif n > 128:
                out += bytes([d[i]]) * (257 - n)
                i += 1
        return out

    with open(path, "rb") as f:
        b = f.read()
    offs, counts, w, h = tag("StripOffsets"), tag("StripByteCounts"), tag("ImageWidth")[0], tag("ImageHeight")[0]
    per = len(offs) // 2
    gray = b"".join(unpack(b[offs[k] : offs[k] + counts[k]]) for k in range(per))
    alpha = b"".join(unpack(b[offs[k] : offs[k] + counts[k]]) for k in range(per, 2 * per))
    rows = bytearray()
    for i in range(w * h):
        g = round(gray[i] * 255 / alpha[i]) if alpha[i] else 0
        rows += bytes([min(255, g)] * 3 + [alpha[i]])
    with open(t, "wb") as f:
        f.write(f"P7\nWIDTH {w}\nHEIGHT {h}\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n".encode() + rows)


# Suite files ImageMagick decodes wrongly, with the decoder to use instead.
SUITE_REFS = {"libtiff/minisblack-2c-8b-alpha.tiff": planar_graya_packbits_ref}


def fetch_suites(manifest, skipped):
    """Downloads the pinned public test images (checked by sha256) and adds each with a reference
    decode by ImageMagick (libtiff, libjpeg-turbo). Files ImageMagick can't decode either (IFD
    loops and other hostile files) are added to be opened without crashing or hanging."""
    import hashlib

    pins = os.path.join(os.path.dirname(os.path.abspath(__file__)), "format_suites.sha256")
    root = os.path.join(os.path.dirname(OUT), "formats-suites")
    with open(pins) as f:
        lines = [l.split(None, 1) for l in f if l.strip() and not l.startswith("#")]
    for sha, rel in ((a, b.strip()) for a, b in lines):
        suite, name = rel.split("/", 1)
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            log = []
            if not run(["curl", "-fsSL", "--retry", "3", "-A", "Photocraft-dev", "-o", path, SUITES[suite] + name], log):
                skipped.append((suite, name, "download: " + (log[-1] if log else "failed")))
                continue
        with open(path, "rb") as f:
            if hashlib.sha256(f.read()).hexdigest() != sha:
                skipped.append((suite, name, "sha256 mismatch"))
                continue
        if name.endswith("/ref.png"):
            continue  # a conformance case's official rendering, used by its input below
        ref = path + ".ref"
        official = os.path.join(os.path.dirname(path), "ref.png")
        # blendmodes' ref.png disagrees with libjxl itself (djxl) on colour under partial alpha
        # (its alpha matches): djxl is its reference.
        if suite == "jxl-conformance" and os.path.exists(official) and not name.startswith("blendmodes/"):
            # The case's official rendering (in the image's own profile), converted to sRGB through
            # that profile: compared with the document shown in sRGB.
            srgb_icc = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"
            convert = ["-profile", srgb_icc] if subprocess.run([M, "identify", "-format", "%[profile:icc]", official], capture_output=True, text=True).stdout.strip() else []
            ok = run([M, official, *convert, "-depth", "32", "-define", "quantum:format=floating-point", f"RGBA:{ref}"], [])
            info = subprocess.run([M, "identify", "-format", "%w %h\n", official], capture_output=True, text=True).stdout.split()
            entry = dict(file=os.path.relpath(path, OUT), format=suite, option=name.split("/")[0], tolerance="lossy", srgb=True, expect={"mode": "*"})
            if ok and len(info) >= 2:
                entry.update(width=int(info[0]), height=int(info[1]), reference=os.path.relpath(ref, OUT), channels=4)
            else:
                entry.update(open_only=True)
            manifest.append(entry)
            continue
        if suite == "jxl-conformance":
            # No official rendering (the animations): djxl, which decodes the first frame as we open it.
            # Floating-point files to PFM, which keeps values past 1 (and has no alpha).
            floats = "float" in subprocess.run(["jxlinfo", path], capture_output=True, text=True).stdout
            png = path + (".ref.pfm" if floats else ".ref.png")
            ok = run(["djxl", "--quiet", path, png] if floats else ["djxl", "--quiet", "--bits_per_sample=16", path, png], []) and run([M, f"{png}[0]", "-depth", "32", "-define", "quantum:format=floating-point", f"RGBA:{ref}"], [])
            info = subprocess.run([M, "identify", "-format", "%w %h\n", f"{png}[0]"], capture_output=True, text=True).stdout.split()
            entry = dict(file=os.path.relpath(path, OUT), format=suite, option=name.split("/")[0], tolerance="lossy", expect={"mode": "*"})
            if ok and len(info) >= 2:
                entry.update(width=int(info[0]), height=int(info[1]), reference=os.path.relpath(ref, OUT), channels=4)
            else:
                entry.update(open_only=True)
            manifest.append(entry)
            continue
        info = subprocess.run([M, "identify", "-format", "%w %h %[colorspace]\n", f"{path}[0]"], capture_output=True, text=True).stdout.split()
        space = "CMYKA" if len(info) > 2 and info[2] == "CMYK" else "RGBA"
        source = f"{path}[0]"
        if rel in SUITE_REFS:
            source = path + ".ref.pam"
            SUITE_REFS[rel](path, source)
        ok = len(info) > 2 and run([M, source, "-depth", "32", "-define", "quantum:format=floating-point", f"{space}:{ref}"], [])
        compression = subprocess.run([M, "identify", "-format", "%[compression]", f"{path}[0]"], capture_output=True, text=True).stdout
        lossy = compression in ("JPEG", "OJPEG", "WebP") or name.lower().endswith((".jpg", ".jpeg"))
        entry = dict(file=os.path.relpath(path, OUT), format=suite, option=name, tolerance="lossy" if lossy else "exact", expect={"mode": "*"})
        if ok:
            entry.update(width=int(info[0]), height=int(info[1]), reference=os.path.relpath(ref, OUT), channels=5 if space == "CMYKA" else 4)
        else:
            entry.update(open_only=True)
        manifest.append(entry)


def main():
    os.makedirs(OUT, exist_ok=True)
    write_pam(os.path.join(OUT, RGBA), W, H, True)
    write_pam(os.path.join(OUT, RGB), W, H, False)
    write_pam(os.path.join(OUT, BIG), BW, BH, False)
    write_pfm(os.path.join(OUT, "hdr.pfm"), W, H)
    run([M, os.path.join(OUT, RGB), "-depth", "8", os.path.join(OUT, "rgb8.png")], [])
    manifest, skipped = [], []
    for s in SAMPLES:
        d = os.path.join(OUT, s["fmt"])
        os.makedirs(d, exist_ok=True)
        out = os.path.join(d, f"{s['name']}.{s['ext']}")
        log = []
        if not all(run(c, log) for c in s["make"](OUT, out)):
            skipped.append((s["fmt"], s["name"], log[-1] if log else "failed"))
            continue
        ref = out + ".ref"
        if s["ref"]:
            tmp = out + ".ref" + s["ref_ext"]
            ok = all(run(c, log) for c in s["ref"](out, tmp)) and run([M, tmp, "-depth", "32", "-define", "quantum:format=floating-point", f"RGBA:{ref}"], log)
        else:
            orient = ["-auto-orient"] if s["expect"].get("orient") else []
            space = "CMYKA" if s["expect"].get("mode") == "Cmyk" else "RGBA"
            ok = run([M, f"{out}[0]", *orient, "-depth", "32", "-define", "quantum:format=floating-point", f"{space}:{ref}"], log)
        if not ok:
            skipped.append((s["fmt"], s["name"], "reference decode: " + (log[-1] if log else "failed")))
            continue
        size_src = out + ".ref" + s["ref_ext"] if s["ref"] else f"{out}[0]"
        idn = subprocess.run([M, size_src, "-auto-orient", "-format", "%w %h", "info:"], capture_output=True, text=True).stdout.split()
        w, h = int(idn[0]), int(idn[1])
        manifest.append(dict(file=os.path.relpath(out, OUT), format=s["fmt"], option=s["name"], width=w, height=h, reference=os.path.relpath(ref, OUT), channels=5 if s["expect"].get("mode") == "Cmyk" else 4, tolerance=s["tol"], expect=s["expect"]))
    fetch_suites(manifest, skipped)
    with open(os.path.join(OUT, "manifest.json"), "w") as f:
        json.dump(dict(samples=manifest, skipped=[dict(format=a, option=b, why=c) for a, b, c in skipped]), f, indent=1)
    print(f"{len(manifest)} samples in {OUT}; {len(skipped)} skipped")
    for a, b, c in skipped:
        print(f"  skipped {a}/{b}: {c}")


if __name__ == "__main__":
    main()

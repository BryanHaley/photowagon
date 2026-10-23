"""Writes the brush files the walkthroughs import (original, generated): a GIMP brush (.gbr), a
GIMP generated brush (.vbr), a PNG tip, a Krita preset (.kpp) and a Krita bundle (.bundle) holding
tips and a preset.
The photos here are CC0 (see CREDITS.md). Run: python3 make_samples.py"""
import io
import random
import struct
import zipfile

from PIL import Image, ImageDraw, ImageFilter, PngImagePlugin

random.seed(7)


def gbr(name, img):
    """GIMP brush v2, 1 byte per pixel; 255 = full paint."""
    w, h = img.size
    label = name.encode() + b"\0"
    header = struct.pack(">IIIII", 28 + len(label), 2, w, h, 1) + b"GIMP" + struct.pack(">I", 20) + label
    return header + img.tobytes()


# A speckled dry-media tip: paint is white in GIMP's convention.
speckle = Image.new("L", (64, 64), 0)
d = ImageDraw.Draw(speckle)
for _ in range(220):
    x, y, r = random.gauss(32, 11), random.gauss(32, 11), random.uniform(0.6, 2.4)
    d.ellipse([x - r, y - r, x + r, y + r], fill=random.randint(140, 255))
speckle = speckle.filter(ImageFilter.GaussianBlur(0.6))
open("speckle.gbr", "wb").write(gbr("Speckle", speckle))

open("oval.vbr", "w").write("GIMP-VBR\n1.0\nOval\n15\n30\n0.6\n2.5\n30\n")

# A PNG tip, Photoshop's convention: dark pixels paint.
star = Image.new("L", (96, 96), 255)
d = ImageDraw.Draw(star)
d.polygon([(48, 4), (60, 36), (94, 38), (66, 58), (76, 92), (48, 72), (20, 92), (30, 58), (2, 38), (36, 36)], fill=0)
star.save("star.png")

def kpp(name, brush):
    """A Krita preset: a PNG preview whose compressed `preset` text holds the settings."""
    xml = (f'<Preset paintopid="paintbrush" name="{name}"><param type="string" name="brush_definition">'
           f'<![CDATA[{brush}]]></param></Preset>')
    info = PngImagePlugin.PngInfo()
    info.add_text("version", "2.2")
    info.add_text("preset", xml, zip=True)
    out = io.BytesIO()
    Image.new("RGB", (32, 32), "white").save(out, "PNG", pnginfo=info)
    return out.getvalue()


open("inky.kpp", "wb").write(kpp("Inky", '<Brush type="auto_brush" spacing="0.1" angle="0">'
                                 '<MaskGenerator type="circle" id="default" diameter="60" ratio="0.6" hfade="0.4"/></Brush>'))

grain = Image.effect_noise((48, 48), 90).filter(ImageFilter.GaussianBlur(1))
bundle = io.BytesIO()
with zipfile.ZipFile(bundle, "w") as z:
    z.writestr("mimetype", "application/x-krita-resourcebundle")
    z.writestr("brushes/grain.gbr", gbr("Grain", grain))
    png = io.BytesIO()
    star.rotate(36).save(png, "PNG")
    z.writestr("brushes/star.png", png.getvalue())
    z.writestr("paintoppresets/grain-dab.kpp", kpp("Grain Dab", '<Brush type="gbr_brush" filename="grain.gbr" spacing="0.3" scale="1.5"/>'))
open("tips.bundle", "wb").write(bundle.getvalue())

# --- The Layers walkthrough ---

# The CC0 seaside photo (see CREDITS.md), from the downloaded original if it is here.
import os
if os.path.exists("seaside-original.jpg"):
    sea = Image.open("seaside-original.jpg").convert("RGB").resize((1600, 900), Image.LANCZOS)
    sea.save("seaside.jpg", quality=88)
    # A crooked copy for Straighten: turned 3°, then cropped back inside the turned frame.
    w, h = sea.size
    turned = sea.rotate(3, resample=Image.BICUBIC)
    m = 60
    turned.crop((m, m, w - m, h - m)).resize((1600, 900), Image.LANCZOS).save("seaside-crooked.jpg", quality=88)

# A light leak texture: warm bands, blurred, with a little grain.
leak = Image.new("RGB", (1600, 1000))
d = ImageDraw.Draw(leak)
bands = [(0, (40, 20, 10)), (260, (230, 90, 30)), (520, (250, 190, 60)), (760, (30, 30, 25)), (1100, (200, 60, 40)), (1400, (250, 160, 80)), (1600, (60, 30, 20))]
for (x0, c0), (x1, c1) in zip(bands, bands[1:]):
    for x in range(x0, x1):
        t = (x - x0) / max(x1 - x0, 1)
        d.line([(x, 0), (x, 1000)], fill=tuple(int(a + (b - a) * t) for a, b in zip(c0, c1)))
leak = leak.filter(ImageFilter.GaussianBlur(40))
noise = Image.effect_noise((1600, 1000), 24).convert("RGB")
Image.blend(leak, noise, 0.06).save("light-leak.jpg", quality=90)

# A bee on white, to take the white away with the Magic Wand.
bee = Image.new("RGB", (1000, 1000), "white")
d = ImageDraw.Draw(bee)
d.ellipse([420, 260, 560, 460], fill=(170, 220, 250), outline=(60, 60, 60), width=6)
d.ellipse([540, 240, 700, 450], fill=(170, 220, 250), outline=(60, 60, 60), width=6)
d.ellipse([280, 400, 760, 700], fill=(250, 200, 40), outline=(40, 40, 40), width=8)
for x in (430, 530, 630):
    d.rectangle([x, 410, x + 45, 690], fill=(30, 30, 30))
d.ellipse([300, 500, 340, 540], fill=(30, 30, 30))
d.line([(330, 430), (290, 340)], fill=(30, 30, 30), width=8)
d.line([(370, 420), (360, 330)], fill=(30, 30, 30), width=8)
bee.save("bee.jpg", quality=92)

# Purple to blue, to see what Tolerance takes in.
grad = Image.new("RGB", (1600, 1000))
d = ImageDraw.Draw(grad)
for x in range(1600):
    t = x / 1599
    d.line([(x, 0), (x, 1000)], fill=(int(200 - 170 * t), int(40 + 40 * t), int(160 + 90 * t)))
grad.save("blend.png")

# The bee alone (the design file's subject): white made transparent.
cut = bee.convert("RGBA")
cut.putdata([(r, g, b, 0 if min(r, g, b) > 245 else 255) for r, g, b, _ in cut.getdata()])
cut.crop(cut.getbbox()).save("bee-cutout.png")

# A concrete wall, lit from the top left: blotchy grey with grain.
blotch = Image.effect_noise((100, 60), 60).convert("L").resize((1600, 1000), Image.BICUBIC).filter(ImageFilter.GaussianBlur(12))
grain = Image.effect_noise((1600, 1000), 40).convert("L")
light = Image.new("L", (2, 2))
light.putdata([230, 130, 130, 40])
light = light.resize((1600, 1000), Image.BILINEAR)
wall = Image.blend(Image.blend(blotch, grain, 0.35), light, 0.3).point(lambda v: int(40 + v * 0.45))
Image.merge("RGB", (wall, wall, wall.point(lambda v: min(v + 4, 255)))).save("concrete.jpg", quality=88)

# design.psd (the layered design the Layers walkthrough opens), from the repository root:
#   S=$PWD/ios/PhotoWagonUITests/Samples; cargo run -q -p photocraft-cli -- run --new '{"width":1080,"height":1080,"name":"design"}' \
#     --cmd layer.newFillLayer.gradient --params '{"from":"#e3683b","to":"#9e1f1a","angle":90}' --cmd layer.renameLayer --params '{"name":"Gradient Background"}' \
#     --cmd type.create --params '{"x":540,"y":400,"text":"The Good","name":"The Good","align":"center","size":170,"color":"#ffffff"}' \
#     --cmd file.placeEmbedded --params "{\"path\":\"$S/bee-cutout.png\",\"scale\":130,\"center\":[560,560]}" --cmd layer.renameLayer --params '{"name":"subject"}' \
#     --cmd type.create --params '{"x":540,"y":820,"text":"Game","name":"Game","align":"center","size":170,"color":"#ffffff"}' --out $S/design.psd


# A water drop falling and splashing, eight transparent frames (drop-1.png … drop-8.png): frame 1
# the drop near the top, then it lands and splashes at the bottom.
def drop_frame(i):
    w, h, s = 640, 400, 4  # drawn 4× larger, then reduced for smooth edges
    img = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    blue, light = (42, 157, 244, 255), (140, 205, 250, 255)

    def drop(cx, cy, r):
        d.ellipse([(cx - r) * s, (cy - r) * s, (cx + r) * s, (cy + r) * s], fill=blue)
        d.polygon([((cx - r * 0.92) * s, (cy - r * 0.4) * s), (cx * s, (cy - r * 2.4) * s), ((cx + r * 0.92) * s, (cy - r * 0.4) * s)], fill=blue)
        d.ellipse([(cx - r * 0.45) * s, (cy - r * 0.55) * s, (cx - r * 0.1) * s, (cy - r * 0.1) * s], fill=light)

    floor = 330
    if i == 1:
        drop(320, 110, 22)
    else:
        k = i - 2  # 0 … 6: the splash grows, then settles into ripples
        spread = [8, 30, 60, 90, 120, 150, 170][k]
        height = [10, 40, 70, 60, 35, 15, 0][k]
        if k == 0:
            drop(320, floor - 30, 22)
        d.ellipse([(320 - spread * 1.6) * s, (floor - 10) * s, (320 + spread * 1.6) * s, (floor + 10) * s], outline=blue, width=4 * s)
        if height:
            for dx in (-1, 1):
                d.polygon([(320 * s, floor * s), ((320 + dx * spread * 0.6) * s, (floor - height) * s), ((320 + dx * spread * 0.9) * s, floor * s)], fill=blue)
            for n in range(5):
                a = -0.9 + n * 0.45
                x, y = 320 + a * spread * 1.2, floor - height * (1.3 - abs(a) * 0.4)
                d.ellipse([(x - 6) * s, (y - 6) * s, (x + 6) * s, (y + 6) * s], fill=blue)
    return img.resize((w, h), Image.Resampling.LANCZOS)


for i in range(1, 9):
    drop_frame(i).save(f"drop-{i}.png")


# Smoke on black, to add with Screen.
smoke = Image.new("L", (1600, 1000), 0)
d = ImageDraw.Draw(smoke)
for _ in range(220):
    x, y, r = random.randint(-100, 1700), random.randint(450, 1050), random.randint(30, 140)
    d.ellipse([x - r * 1.6, y - r, x + r * 1.6, y + r], fill=random.randint(40, 140))
smoke = smoke.filter(ImageFilter.GaussianBlur(35))
Image.merge("RGB", (smoke, smoke, smoke)).save("smoke.jpg", quality=90)

# The portrait with green blotches on the skin, to fix with a Color layer.
if os.path.exists("red-hair.jpg"):
    hair = Image.open("red-hair.jpg").convert("RGB")
    blotch = Image.new("L", hair.size, 0)
    bd = ImageDraw.Draw(blotch)
    w, h = hair.size
    bd.ellipse([int(w * 0.5), int(h * 0.55), int(w * 0.75), int(h * 0.75)], fill=140)
    blotch = blotch.filter(ImageFilter.GaussianBlur(40))
    Image.composite(Image.new("RGB", hair.size, (90, 170, 60)), hair, blotch).save("cast.jpg", quality=90)

# The seaside photo with a wire across the sky, to take out with the Remove tool.
sea = Image.open("seaside.jpg").convert("RGB")
ImageDraw.Draw(sea).line([(0, 150), (1600, 250)], fill=(30, 30, 35), width=5)
sea.save("wire.jpg", quality=92)

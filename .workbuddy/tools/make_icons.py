"""Generate app icons for ZY-Player-Flutter from the provided artwork.

Source: clipboard JPG (1282x1282) - black rounded square, cyan play logo + "ZY Player".
Only the white area OUTSIDE the rounded corner must be blackened -> use a flood fill
from the four corners (a plain luminance threshold would also eat the bright cyan
"ZY Player" text, which is near-white). Then export every platform density.

Adaptive icon: black background + foreground content scaled to 0.72 so the whole
logo+text stays inside the round safe-zone of most launchers.
"""
import os
from PIL import Image, ImageFilter, ImageDraw

SRC = "C:/Users/VTE/.workbuddy/clipboard-images/clipboard-2026-10-04T04-39-37-178Z-ed1a840f.jpg"
ROOT = "D:/WorkBuddy/ZY-Player-Flutter"
PREVIEW = ROOT + "/.workbuddy/tools/icon_preview"
os.makedirs(PREVIEW, exist_ok=True)

im = Image.open(SRC).convert("RGB")
W, H = im.size

# ---- 1) master: blacken only the outer white background via flood fill ----
lum = im.convert("L")
# candidate background = near-pure-white pixels
bg = lum.point(lambda p: 255 if p >= 245 else 0)
for sp in [(0, 0), (W - 1, 0), (0, H - 1), (W - 1, H - 1)]:
    ImageDraw.floodfill(bg, sp, 128, thresh=20)
mask = bg.point(lambda p: 255 if p == 128 else 0)
# grow the mask slightly to swallow anti-aliased edge pixels
mask = mask.filter(ImageFilter.MaxFilter(7))
master = Image.composite(Image.new("RGB", (W, H), (0, 0, 0)), im, mask)
master.save(PREVIEW + "/master.png")
print("master done (size %dx%d)" % master.size)


def full(size, ratio=1.0):
    """Full-bleed icon at given logical size (ratio<1 pads with black)."""
    if ratio >= 1.0:
        return master.resize((size, size), Image.LANCZOS)
    inner = int(size * ratio)
    canvas = Image.new("RGB", (size, size), (0, 0, 0))
    canvas.paste(master.resize((inner, inner), Image.LANCZOS),
                 ((size - inner) // 2, (size - inner) // 2))
    return canvas


def transparent_fg(size, ratio):
    """Transparent canvas with the (black-backed) artwork centered at ratio."""
    inner = int(size * ratio)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(master.resize((inner, inner), Image.LANCZOS).convert("RGBA"),
                 ((size - inner) // 2, (size - inner) // 2))
    return canvas


# ---- 2) Android legacy launcher icons (full artwork, incl. text) ----
android_base = ROOT + "/android/app/src/main/res"
for d, s in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
    dpath = f"{android_base}/mipmap-{d}"
    os.makedirs(dpath, exist_ok=True)
    full(s).save(f"{dpath}/ic_launcher.png")
print("android legacy done")

# ---- 3) Android adaptive icon ----
for d, s in {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}.items():
    dpath = f"{android_base}/mipmap-{d}"
    os.makedirs(dpath, exist_ok=True)
    transparent_fg(s, 0.72).save(f"{dpath}/ic_launcher_foreground.png")

anydpi = f"{android_base}/mipmap-anydpi-v26"
os.makedirs(anydpi, exist_ok=True)
with open(f"{anydpi}/ic_launcher.xml", "w", encoding="utf-8") as f:
    f.write('<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@color/ic_launcher_background" />\n'
            '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
            '</adaptive-icon>\n')

colors_path = f"{android_base}/values/colors.xml"
os.makedirs(f"{android_base}/values", exist_ok=True)
if not os.path.exists(colors_path):
    with open(colors_path, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
                '    <color name="ic_launcher_background">#000000</color>\n</resources>\n')
print("android adaptive done")

# ---- 4) Windows .ico ----
full(256).save(ROOT + "/windows/runner/resources/app_icon.ico", format="ICO",
               sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print("windows ico done")

# ---- 5) iOS icons (no alpha required; system rounds the corners) ----
ios_dir = ROOT + "/ios/Runner/Assets.xcassets/AppIcon.appiconset"
ios_map = {
    "Icon-App-20x20@1x.png": 20, "Icon-App-20x20@2x.png": 40, "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29, "Icon-App-29x29@2x.png": 58, "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40, "Icon-App-40x40@2x.png": 80, "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120, "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76, "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167, "Icon-App-1024x1024@1x.png": 1024,
}
if os.path.isdir(ios_dir):
    for name, s in ios_map.items():
        full(s).save(f"{ios_dir}/{name}")
    print("ios done")

# ---- 6) Web icons ----
web = ROOT + "/web"
if os.path.isdir(web):
    full(32).save(f"{web}/favicon.png")
    for name, s in {"Icon-192.png": 192, "Icon-512.png": 512}.items():
        p = f"{web}/icons/{name}"
        if os.path.exists(p):
            full(s).save(p)
    for name, s in {"Icon-maskable-192.png": 192, "Icon-maskable-512.png": 512}.items():
        p = f"{web}/icons/{name}"
        if os.path.exists(p):
            full(s, ratio=0.8).save(p)
    print("web done")

# ---- 7) self-check previews ----
S = 512
# adaptive icon as a round-mask launcher renders it (mask dia ~0.70)
circ = Image.new("RGB", (S, S), (205, 207, 212))
inner = int(S * 0.72)
layer = Image.new("RGB", (S, S), (0, 0, 0))
layer.paste(master.resize((inner, inner), Image.LANCZOS), ((S - inner) // 2, (S - inner) // 2))
m = Image.new("L", (S, S), 0)
ImageDraw.Draw(m).ellipse((S * 0.15, S * 0.15, S * 0.85, S * 0.85), fill=255)
circ.paste(layer, (0, 0), m)
circ.save(PREVIEW + "/adaptive_circle.png")

# legacy icon, rounded-square mask
rq = Image.new("RGB", (S, S), (205, 207, 212))
leg = master.resize((int(S * 0.78), int(S * 0.78)), Image.LANCZOS)
rr = Image.new("L", (int(S * 0.78), int(S * 0.78)), 0)
ImageDraw.Draw(rr).rounded_rectangle((0, 0, int(S * 0.78) - 1, int(S * 0.78) - 1), radius=int(S * 0.18), fill=255)
rq.paste(leg, (int(S * 0.11), int(S * 0.11)), rr)
rq.save(PREVIEW + "/legacy_rounded.png")
print("previews done ->", PREVIEW)

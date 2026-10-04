"""Generate app icons for ZY-Player-Flutter from the new artwork.

Source: .workbuddy/tools/icon_source.png (1195x1195, RGBA)
 - black rounded square with a cyan play logo (NO text), outer corners transparent.
 - the artwork's black is ~#090907 (near black).
Strategy: composite the RGBA source onto a pure-black canvas (transparent corners
become #000000), so legacy/dark surfaces get a full black square. The logo itself
is centered and only ~0.54 of the canvas width, so the adaptive foreground can use
the full bleed (ratio 1.0) and still stay inside the launcher round safe-zone.
"""
import os
from PIL import Image, ImageDraw

SRC = "D:/WorkBuddy/ZY-Player-Flutter/.workbuddy/tools/icon_source.png"
ROOT = "D:/WorkBuddy/ZY-Player-Flutter"
PREVIEW = ROOT + "/.workbuddy/tools/icon_preview"
os.makedirs(PREVIEW, exist_ok=True)

src = Image.open(SRC).convert("RGBA")
W, H = src.size
master = Image.alpha_composite(Image.new("RGBA", (W, H), (0, 0, 0, 255)), src).convert("RGB")
master.save(PREVIEW + "/master.png")
print("master done (size %dx%d)" % master.size)


def full(size):
    return master.resize((size, size), Image.LANCZOS)


def transparent_fg(size, ratio):
    """Transparent canvas with the (black-backed) artwork centered at ratio."""
    inner = int(size * ratio)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(master.resize((inner, inner), Image.LANCZOS).convert("RGBA"),
                 ((size - inner) // 2, (size - inner) // 2))
    return canvas


# ---- Android legacy launcher icons (full black square + logo) ----
android_base = ROOT + "/android/app/src/main/res"
for d, s in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
    dpath = f"{android_base}/mipmap-{d}"
    os.makedirs(dpath, exist_ok=True)
    full(s).save(f"{dpath}/ic_launcher.png")
print("android legacy done")

# ---- Android adaptive icon (logo is only 0.54 wide -> full-bleed is safe) ----
for d, s in {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}.items():
    dpath = f"{android_base}/mipmap-{d}"
    os.makedirs(dpath, exist_ok=True)
    transparent_fg(s, 1.0).save(f"{dpath}/ic_launcher_foreground.png")

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
with open(colors_path, "w", encoding="utf-8") as f:
    f.write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
            '    <color name="ic_launcher_background">#000000</color>\n</resources>\n')
print("android adaptive done")

# ---- Windows .ico ----
full(256).save(ROOT + "/windows/runner/resources/app_icon.ico", format="ICO",
               sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print("windows ico done")

# ---- iOS icons (no alpha; system rounds the corners) ----
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

# ---- Web icons ----
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
            transparent_fg(s, 0.8).save(p)
    print("web done")

# ---- self-check previews ----
S = 512
# adaptive icon as a round-mask launcher renders it (mask dia ~0.70)
circ = Image.new("RGB", (S, S), (205, 207, 212))
layer = Image.new("RGB", (S, S), (0, 0, 0))
layer.paste(master.resize((S, S), Image.LANCZOS), (0, 0))
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

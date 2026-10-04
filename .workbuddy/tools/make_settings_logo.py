"""Build the Settings-page logo: black rounded square + centered cyan play logo,
WITHOUT the 'ZY Player' text (the settings page already shows that as a caption).

Source bounding box of the logo (measured by analyze_logo.py):
    x[318..965] y[267..811]
The artwork's black is NOT pure black (#JPG), so pasting the crop as an opaque
rectangle shows a grey seam. We therefore KEY OUT the dark background (alpha from
per-pixel max channel) and composite only the cyan logo onto a pure-black rounded
square that matches the app-icon background (#000000).
"""
from PIL import Image, ImageDraw

ROOT = "D:/WorkBuddy/ZY-Player-Flutter"
PREVIEW = ROOT + "/.workbuddy/tools/icon_preview"
master = Image.open(PREVIEW + "/master.png").convert("RGB")
W, H = master.size

PAD = 16
cx0, cy0, cx1, cy1 = 318 - PAD, 267 - PAD, 965 + PAD, 811 + PAD
cx0 = max(0, cx0); cy0 = max(0, cy0); cx1 = min(W, cx1); cy1 = min(H, cy1)
logo = master.crop((cx0, cy0, cx1, cy1))
lw, lh = logo.size
print("logo crop: %dx%d (ratio %.3f)" % (lw, lh, lw / lh))

SIZE = 512
RADIUS = int(SIZE * 0.22)
LOGO_FRAC = 0.62

tw = int(SIZE * LOGO_FRAC)
th = int(round(tw * lh / lw))
logo_r = logo.resize((tw, th), Image.LANCZOS)

# ---- key out the dark background: alpha ramps from 0 (dark) to 255 (bright) ----
LO, HI = 45.0, 130.0
src = logo_r.load()
keyed = Image.new("RGBA", (tw, th))
dst = keyed.load()
for y in range(th):
    for x in range(tw):
        r, g, b = src[x, y]
        m = max(r, g, b)
        a = int(max(0.0, min(1.0, (m - LO) / (HI - LO))) * 255)
        dst[x, y] = (r, g, b, a)

canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
mask = Image.new("L", (SIZE, SIZE), 0)
ImageDraw.Draw(mask).rounded_rectangle(
    (0, 0, SIZE - 1, SIZE - 1), radius=RADIUS, fill=255)
canvas.paste(Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 255)), (0, 0), mask)
canvas.paste(keyed, ((SIZE - tw) // 2, (SIZE - th) // 2), keyed)

canvas.save(PREVIEW + "/settings_logo.png")
print("settings logo written -> %dx%d, logo drawn %dx%d" % (SIZE, SIZE, tw, th))

for name, bg in (("settings_logo_on_light.png", (242, 242, 247)),
                 ("settings_logo_on_dark.png", (10, 10, 10))):
    pv = Image.new("RGB", (SIZE + 120, SIZE + 120), bg)
    pv.paste(canvas, (60, 60), canvas)
    pv.save(PREVIEW + "/" + name)
print("previews done")

"""Probe the new icon source: size, corner/edge pixels, alpha distribution.

Goal: decide whether the rounded-corner outside is WHITE (needs flood-fill to
black) or transparent (can be composited directly).
"""
from PIL import Image

SRC = "D:/WorkBuddy/ZY-Player-Flutter/.workbuddy/tools/icon_source.png"
im = Image.open(SRC).convert("RGBA")
w, h = im.size
px = im.load()
print("size: %dx%d  mode: RGBA" % (w, h))

pts = {
    "corner(0,0)": (0, 0),
    "corner(w-1,0)": (w - 1, 0),
    "corner(0,h-1)": (0, h - 1),
    "corner(w-1,h-1)": (w - 1, h - 1),
    "in(5%,5%)": (int(w * 0.05), int(h * 0.05)),
    "in(12%,12%)": (int(w * 0.12), int(h * 0.12)),
    "center": (w // 2, h // 2),
    "mid_left(2%,50%)": (int(w * 0.02), h // 2),
    "mid_top(50%,2%)": (w // 2, int(h * 0.02)),
}
for k, (x, y) in pts.items():
    print("%-18s (%4d,%4d): %s" % (k, x, y, px[x, y]))

alpha = im.split()[3]
hist = alpha.histogram()
total = w * h
print("alpha=0   ratio: %.4f" % (hist[0] / total))
print("alpha=255 ratio: %.4f" % (hist[255] / total))

# brightest (logo) pixel value, to judge color
mx = (0, 0, 0)
for y in range(0, h, 7):
    for x in range(0, w, 7):
        r, g, b, a = px[x, y]
        if max(r, g, b) > max(mx):
            mx = (r, g, b)
print("brightest sampled RGB:", mx)

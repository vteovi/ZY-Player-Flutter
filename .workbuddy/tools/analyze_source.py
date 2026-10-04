"""Measure the cyan logo bounding box inside the new source icon (no text).

Used to pick a safe scale for the Android adaptive-icon foreground so the logo
stays inside the round safe-zone.
"""
from PIL import Image

SRC = "D:/WorkBuddy/ZY-Player-Flutter/.workbuddy/tools/icon_source.png"
im = Image.open(SRC).convert("RGBA")
w, h = im.size
px = im.load()
TH = 90

xmin, ymin, xmax, ymax = w, h, -1, -1
for y in range(h):
    for x in range(w):
        r, g, b, a = px[x, y]
        if a > 0 and max(r, g, b) > TH:
            if x < xmin:
                xmin = x
            if x > xmax:
                xmax = x
            if y < ymin:
                ymin = y
            if y > ymax:
                ymax = y

bw, bh = xmax - xmin + 1, ymax - ymin + 1
print("logo bbox: x[%d..%d] y[%d..%d]  w=%d h=%d" % (xmin, xmax, ymin, ymax, bw, bh))
print("bbox width  = %.3f of canvas" % (bw / w))
print("bbox height = %.3f of canvas" % (bh / h))
print("bbox center = (%.1f, %.1f)  canvas center = (%.1f, %.1f)"
      % ((xmin + xmax) / 2, (ymin + ymax) / 2, w / 2, h / 2))

"""Locate play-logo vs text, ignoring the anti-aliased rounded-corner rim.

The master's rounded-corner edge keeps a few grey anti-alias pixels that are
"bright" by threshold, so a full-width row projection gets bridged into one
block. Restrict the scan to an inner window to separate logo from text.
"""
from PIL import Image

SRC = "D:/WorkBuddy/ZY-Player-Flutter/.workbuddy/tools/icon_preview/master.png"
im = Image.open(SRC).convert("RGB")
W, H = im.size
px = im.load()

XM = 150          # inner margin (skip rim anti-alias)
YM = 20
X0, X1 = XM, W - XM
Y0, Y1 = YM, H - YM


def bright(r, g, b):
    return max(r, g, b) > 60


rows = []
for y in range(H):
    c = 0
    if Y0 <= y <= Y1:
        for x in range(X0, X1 + 1):
            if bright(*px[x, y]):
                c += 1
    rows.append(c)

blocks = []
inb = False
s = 0
for y, c in enumerate(rows):
    if c > 0 and not inb:
        inb = True
        s = y
    elif c == 0 and inb:
        inb = False
        blocks.append((s, y - 1))
if inb:
    blocks.append((s, H - 1))

print("image size: %dx%d  (scan x[%d..%d] y[%d..%d])" % (W, H, X0, X1, Y0, Y1))
print("row blocks:")
for (y0, y1) in blocks:
    xmin, xmax = W, -1
    for y in range(y0, y1 + 1):
        for x in range(X0, X1 + 1):
            if bright(*px[x, y]):
                if x < xmin:
                    xmin = x
                if x > xmax:
                    xmax = x
    print("  y[%4d..%4d] h=%4d  x[%4d..%4d] w=%4d" %
          (y0, y1, y1 - y0 + 1, xmin, xmax, xmax - xmin + 1))

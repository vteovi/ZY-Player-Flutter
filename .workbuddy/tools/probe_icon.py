from PIL import Image

src = "C:/Users/VTE/.workbuddy/clipboard-images/clipboard-2026-10-04T04-39-37-178Z-ed1a840f.jpg"
im = Image.open(src).convert("RGB")
w, h = im.size
print("size:", w, "x", h)
px = im.load()
pts = {"tl": (0, 0), "tr": (w - 1, 0), "bl": (0, h - 1), "br": (w - 1, h - 1),
       "center": (w // 2, h // 2),
       "in_tl": (int(w * 0.08), int(h * 0.08)),
       "left_mid": (int(w * 0.12), h // 2),
       "bottom_mid": (w // 2, int(h * 0.72))}
for name, (x, y) in pts.items():
    print(f"{name} ({x},{y}):", px[x, y])

gray = im.convert("L")
hist = gray.histogram()
total = w * h
white = sum(hist[241:256])
dark = sum(hist[0:16])
print("near-white(>240) ratio: %.4f" % (white / total))
print("near-black(<16)  ratio: %.4f" % (dark / total))
print("lum at corner_in(8%,8%):", gray.getpixel((int(w * 0.08), int(h * 0.08))))


from PIL import Image, ImageDraw
import os

SRC = "/Users/ola/Desktop/ls/系统码表sysmon/assets/logo.jpg"
OUT = "/Users/ola/Desktop/ls/系统码表sysmon/build/AppIcon.iconset"
os.makedirs(OUT, exist_ok=True)

S = 1024
src = Image.open(SRC).convert("L")
mask = src.point(lambda v: 255 - v)
mask = mask.crop(mask.getbbox())
w, h = mask.size

def build(bg, fg, path):
    tile = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(tile)
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=228, fill=bg)
    target = int(S * 0.60)
    scale = target / max(w, h)
    gw, gh = int(w * scale), int(h * scale)
    g = mask.resize((gw, gh), Image.LANCZOS)
    art = Image.new("RGBA", (gw, gh), fg)
    art.putalpha(g)
    tile.alpha_composite(art, ((S - gw) // 2, (S - gh) // 2))
    tile.save(path)

build((23, 23, 26, 255), (255, 255, 255, 255), "/Users/ola/Desktop/ls/系统码表sysmon/assets/icon-dark.png")

# 正式生成黑色底 iconset
tile = Image.open("/Users/ola/Desktop/ls/系统码表sysmon/assets/icon-dark.png")
sizes = [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),
         (128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),
         (512,"512x512"),(1024,"512x512@2x")]
for px, name in sizes:
    tile.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, f"icon_{name}.png"))
print("ok")

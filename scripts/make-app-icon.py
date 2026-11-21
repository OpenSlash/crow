#!/usr/bin/env python3
"""Builds Crow's app icon and glyphs from the brand artwork.

Inputs (apps/macos/Resources/Brand): crow-foreground.png, the full-colour crow
head on transparency, and crow-glyph.png, its solid silhouette.
Outputs: AppIcon.icns, AppIcon-1024.png, MenuBarGlyph.png (+@2x), IslandGlyph.png,
and icon-composer/ layers for Apple's Icon Composer.
"""
import os, shutil, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFilter, ImageChops

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, "apps/macos/Resources/Brand")
OUT = os.path.join(ROOT, "apps/macos/Resources")

CANVAS = 1024
BODY = 824                     # Apple's macOS icon grid: 824 pt shape on a 1024 canvas
TOP, BOTTOM = (0xE6, 0xE8, 0xEE), (0xB7, 0xBE, 0xC9)


def squircle(size, scale=4, n=5.0):
    """Superellipse mask, close to Apple's continuous-corner icon shape."""
    big = size * scale
    mask = Image.new("L", (big, big), 0)
    px = mask.load()
    r = big / 2
    for y in range(big):
        dy = abs((y + 0.5 - r) / r) ** n
        if dy >= 1:
            continue
        half = int(r * (1 - dy) ** (1 / n))
        for x in range(int(r - half), int(r + half)):
            px[x, y] = 255
    return mask.resize((size, size), Image.LANCZOS)


def gradient(size):
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        d.line([(0, y), (size, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    return img


def crow_layer(size):
    """The crow, scaled into the icon body with its neck running off the bottom."""
    fg = Image.open(os.path.join(BRAND, "crow-foreground.png")).convert("RGBA")
    box = fg.getbbox()
    crow = fg.crop(box)
    target_w = int(size * 0.92)
    h = int(crow.height * target_w / crow.width)
    crow = crow.resize((target_w, h), Image.LANCZOS)
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    x = -int(size * 0.03)   # the artwork is cut flat on the left: push that edge outside
    y = size - h + int(size * 0.06)   # neck crosses the bottom edge
    layer.alpha_composite(crow, (x, max(y, int(size * 0.14))))
    return layer


def app_icon():
    mask = squircle(BODY)
    body = gradient(BODY).convert("RGBA")
    # Soft top highlight, as in Apple's icons.
    hi = Image.new("L", (BODY, BODY), 0)
    ImageDraw.Draw(hi).ellipse([-BODY * 0.3, -BODY * 0.75, BODY * 1.3, BODY * 0.35], fill=60)
    hi = hi.filter(ImageFilter.GaussianBlur(BODY * 0.08))
    body = Image.composite(Image.new("RGBA", (BODY, BODY), (255, 255, 255, 255)), body, hi)
    crow = crow_layer(BODY)
    # A soft shadow under the crow gives it depth on the flat ground.
    shadow = Image.new("RGBA", (BODY, BODY), (20, 24, 40, 0))
    shadow.putalpha(crow.getchannel("A").point(lambda a: a * 0.35).filter(ImageFilter.GaussianBlur(14)))
    body.alpha_composite(shadow, (6, 12))
    body.alpha_composite(crow)
    body.putalpha(ImageChops.multiply(body.getchannel("A"), mask))

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    off = (CANVAS - BODY) // 2
    drop = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    dmask = Image.new("L", (CANVAS, CANVAS), 0)
    dmask.paste(mask.point(lambda a: a * 0.32), (off, off + 10))
    drop.putalpha(dmask.filter(ImageFilter.GaussianBlur(14)))
    canvas.alpha_composite(drop)
    canvas.alpha_composite(body, (off, off))
    return canvas


def glyph(size, pad=0.04):
    """White-on-transparent silhouette with its eye cut out, trimmed and centred."""
    g = Image.open(os.path.join(BRAND, "crow-glyph.png")).convert("RGBA")
    alpha = g.getchannel("A")
    alpha = alpha.crop(alpha.getbbox())
    side = max(alpha.size)
    sq = Image.new("L", (side, side), 0)
    sq.paste(alpha, ((side - alpha.width) // 2, side - alpha.height))
    inner = int(size * (1 - 2 * pad))
    sq = sq.resize((inner, inner), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    solid = Image.new("RGBA", (inner, inner), (0, 0, 0, 255))
    solid.putalpha(sq)
    out.alpha_composite(solid, ((size - inner) // 2, (size - inner) // 2))
    return out


def main():
    icon = app_icon()
    icon.save(os.path.join(OUT, "AppIcon-1024.png"))
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.mkdir(iconset)
        for pt in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = pt * scale
                name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
                icon.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(OUT, "AppIcon.icns")], check=True)
    # Menu bar: 18 pt template (black + alpha; macOS tints it).
    glyph(18).save(os.path.join(OUT, "MenuBarGlyph.png"))
    glyph(36).save(os.path.join(OUT, "MenuBarGlyph@2x.png"))
    glyph(128, pad=0).save(os.path.join(OUT, "IslandGlyph.png"))
    # Icon Composer layers: background colour is set in the app; the crow is the layer.
    layers = os.path.join(BRAND, "icon-composer")
    os.makedirs(layers, exist_ok=True)
    crow_layer(CANVAS).save(os.path.join(layers, "crow.png"))
    gradient(CANVAS).save(os.path.join(layers, "background.png"))
    print("wrote AppIcon.icns, AppIcon-1024.png, MenuBarGlyph(@2x).png, IslandGlyph.png, Brand/icon-composer/")


if __name__ == "__main__":
    main()

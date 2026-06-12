#!/usr/bin/env python3
from __future__ import annotations

import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Resources" / "AppIcon-source.png"
PREPARED = ROOT / "Resources" / "AppIcon-prepared.png"
ICONSET = ROOT / "build" / "AppIcon.iconset"
ICNS = ROOT / "Resources" / "AppIcon.icns"

CANVAS_SIZE = 1024
VISIBLE_SIZE = 824
CORNER_RADIUS = 184
SHADOW_BLUR = 24
SHADOW_OFFSET_Y = 16

ICONSET_SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def center_crop_square(image: Image.Image) -> Image.Image:
    width, height = image.size
    side = min(width, height)
    left = (width - side) // 2
    top = (height - side) // 2
    return image.crop((left, top, left + side, top + side))


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size, size), radius=radius, fill=255)
    return mask


def build_prepared_icon() -> Image.Image:
    image = Image.open(SOURCE).convert("RGBA")
    image = center_crop_square(image).resize((VISIBLE_SIZE, VISIBLE_SIZE), Image.Resampling.LANCZOS)
    mask = rounded_mask(VISIBLE_SIZE, CORNER_RADIUS)

    canvas = Image.new("RGBA", (CANVAS_SIZE, CANVAS_SIZE), (0, 0, 0, 0))
    origin = ((CANVAS_SIZE - VISIBLE_SIZE) // 2, (CANVAS_SIZE - VISIBLE_SIZE) // 2)

    shadow = Image.new("RGBA", (CANVAS_SIZE, CANVAS_SIZE), (0, 0, 0, 0))
    shadow_mask = Image.new("L", (CANVAS_SIZE, CANVAS_SIZE), 0)
    shadow_mask.paste(mask, (origin[0], origin[1] + SHADOW_OFFSET_Y))
    shadow_mask = shadow_mask.filter(ImageFilter.GaussianBlur(SHADOW_BLUR))
    shadow.putalpha(shadow_mask.point(lambda value: int(value * 0.24)))
    canvas.alpha_composite(shadow)

    canvas.paste(image, origin, mask)
    return canvas


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"Missing source icon: {SOURCE}")

    ROOT.joinpath("Resources").mkdir(parents=True, exist_ok=True)
    ICONSET.mkdir(parents=True, exist_ok=True)

    for path in ICONSET.glob("*.png"):
        path.unlink()

    prepared = build_prepared_icon()
    prepared.save(PREPARED)

    for filename, size in ICONSET_SIZES:
        resized = prepared.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(ICONSET / filename)

    if ICNS.exists():
        ICNS.unlink()
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)
    print(ICNS)


if __name__ == "__main__":
    main()

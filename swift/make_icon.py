#!/usr/bin/env python3
"""Generate AppIcon.icns for AranetBar.

Reproducible: `python3 make_icon.py` rewrites `AppIcon.icns` and `icon-1024.png`.
Requires Pillow, plus macOS's `iconutil`.
"""

from __future__ import annotations

import subprocess
import sys
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
MASTER = 4096  # supersample, then downscale for smooth edges
SIZES = [16, 32, 64, 128, 256, 512, 1024]


def rounded_mask(size: int, inset: float, radius: float) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([inset, inset, size - inset, size - inset], radius=radius, fill=255)
    return mask


def gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    """Diagonal gradient, top-left -> bottom-right."""
    y, x = np.mgrid[0:size, 0:size]
    t = ((x + y) / (2 * (size - 1)))[..., None]
    a = np.array(top, dtype=float)
    b = np.array(bottom, dtype=float)
    return Image.fromarray((a + (b - a) * t).astype(np.uint8), "RGB")


def draw_icon(size: int) -> Image.Image:
    # macOS icon grid: content box is ~824/1024 of the canvas with a large radius.
    inset = size * 0.0977
    content = size - 2 * inset
    radius = content * 0.2245

    mask = rounded_mask(size, inset, radius)
    art = gradient(size, (10, 34, 38), (13, 90, 82)).convert("RGBA")

    draw = ImageDraw.Draw(art)
    cx = size / 2
    cy = size / 2 + content * 0.03  # optical centring: the bottom gap adds weight

    # 270-degree gauge, banded with Aranet's own green/yellow/red CO2 levels.
    r = content * 0.305
    width = int(content * 0.088)
    box = [cx - r, cy - r, cx + r, cy + r]

    for start, end, colour in (
        (135, 285, (52, 199, 89, 255)),    # green  - good air
        (285, 345, (255, 204, 0, 255)),    # yellow - getting stuffy
        (345, 405, (255, 69, 58, 255)),    # red    - ventilate
    ):
        draw.arc(box, start, end, fill=colour, width=width)

    # Needle pointing straight up, inside the green band.
    angle = math.radians(270)
    tip_r = r * 0.78
    tip = (cx + tip_r * math.cos(angle), cy + tip_r * math.sin(angle))
    needle_w = int(content * 0.040)
    draw.line([cx, cy, tip[0], tip[1]], fill=(255, 255, 255, 255), width=needle_w)
    cap = needle_w / 2
    draw.ellipse([tip[0] - cap, tip[1] - cap, tip[0] + cap, tip[1] + cap], fill=(255, 255, 255, 255))

    # Pivot.
    pivot = content * 0.055
    draw.ellipse(
        [cx - pivot, cy - pivot, cx + pivot, cy + pivot],
        fill=(255, 255, 255, 255),
    )

    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(art, (0, 0), mask)
    return icon


def main() -> None:
    master = draw_icon(MASTER).resize((1024, 1024), Image.LANCZOS)
    master.save(HERE / "icon-1024.png")

    iconset = HERE / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for size in SIZES:
        master.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
        if size <= 512:  # @2x variants, capped at the 1024 master
            master.resize((size * 2, size * 2), Image.LANCZOS).save(
                iconset / f"icon_{size}x{size}@2x.png"
            )

    out = HERE / "AppIcon.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out)], check=True)
    print(f"wrote {out} ({out.stat().st_size:,} bytes)")


if __name__ == "__main__":
    sys.exit(main())

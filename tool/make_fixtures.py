#!/usr/bin/env python3
"""Regenerate deterministic EXIF-orientation fixtures for the Flutter tests.

Each fixture is a 64x64 image whose LEFT half is RED and RIGHT half is BLUE,
with physically un-mirrored pixels. Only the EXIF Orientation tag differs, so a
decoder that honours EXIF is what moves the pixels — which is exactly the
front-camera mirror mechanism under test.

    python3 tool/make_fixtures.py
"""
from pathlib import Path

from PIL import Image

OUT = Path(__file__).resolve().parent.parent / "test" / "fixtures"


def left_red_right_blue() -> Image.Image:
    im = Image.new("RGB", (64, 64))
    for x in range(64):
        for y in range(64):
            im.putpixel((x, y), (255, 0, 0) if x < 32 else (0, 0, 255))
    return im


def write(name: str, orientation: int) -> None:
    im = left_red_right_blue()
    exif = im.getexif()
    exif[274] = orientation  # 274 = Orientation
    OUT.mkdir(parents=True, exist_ok=True)
    im.save(OUT / name, "JPEG", exif=exif, quality=95)
    print(f"wrote {name} (Orientation={orientation})")


if __name__ == "__main__":
    write("exif_normal.jpg", 1)   # no transform
    write("exif_mirror2.jpg", 2)  # mirror-horizontal (front-camera style)

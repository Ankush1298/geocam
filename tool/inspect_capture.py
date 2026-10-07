#!/usr/bin/env python3
"""Inspect a real GeoCam/front-camera capture to settle the orientation convention.

Run on the ORIGINAL JPEG straight off the phone (before any editing):

    python3 tool/inspect_capture.py /path/to/front_capture.jpg

It reports the EXIF Orientation tag, pixel dimensions, and whether the EXIF
describes a MIRROR — the single fact needed to decide, with certainty, whether
the capture boundary must undo a front-camera mirror or leave the pixels as-is.
"""
import sys

from PIL import Image

ORIENTATION_MEANING = {
    1: "normal (no transform)",
    2: "MIRROR horizontal",
    3: "rotate 180",
    4: "MIRROR vertical",
    5: "MIRROR + rotate 270 CW",
    6: "rotate 90 CW",
    7: "MIRROR + rotate 90 CW",
    8: "rotate 270 CW",
}
MIRRORED = {2, 4, 5, 7}


def main(path: str) -> int:
    im = Image.open(path)
    o = im.getexif().get(274)  # 274 = Orientation
    print(f"file:            {path}")
    print(f"pixel size:      {im.size[0]} x {im.size[1]} (WxH, as stored)")
    print(f"EXIF Orientation:{o!r}  ->  {ORIENTATION_MEANING.get(o, 'absent/unknown')}")
    if o in MIRRORED:
        print("verdict:         EXIF encodes a MIRROR. Decoders apply it; for a")
        print("                 true-scene authenticity image the capture boundary")
        print("                 must undo exactly this mirror once.")
    elif o in (None, 1):
        print("verdict:         No mirror in EXIF. If the saved photo still looks")
        print("                 mirrored, the sensor stored physically-mirrored")
        print("                 pixels (case A) — undo once, gated on front camera.")
    else:
        print("verdict:         Rotation only; no mirror component.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))

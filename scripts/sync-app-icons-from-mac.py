#!/usr/bin/env python3
"""Regenerate shared packaging icons from macOS AppIcon.icns (authoritative rounded-flat mark).

Outputs:
  - win/Resources/AppIcon.{png,ico}   (WPF ApplicationIcon + QC logo + Inno SetupIcon)
  - win/build/icon.{png,ico}
  - build/icon.{png,ico,icns}
  - docs/assets/icon.png, app-icon.png, app-icon-128.png
  - mac/build/icon.icns  (copy of Resources)

Run from repo root:
  python3 scripts/sync-app-icons-from-mac.py
"""
from __future__ import annotations

import io
import shutil
import struct
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError as e:
    sys.stderr.write("Pillow required: pip install Pillow\n")
    raise SystemExit(1) from e

ROOT = Path(__file__).resolve().parents[1]
ICNS = ROOT / "mac" / "Resources" / "AppIcon.icns"
ICO_SIZES = (16, 24, 32, 48, 64, 128, 256)


def load_base() -> Image.Image:
    if not ICNS.is_file():
        raise SystemExit(f"missing source icns: {ICNS}")
    im = Image.open(ICNS)
    # Prefer largest frame if multi-image
    best = im.convert("RGBA")
    n = getattr(im, "n_frames", 1)
    for i in range(n):
        im.seek(i)
        frame = im.convert("RGBA")
        if frame.size[0] * frame.size[1] > best.size[0] * best.size[1]:
            best = frame
    w, h = best.size
    if w != h:
        side = max(w, h)
        canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        canvas.paste(best, ((side - w) // 2, (side - h) // 2), best)
        best = canvas
    return best


def resize(base: Image.Image, size: int) -> Image.Image:
    return base.resize((size, size), Image.Resampling.LANCZOS)


def write_png_ico(path: Path, images: list[Image.Image]) -> None:
    entries: list[tuple[int, int, bytes]] = []
    blobs: list[bytes] = []
    for im in images:
        buf = io.BytesIO()
        im.save(buf, format="PNG")
        raw = buf.getvalue()
        w, h = im.size
        entries.append((0 if w >= 256 else w, 0 if h >= 256 else h, raw))
        blobs.append(raw)
    count = len(entries)
    header = struct.pack("<HHH", 0, 1, count)
    offset = 6 + 16 * count
    directory = b""
    for w, h, raw in entries:
        directory += struct.pack("<BBBBHHII", w, h, 0, 0, 1, 32, len(raw), offset)
        offset += len(raw)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(header + directory + b"".join(blobs))


def main() -> None:
    base = load_base()
    master512 = resize(base, 512)
    master128 = resize(base, 128)
    frames = [resize(base, s) for s in ICO_SIZES]

    png_targets = [
        ROOT / "win" / "Resources" / "AppIcon.png",
        ROOT / "win" / "build" / "icon.png",
        ROOT / "build" / "icon.png",
        ROOT / "docs" / "assets" / "icon.png",
        ROOT / "docs" / "assets" / "app-icon.png",
    ]
    for p in png_targets:
        p.parent.mkdir(parents=True, exist_ok=True)
        master512.save(p, "PNG")
        print(f"PNG 512 → {p.relative_to(ROOT)}")
    (ROOT / "docs" / "assets" / "app-icon-128.png").parent.mkdir(parents=True, exist_ok=True)
    master128.save(ROOT / "docs" / "assets" / "app-icon-128.png", "PNG")
    print("PNG 128 → docs/assets/app-icon-128.png")

    ico_tmp = ROOT / "build" / "icon.ico"
    write_png_ico(ico_tmp, frames)
    for p in (
        ROOT / "win" / "Resources" / "AppIcon.ico",
        ROOT / "win" / "build" / "icon.ico",
    ):
        p.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ico_tmp, p)
        print(f"ICO    → {p.relative_to(ROOT)} ({p.stat().st_size} B)")
    print(f"ICO    → build/icon.ico ({ico_tmp.stat().st_size} B)")

    for dest in (ROOT / "build" / "icon.icns", ROOT / "mac" / "build" / "icon.icns"):
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ICNS, dest)
        print(f"ICNS   → {dest.relative_to(ROOT)}")

    # Sanity: solid-pixel count should be high (anti-aliased modern mark), not ~12-color flat
    colors = master512.getcolors(maxcolors=500_000)
    ncolors = len(colors) if colors else -1
    if ncolors < 100:
        print(f"WARN: master PNG only ~{ncolors} colors — source may be the old flat mark", file=sys.stderr)
    else:
        print(f"OK: master PNG ~{ncolors} colors (rounded flat)")


if __name__ == "__main__":
    main()

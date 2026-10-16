#!/usr/bin/env python3
"""Rebuild PicoSurf's reading fonts, fonts/*.pfn and fonts/LICENSE, from the
X.Org bitmap font releases (proportional fonts spec, section 2).

usage: tools/build-fonts.py ADOBE_75DPI UTOPIA_75DPI

  ADOBE_75DPI   font-adobe-75dpi-1.0.4.tar.xz
  UTOPIA_75DPI  font-adobe-utopia-75dpi-1.0.5.tar.xz
                (both from https://www.x.org/releases/individual/font/)

PicoDeck's tools/mkfont.py does the conversion (PICODECK_ROOT, default
~/Projects/PicoDeck/picodeck). The archives are only read: their BDFs are
parsed as text, and nothing in them is run. Before mkfont.py, each BDF is
cut to ASCII with a tight bounding box, glyphs whose ink overhangs their
advance get a wider advance, and over-padded bitmap rows are trimmed;
mkfont.py gets all three wrong (PicoDeck issue #74).
"""
import hashlib
import os
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "fonts"
FIRST, LAST = 0x20, 0x7E

# Archive: (top-level directory, SHA-256).
ARCHIVES = {
    "adobe": ("font-adobe-75dpi-1.0.4", "1281a62dbeded169e495cae1a5b487e1f336f2b4d971d92911c59c103999b911"),
    "utopia": ("font-adobe-utopia-75dpi-1.0.5", "a726245932d0724fa0c538c992811d63d597e5f53928f4048e9caf5623797760"),
}
# Output font: (archive, BDF file in it).
FONTS = {
    "sans": ("adobe", "helvR12.bdf"),
    "sans-bold": ("adobe", "helvB12.bdf"),
    "serif": ("utopia", "UTRG__10.bdf"),
    "serif-bold": ("utopia", "UTB___10.bdf"),
}
LICENSE_PARTS = [
    ("adobe", "sans.pfn and sans-bold.pfn: Helvetica 12 and Helvetica Bold 12\n"
              "(helvR12, helvB12) from X.Org font-adobe-75dpi 1.0.4."),
    ("utopia", "serif.pfn and serif-bold.pfn: Utopia Regular 10 and Utopia Bold 10\n"
               "(UTRG__10, UTB___10) from X.Org font-adobe-utopia-75dpi 1.0.5."),
]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def member_text(tar, top, name):
    f = tar.extractfile(f"{top}/{name}")
    if f is None:
        raise SystemExit(f"{top}/{name}: not a file in the archive")
    return f.read().decode("latin-1")


def fix_glyph(block, adjusted):
    """Move a negative left bearing to 0 and widen DWIDTH so all ink lies in
    [0, advance): the firmware draws only `advance` columns of a glyph. Trim
    bitmap rows to ceil(width / 8) bytes; the trimmed padding must be zero."""
    block = list(block)
    ib = next(i for i, l in enumerate(block) if l.startswith("BBX"))
    idw = next(i for i, l in enumerate(block) if l.startswith("DWIDTH"))
    w, h, xo, yo = map(int, block[ib].split()[1:5])
    dw = int(block[idw].split()[1])
    if xo < 0 or xo + w > dw:
        new_xo = max(xo, 0)
        block[ib] = f"BBX {w} {h} {new_xo} {yo}"
        block[idw] = f"DWIDTH {max(dw + (new_xo - xo), new_xo + w)} 0"
        adjusted.append(block[0].split()[1])
    digits = (w + 7) // 8 * 2
    start = block.index("BITMAP")
    for i in range(start + 1, len(block) - 1):
        row = block[i].strip()
        if len(row) > digits:
            if int(row[digits:], 16) != 0:
                raise SystemExit(f"{block[0]}: bitmap padding is not zero")
            row = row[:digits]
        block[i] = row.ljust(digits, "0")
    return block


def ascii_bdf(text):
    """The ASCII glyphs only, fixed as above, under a FONTBOUNDINGBOX tight
    around their ink, so mkfont.py takes the text's real height."""
    lines = [l.rstrip() for l in text.splitlines()]
    glyphs, adjusted = {}, []
    i = 0
    while i < len(lines):
        if lines[i].startswith("STARTCHAR"):
            j = i
            while not lines[j].startswith("ENDCHAR"):
                j += 1
            block = lines[i:j + 1]
            enc = next(int(l.split()[1]) for l in block if l.startswith("ENCODING"))
            if FIRST <= enc <= LAST:
                glyphs[enc] = fix_glyph(block, adjusted)
            i = j
        i += 1
    missing = "".join(chr(c) for c in range(FIRST, LAST + 1) if c not in glyphs)
    if missing:
        raise SystemExit(f"missing glyphs: {missing}")
    top = bottom = right = None
    for block in glyphs.values():
        w, h, xo, yo = map(int, next(l for l in block if l.startswith("BBX")).split()[1:5])
        start = block.index("BITMAP")
        if not any(int(r, 16) for r in block[start + 1:-1] if r):
            continue  # no ink (the space)
        dw = int(next(l for l in block if l.startswith("DWIDTH")).split()[1])
        top = yo + h if top is None else max(top, yo + h)
        bottom = yo if bottom is None else min(bottom, yo)
        right = max(xo + w, dw) if right is None else max(right, xo + w, dw)
    out = ["STARTFONT 2.1", "FONT picosurf-ascii", "SIZE 1 75 75",
           f"FONTBOUNDINGBOX {right} {top - bottom} 0 {bottom}", f"CHARS {len(glyphs)}"]
    for enc in sorted(glyphs):
        out += glyphs[enc]
    out.append("ENDFONT")
    return "\n".join(out) + "\n", adjusted


def main(argv):
    if len(argv) != 3:
        raise SystemExit(__doc__)
    paths = {"adobe": Path(argv[1]), "utopia": Path(argv[2])}
    for key, (top, digest) in ARCHIVES.items():
        if sha256(paths[key]) != digest:
            raise SystemExit(f"{paths[key]}: SHA-256 does not match {top}")
    root = Path(os.environ.get("PICODECK_ROOT", Path.home() / "Projects/PicoDeck/picodeck"))
    mkfont = root / "tools" / "mkfont.py"
    if not mkfont.is_file():
        raise SystemExit(f"{mkfont}: not found (set PICODECK_ROOT)")
    OUT.mkdir(exist_ok=True)
    licences = {}
    with tempfile.TemporaryDirectory() as tmp:
        for key, path in paths.items():
            top = ARCHIVES[key][0]
            with tarfile.open(path, "r:xz") as tar:
                licences[key] = member_text(tar, top, "COPYING")
                for name, (archive, bdf) in FONTS.items():
                    if archive != key:
                        continue
                    text, adjusted = ascii_bdf(member_text(tar, top, bdf))
                    src = Path(tmp) / f"{name}.bdf"
                    src.write_text(text)
                    out = OUT / f"{name}.pfn"
                    subprocess.run([sys.executable, "-I", str(mkfont), str(src), str(out),
                                    "--range", "0x20-0x7E"], check=True)
                    print(f"{out.relative_to(REPO)}: from {bdf}; advance widened for: "
                          f"{' '.join(adjusted) or 'none'}")
    parts = ["PicoSurf's Sans and Serif reading fonts are converted from X.Org's bitmap\n"
             "font releases (tools/build-fonts.py). Their licences follow, unchanged.\n"]
    for key, intro in LICENSE_PARTS:
        parts.append("=" * 72 + "\n" + intro + "\n\n" + licences[key].rstrip() + "\n")
    (OUT / "LICENSE").write_text("\n".join(parts))
    print("fonts/LICENSE written")


if __name__ == "__main__":
    main(sys.argv)

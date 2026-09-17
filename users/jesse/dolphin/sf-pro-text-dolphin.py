"""Copy SF Pro Text under a new family name, with its real average glyph width.

Requires fontTools.
"""

import argparse
from pathlib import Path

from fontTools.ttLib import TTFont

PRINTABLE_ASCII = range(32, 127)
POSTSCRIPT_NAME_ID = 6


def write_font(source: Path, destination_dir: Path, family: str) -> None:
    font = TTFont(source)
    cmap = font.getBestCmap()
    metrics = font["hmtx"]

    advances = [metrics[cmap[code]][0] for code in PRINTABLE_ASCII if code in cmap]
    font["OS/2"].xAvgCharWidth = round(sum(advances) / len(advances))

    for record in font["name"].names:
        text = record.toUnicode()
        # PostScript names can't contain spaces.
        if record.nameID == POSTSCRIPT_NAME_ID:
            record.string = text.replace("SFProText", family.replace(" ", ""))
        elif "SF Pro Text" in text:
            record.string = text.replace("SF Pro Text", family)

    font.save(destination_dir / source.name.replace("SF-Pro-Text", family.replace(" ", "-")))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source_dir", type=Path, help="directory holding SF-Pro-Text-*.otf")
    parser.add_argument("destination_dir", type=Path, help="existing directory the copies are written to")
    parser.add_argument("family", help="family name that replaces SF Pro Text")
    args = parser.parse_args()

    for source in args.source_dir.glob("SF-Pro-Text-*.otf"):
        write_font(source, args.destination_dir, args.family)


if __name__ == "__main__":
    main()

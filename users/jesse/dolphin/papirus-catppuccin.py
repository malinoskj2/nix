"""Mirror a Papirus icon theme with its mimetype icons recolored to the Catppuccin palette.

Single-hue icons get their accent moved to the nearest Catppuccin accent (keeping each shade's
relative lightness) and their grays mapped onto the Mocha neutrals. Glyphs drawn on the light paper
sheet use Latte accents, which are made for light backgrounds; on a colored sheet, where Mocha's
pastels are too light for white glyphs, the glyphs turn dark. Icons with several hues are logos,
so only their paper sheet is recolored.
"""

import argparse
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path

ACCENTS = ["red", "peach", "yellow", "green", "teal", "sky", "sapphire", "blue", "mauve", "pink"]
# Papirus gray lightness -> Mocha neutral, anchored so the paper sheet lands on "text".
NEUTRAL_STOPS = [
    (0.00, "crust"),
    (0.25, "base"),
    (0.35, "surface0"),
    (0.45, "surface1"),
    (0.55, "surface2"),
    (0.65, "overlay0"),
    (0.73, "overlay1"),
    (0.80, "overlay2"),
    (0.86, "subtext0"),
    (0.91, "text"),
]
# Papirus's light paper sheet and its highlight.
PAPIRUS_PAPER = "e4e4e4"
PAPIRUS_PAPER_HIGHLIGHT = "fafafa"
# The top stop and the paper highlight are a little lighter than any Mocha color.
TOP_NEUTRAL = "e6eaf9"
PAPER_HIGHLIGHT = "e1e6f8"
# Lightness of a typical Papirus accent.
REFERENCE_LIGHTNESS = 0.62
# Shades keep this share of their lightness offset from the reference, within these bounds.
SHADE_CONTRAST = 0.6
SHADE_LIGHTNESS_RANGE = (0.25, 0.95)
# Shades at this chroma or more keep the accent's full chroma; paler ones scale down to the floor.
FULL_CHROMA = 0.15
CHROMA_SCALE_FLOOR = 0.4
# Colors with less OKLCH chroma than this count as gray.
GRAY_CHROMA = 0.04
# An icon whose colored hues all lie within this many degrees of each other is single-hue.
SINGLE_HUE_SPREAD = 40
# White glyph pixels are lighter than this.
WHITE_LIGHTNESS = 0.95
# Out-of-gamut colors lose this share of chroma per step, for at most this many steps.
GAMUT_CHROMA_STEP = 0.92
GAMUT_MAX_STEPS = 40

HEX_COLOR = re.compile(r"#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b")
TAG = re.compile(r"<[^>]+>")
TRANSLUCENT = re.compile(r"(?<![\w-])(?:fill-)?opacity\s*[:=]\s*\"?\s*(0?\.\d+|0)\b")


# Colors pass between functions as bare lowercase rrggbb strings or as OKLCH lightness, chroma and
# hue in degrees.
type Lch = tuple[float, float, float]


@dataclass(frozen=True)
class Scheme:
    mocha_accents: list[Lch]
    latte_accents: list[Lch]
    glyph: str
    neutrals: list[tuple[float, str]]
    paper: dict[str, str]


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def srgb_to_linear(channel: float) -> float:
    return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4


def linear_to_srgb(channel: float) -> float:
    return 12.92 * channel if channel <= 0.0031308 else 1.055 * channel ** (1 / 2.4) - 0.055


def hex_channels(color: str) -> list[int]:
    return [int(color[i : i + 2], 16) for i in (0, 2, 4)]


def to_oklch(color: str) -> Lch:
    red, green, blue = (srgb_to_linear(channel / 255) for channel in hex_channels(color))
    cone_l = (0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue) ** (1 / 3)
    cone_m = (0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue) ** (1 / 3)
    cone_s = (0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue) ** (1 / 3)
    lightness = 0.2104542553 * cone_l + 0.7936177850 * cone_m - 0.0040720468 * cone_s
    axis_a = 1.9779984951 * cone_l - 2.4285922050 * cone_m + 0.4505937099 * cone_s
    axis_b = 0.0259040371 * cone_l + 0.7827717662 * cone_m - 0.8086757660 * cone_s
    return lightness, math.hypot(axis_a, axis_b), math.degrees(math.atan2(axis_b, axis_a)) % 360


# Chroma shrinks until the color fits in sRGB.
def to_hex(lightness: float, chroma: float, hue: float) -> str:
    for _ in range(GAMUT_MAX_STEPS):
        axis_a = chroma * math.cos(math.radians(hue))
        axis_b = chroma * math.sin(math.radians(hue))
        cone_l = (lightness + 0.3963377774 * axis_a + 0.2158037573 * axis_b) ** 3
        cone_m = (lightness - 0.1055613458 * axis_a - 0.0638541728 * axis_b) ** 3
        cone_s = (lightness - 0.0894841775 * axis_a - 1.2914855480 * axis_b) ** 3
        rgb = [
            4.0767416621 * cone_l - 3.3077115913 * cone_m + 0.2309699292 * cone_s,
            -1.2684380046 * cone_l + 2.6097574011 * cone_m - 0.3413193965 * cone_s,
            -0.0041960863 * cone_l - 0.7034186147 * cone_m + 1.7076147010 * cone_s,
        ]
        if all(-1e-4 <= channel <= 1.0001 for channel in rgb):
            break
        chroma *= GAMUT_CHROMA_STEP
    srgb = (clamp(linear_to_srgb(max(0, channel)), 0, 1) for channel in rgb)
    return "".join(f"{round(channel * 255):02x}" for channel in srgb)


def hue_distance(first: float, second: float) -> float:
    distance = abs(first - second) % 360
    return min(distance, 360 - distance)


def expand_hex(color: str) -> str:
    color = color.lower()
    return "".join(digit * 2 for digit in color) if len(color) == 3 else color


def map_accent(color: str, accents: list[Lch]) -> str:
    lightness, chroma, hue = to_oklch(color)
    accent_lightness, accent_chroma, accent_hue = min(accents, key=lambda lch: hue_distance(lch[2], hue))
    shade_offset = (lightness - REFERENCE_LIGHTNESS) * SHADE_CONTRAST
    shade_lightness = clamp(accent_lightness + shade_offset, *SHADE_LIGHTNESS_RANGE)
    chroma_scale = clamp(chroma / FULL_CHROMA, CHROMA_SCALE_FLOOR, 1.0)
    return to_hex(shade_lightness, accent_chroma * chroma_scale, accent_hue)


def map_gray(color: str, neutrals: list[tuple[float, str]]) -> str:
    lightness = to_oklch(color)[0]
    for (low_stop, low_color), (high_stop, high_color) in zip(neutrals, neutrals[1:]):
        if lightness <= high_stop:
            weight = (lightness - low_stop) / (high_stop - low_stop)
            channels = zip(hex_channels(low_color), hex_channels(high_color))
            return "".join(f"{round(low * (1 - weight) + high * weight):02x}" for low, high in channels)
    return neutrals[-1][1]


def recolor_tag(
    tag: str,
    scheme: Scheme,
    accents: list[Lch],
    *,
    single_hue: bool,
    dark_glyphs: bool,
) -> str:
    def recolor_hex(match: re.Match[str]) -> str:
        color = expand_hex(match.group(1))
        if color in scheme.paper:
            return "#" + scheme.paper[color]
        if not single_hue:
            return match.group(0)
        lightness, chroma, _ = to_oklch(color)
        if chroma > GRAY_CHROMA:
            return "#" + map_accent(color, accents)
        if dark_glyphs and lightness > WHITE_LIGHTNESS:
            return "#" + scheme.glyph
        return "#" + map_gray(color, scheme.neutrals)

    return HEX_COLOR.sub(recolor_hex, tag)


def recolor(svg: str, scheme: Scheme) -> str:
    colors = {expand_hex(color) for color in HEX_COLOR.findall(svg)}
    hues = [hue for _, chroma, hue in map(to_oklch, colors) if chroma > GRAY_CHROMA]
    single_hue = all(hue_distance(first, second) <= SINGLE_HUE_SPREAD for first in hues for second in hues)
    on_paper = bool(colors & scheme.paper.keys())
    accents = scheme.latte_accents if on_paper else scheme.mocha_accents

    def recolor_match(match: re.Match[str]) -> str:
        tag = match.group(0)
        # Translucent whites are highlights, not glyphs.
        dark_glyphs = bool(hues) and not on_paper and not TRANSLUCENT.search(tag)
        return recolor_tag(tag, scheme, accents, single_hue=single_hue, dark_glyphs=dark_glyphs)

    return TAG.sub(recolor_match, svg)


def load_scheme(palette_file: Path) -> Scheme:
    palette = json.loads(palette_file.read_text())
    mocha, latte = palette["mocha"], palette["latte"]
    return Scheme(
        mocha_accents=[to_oklch(mocha[accent]) for accent in ACCENTS],
        latte_accents=[to_oklch(latte[accent]) for accent in ACCENTS],
        glyph=mocha["base"],
        neutrals=[(stop, mocha[neutral]) for stop, neutral in NEUTRAL_STOPS] + [(1.00, TOP_NEUTRAL)],
        paper={PAPIRUS_PAPER: mocha["text"], PAPIRUS_PAPER_HIGHLIGHT: PAPER_HIGHLIGHT},
    )


# The copy mirrors the source theme instead of inheriting it: KIconLoader tries a MIME-style name's
# generic fallback (application-menu -> application-x-generic) in each theme before moving on to
# the inherited one. Only the mimetype directories are rewritten; everything else is symlinked.
def mirror_theme(source: Path, destination: Path, scheme: Scheme) -> None:
    for size_dir in source.iterdir():
        if not size_dir.is_dir():
            continue
        size_copy = destination / size_dir.name
        if "@" in size_dir.name:
            size_copy.symlink_to(size_dir.readlink())
            continue
        size_copy.mkdir()

        for context_dir in size_dir.iterdir():
            context_copy = size_copy / context_dir.name
            if context_dir.name != "mimetypes":
                context_copy.symlink_to(context_dir.resolve())
                continue
            context_copy.mkdir()

            for icon in context_dir.iterdir():
                icon_copy = context_copy / icon.name
                if icon.is_symlink() and "/" not in str(icon.readlink()):
                    icon_copy.symlink_to(icon.readlink())
                else:
                    icon_copy.write_text(recolor(icon.read_text(), scheme))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source", type=Path, help="Papirus theme directory")
    parser.add_argument("destination", type=Path, help="existing, empty output theme directory")
    parser.add_argument("name", help="name written to the copy's index.theme")
    parser.add_argument(
        "palette",
        type=Path,
        help='JSON file with the "mocha" and "latte" flavors as bare rrggbb strings',
    )
    args = parser.parse_args()

    mirror_theme(args.source, args.destination, load_scheme(args.palette))

    index = (args.source / "index.theme").read_text()
    index = re.sub(r"(?m)^Name=.*$", f"Name={args.name}", index, count=1)
    (args.destination / "index.theme").write_text(index)


if __name__ == "__main__":
    main()

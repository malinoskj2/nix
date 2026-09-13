# Recolors Papirus mimetype SVGs with the Catppuccin palette.
# Single-hue icons get their accent moved to the nearest Catppuccin accent (keeping each shade's
# relative lightness) and their grays mapped onto the Mocha neutrals. Glyphs drawn on the light paper
# sheet use Latte accents, which are made for light backgrounds; on a colored sheet, where Mocha's
# pastels are too light for white glyphs, the glyphs turn dark. Icons with several hues are logos,
# so only their paper sheet is recolored.
import math, pathlib, re, sys

MOCHA = ["f38ba8", "fab387", "f9e2af", "a6e3a1", "94e2d5", "89dceb", "74c7ec", "89b4fa", "cba6f7", "f5c2e7"]
LATTE = ["d20f39", "fe640b", "df8e1d", "40a02b", "179299", "04a5e5", "209fb5", "1e66f5", "8839ef", "ea76cb"]
GLYPH = "1e1e2e"
# Papirus gray lightness -> Catppuccin neutral, anchored so the paper sheet lands on "text".
NEUTRALS = [
    (0.00, "11111b"), (0.25, "1e1e2e"), (0.35, "313244"), (0.45, "45475a"), (0.55, "585b70"),
    (0.65, "6c7086"), (0.73, "7f849c"), (0.80, "9399b2"), (0.86, "a6adc8"), (0.91, "cdd6f4"),
    (1.00, "e6eaf9"),
]
PAPER = {"e4e4e4": "cdd6f4", "fafafa": "e1e6f8"}
REF_L = 0.62  # typical lightness of a Papirus accent


def srgb_to_lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def lin_to_srgb(c):
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def oklch(hexc):
    r, g, b = (srgb_to_lin(int(hexc[i : i + 2], 16) / 255) for i in (0, 2, 4))
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return L, math.hypot(a, bb), math.degrees(math.atan2(bb, a)) % 360


def to_hex(L, C, H):
    for _ in range(40):
        a, b = C * math.cos(math.radians(H)), C * math.sin(math.radians(H))
        l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
        m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
        s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
        rgb = [
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
        ]
        if all(-1e-4 <= c <= 1.0001 for c in rgb):
            break
        C *= 0.92
    return "".join("%02x" % round(max(0, min(1, lin_to_srgb(max(0, c)))) * 255) for c in rgb)


def hue_dist(a, b):
    d = abs(a - b) % 360
    return min(d, 360 - d)


MOCHA_LCH = [oklch(a) for a in MOCHA]
LATTE_LCH = [oklch(a) for a in LATTE]


def map_accent(hexc, palette):
    L, C, H = oklch(hexc)
    aL, aC, aH = min(palette, key=lambda t: hue_dist(t[2], H))
    return to_hex(max(0.25, min(0.95, aL + (L - REF_L) * 0.6)), aC * max(0.4, min(1.0, C / 0.15)), aH)


def map_gray(hexc):
    L = oklch(hexc)[0]
    for (l0, c0), (l1, c1) in zip(NEUTRALS, NEUTRALS[1:]):
        if L <= l1:
            t = (L - l0) / (l1 - l0)
            return "".join(
                "%02x" % round(int(c0[i : i + 2], 16) * (1 - t) + int(c1[i : i + 2], 16) * t) for i in (0, 2, 4)
            )
    return NEUTRALS[-1][1]


HEX = re.compile(r"#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b")
TAG = re.compile(r"<[^>]+>")
TRANSLUCENT = re.compile(r"(?<![\w-])(?:fill-)?opacity\s*[:=]\s*\"?\s*(0?\.\d+|0)\b")


def norm(h):
    h = h.lower()
    return "".join(c * 2 for c in h) if len(h) == 3 else h


def recolor(svg):
    colors = {norm(m) for m in HEX.findall(svg)}
    hues = [oklch(c)[2] for c in colors if oklch(c)[1] > 0.04]
    single = all(hue_dist(a, b) <= 40 for a in hues for b in hues)
    paper = bool(colors & PAPER.keys())
    palette = LATTE_LCH if paper else MOCHA_LCH

    def tag(t):
        # Translucent whites are highlights, not glyphs.
        dark_glyphs = hues and not paper and not TRANSLUCENT.search(t.group(0))

        def sub(m):
            c = norm(m.group(1))
            if c in PAPER:
                return "#" + PAPER[c]
            if not single:
                return m.group(0)
            L, C, _ = oklch(c)
            if C > 0.04:
                return "#" + map_accent(c, palette)
            if dark_glyphs and L > 0.95:
                return "#" + GLYPH
            return "#" + map_gray(c)

        return HEX.sub(sub, t.group(0))

    return TAG.sub(tag, svg)


# usage: papirus-catppuccin.py SRC_THEME_DIR DST_THEME_DIR NAME
# Mirrors SRC with its mimetype directories recolored and everything else symlinked. It can't just
# inherit SRC: KIconLoader tries a MIME-style name's generic fallback (application-menu ->
# application-x-generic) in each theme before moving on to the inherited one.
src, dst, name = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
for size in src.iterdir():
    if not size.is_dir():
        continue
    if "@" in size.name:
        (dst / size.name).symlink_to(size.readlink())
        continue
    (dst / size.name).mkdir()
    for d in size.iterdir():
        if d.name != "mimetypes":
            (dst / size.name / d.name).symlink_to(d.resolve())
            continue
        (dst / size.name / d.name).mkdir()
        for f in d.iterdir():
            if f.is_symlink() and "/" not in str(f.readlink()):
                (dst / size.name / d.name / f.name).symlink_to(f.readlink())
            else:
                (dst / size.name / d.name / f.name).write_text(recolor(f.read_text()))

index = (src / "index.theme").read_text()
index = re.sub(r"(?m)^Name=.*$", f"Name={name}", index, count=1)
(dst / "index.theme").write_text(index)

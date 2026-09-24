import colorsys
import json
import sys
from pathlib import Path

STEPS = [*range(0, 100, 10), *range(100, 800, 50), *range(800, 901, 10)]

# claude.ai derives its themed colors from primitive ramps: --cds-<hue>-<step> in hex, and
# --cds-hsl-<hue>-<step> as the HSL triplets its older styles read. Replacing the primitives
# rethemes every layer above them. Dark mode walks gray from 900 (page) to 0 (strongest text).
GRAY = {
    0: "text",
    50: "text",
    100: "subtext1",
    200: "subtext0",
    300: "overlay2",
    400: "overlay1",
    500: "overlay0",
    600: "surface2",
    700: "surface1",
    800: "surface0",
    900: "base",
}

# Dark mode reads text tints near 300, fills near 450 and background tints near 800.
HUES = {
    "red": "red",
    "orange": "peach",
    "yellow": "yellow",
    "green": "green",
    "aqua": "teal",
    "blue": "blue",
    "violet": "mauve",
    "magenta": "pink",
}

GIT = {
    "added": "green",
    "removed": "red",
    "modified": "yellow",
    "merged": "mauve",
    "closed": "red",
    "conflicting": "peach",
    "draft": "overlay1",
}


# Scripts such as the terminal set inline backgrounds from the app's own copies of its dark
# surfaces, which only an !important rule can override.
STOCK_SURFACES = {
    "rgb(21, 21, 21)": "surface-1",
    "rgb(26, 26, 25)": "surface-2",
    "rgb(32, 32, 31)": "surface-3",
}


def rgb(hex_):
    return tuple(int(hex_[i : i + 2], 16) / 255 for i in (0, 2, 4))


def mix(a, b, t):
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def to_hex(color):
    return "#" + "".join(f"{round(c * 255):02x}" for c in color)


def to_hsl(color):
    hue, lightness, saturation = colorsys.rgb_to_hls(*color)
    return f"{hue * 360:.4g} {saturation * 100:.4g}% {lightness * 100:.4g}%"


def ramp(anchors, step):
    below = max(a for a in anchors if a <= step)
    above = min(a for a in anchors if a >= step)
    if below == above:
        return anchors[below]
    return mix(anchors[below], anchors[above], (step - below) / (above - below))


def declare(name, color):
    return [f"--cds-{name}: {to_hex(color)}", f"--cds-hsl-{name}: {to_hsl(color)}"]


def gray(p):
    return {step: p[name] for step, name in GRAY.items()}


def root(p):
    ramps = {"gray": gray(p)}
    for hue, name in HUES.items():
        ramps[hue] = {0: p["text"], 300: p[name], 500: p[name], 900: p["base"]}
    for hue, anchors in ramps.items():
        for step in STEPS:
            yield from declare(f"{hue}-{step}", ramp(anchors, step))
    yield from declare("clay", mix(p["peach"], p["text"], 0.2))
    yield from declare("clay-emphasized", p["peach"])
    for role in ("accent", "danger", "pro"):
        yield f"--cds-role-{role}-on: {to_hex(p['base'])}"


def cds_root(p):
    yield f"--cds-on-brand: {to_hex(p['base'])}"
    for state, name in GIT.items():
        yield f"--cds-text-git-{state}: {to_hex(p[name])}"
        yield f"--cds-fill-git-{state}-hover: {to_hex(mix(p[name], p['text'], 0.2))}"


def block(selector, declarations):
    body = "".join(f"    {d} !important;\n" for d in declarations)
    return f"  {selector} {{\n{body}  }}\n"


def main():
    palette = {name: rgb(hex_) for name, hex_ in json.loads(sys.argv[1]).items()}
    glass = sys.argv[2]
    out = Path(sys.argv[3])
    out.mkdir()
    page = to_hex(ramp(gray(palette), 850))
    sidebar = to_hex(mix(ramp(gray(palette), 850), (0, 0, 0), 0.2))
    # Variables resolve var() where they are declared, so the primitives go on :root beside the
    # page's own mappings. The git colors are literals the page sets on .cds-root.
    (out / "claude.css").write_text(
        "@media (prefers-color-scheme: dark) {\n"
        + block(":root", root(palette))
        + block(".cds-root", cds_root(palette))
        # The code viewer and the panes set their backgrounds from the code theme's literals.
        + block("diffs-container", ["--diffs-dark-bg: var(--cds-surface-2)"])
        + block(
            '[style*="--code-theme-dark-bg"]',
            ["--code-theme-dark-bg: var(--cds-surface-2)"],
        )
        + "".join(
            block(
                f'[style*="background-color: {stock}"]',
                [f"background-color: var(--cds-{surface})"],
            )
            for stock, surface in STOCK_SURFACES.items()
        )
        # xterm paints its theme background into the canvas. Lightening against the themed
        # surface behind it replaces that darker background and keeps the lighter text.
        + block(".xterm-screen canvas", ["mix-blend-mode: lighten"])
        # The window is transparent, so the chrome bar shows glass through the content's top
        # edge, which runs under the sidebar too.
        + block(
            "body:has(.dframe-root[data-wco]), .bg-surface-1:has(.dframe-root[data-wco])",
            ["background: transparent"],
        )
        + block(
            ".dframe-root[data-wco] .dframe-content",
            [f"background: linear-gradient({glass} 0 var(--df-chrome-bar-height), var(--df-bg-page) 0)"],
        )
        + block(
            '.dframe-root[data-wco][data-variant="web"]:not([data-collapsed]) .dframe-sidebar',
            ["background: linear-gradient(transparent 0 var(--df-chrome-bar-height), var(--df-web-sidebar-bg) 0)"],
        )
        + "}\n"
    )
    # The window's own page stays under claude.ai, so its chrome-bar strip is left clear.
    (out / "shell.css").write_text(
        block(
            "body.darkTheme",
            [f"background: linear-gradient(transparent 0 36px, {page} 0)"],
        )
        + block(
            "body.darkTheme #boot-placeholder-sidebar",
            [f"background: linear-gradient(transparent 0 36px, {sidebar} 0)"],
        )
    )
    # Electron draws the window controls natively over the page's header, and the app's own
    # symbol color is its gray-200.
    (out / "title-bar-symbol").write_text(to_hex(ramp(gray(palette), 200)))


main()

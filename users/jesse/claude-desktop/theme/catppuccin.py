from collections.abc import Iterator

from css import Color, block, glass, media, mix, shell, to_hex, to_hsl

type Palette = dict[str, Color]

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

CODE_THEME = "catppuccin-mocha"


def ramp(anchors: dict[int, Color], step: int) -> Color:
    below = max(a for a in anchors if a <= step)
    above = min(a for a in anchors if a >= step)
    if below == above:
        return anchors[below]
    return mix(anchors[below], anchors[above], (step - below) / (above - below))


def declare(name: str, color: Color) -> list[str]:
    return [f"--cds-{name}: {to_hex(color)}", f"--cds-hsl-{name}: {to_hsl(color)}"]


def gray(mocha: Palette) -> dict[int, Color]:
    return {step: mocha[name] for step, name in GRAY.items()}


def root(mocha: Palette) -> Iterator[str]:
    ramps = {"gray": gray(mocha)}
    for hue, name in HUES.items():
        ramps[hue] = {0: mocha["text"], 300: mocha[name], 500: mocha[name], 900: mocha["base"]}
    for hue, anchors in ramps.items():
        for step in STEPS:
            yield from declare(f"{hue}-{step}", ramp(anchors, step))
    yield from declare("clay", mix(mocha["peach"], mocha["text"], 0.2))
    yield from declare("clay-emphasized", mocha["peach"])
    for role in ("accent", "danger", "pro"):
        yield f"--cds-role-{role}-on: {to_hex(mocha['base'])}"


def cds_root(mocha: Palette) -> Iterator[str]:
    yield f"--cds-on-brand: {to_hex(mocha['base'])}"
    for state, name in GIT.items():
        yield f"--cds-text-git-{state}: {to_hex(mocha[name])}"
        yield f"--cds-fill-git-{state}-hover: {to_hex(mix(mocha[name], mocha['text'], 0.2))}"


def claude_css(mocha: Palette, chrome: str) -> str:
    # Variables resolve var() where they are declared, so the primitives go on :root beside the
    # page's own mappings. The git colors are literals the page sets on .cds-root.
    return media(
        "dark",
        [
            block(":root", root(mocha)),
            block(".cds-root", cds_root(mocha)),
            # The code viewer and the panes set their backgrounds from the code theme's literals.
            block("diffs-container", ["--diffs-dark-bg: var(--cds-surface-2)"]),
            block('[style*="--code-theme-dark-bg"]', ["--code-theme-dark-bg: var(--cds-surface-2)"]),
            *(
                block(f'[style*="background-color: {stock}"]', [f"background-color: var(--cds-{surface})"])
                for stock, surface in STOCK_SURFACES.items()
            ),
            # xterm paints its theme background into the canvas. Lightening against the themed
            # surface behind it replaces that darker background and keeps the lighter text.
            block(".xterm-screen canvas", ["mix-blend-mode: lighten"]),
            *glass(chrome),
        ],
    )


def shell_css(mocha: Palette) -> str:
    page = ramp(gray(mocha), 850)
    return shell("body.darkTheme", to_hex(page), to_hex(mix(page, (0, 0, 0), 0.2)))


# Electron draws the window controls natively over the page's header, and the app's own symbol
# color is its gray-200.
def title_bar_symbol(mocha: Palette) -> str:
    return to_hex(ramp(gray(mocha), 200))

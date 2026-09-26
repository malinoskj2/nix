import colorsys
import sys
from pathlib import Path

# claude.ai's light surfaces and text all come from this gray ramp.
STOCK = {
    0: "ffffff",
    10: "fcfcfb",
    20: "f9f9f7",
    30: "f6f6f4",
    40: "f3f3f0",
    50: "f0efec",
    60: "edece8",
    70: "eae9e4",
    80: "e7e6e1",
    90: "e4e3dd",
    100: "e1e0d9",
    150: "d2d1c7",
    200: "c3c2b7",
    250: "b4b3a8",
    300: "a5a49a",
    350: "97958d",
    400: "898781",
    450: "7b7974",
    500: "6d6b67",
    550: "5f5e5a",
    600: "52514e",
    650: "454442",
    700: "383835",
    750: "2c2c2a",
    800: "20201f",
    810: "1e1e1d",
    820: "1c1c1b",
    830: "1a1a19",
    840: "181817",
    850: "151515",
    860: "131313",
    870: "111111",
    880: "0f0f0f",
    890: "0d0d0d",
    900: "0b0b0b",
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


def declare(ramp, legacy=False):
    for step, color in ramp.items():
        yield f"--cds-gray-{step}: {to_hex(color)}"
        yield f"--cds-hsl-gray-{step}: {to_hsl(color)}"
        # The older tokens read copies of the ramp that :root resolves once.
        if legacy:
            yield f"--_gray-{step}: {to_hsl(color)}"


def block(selector, declarations):
    body = "".join(f"    {d} !important;\n" for d in declarations)
    return f"  {selector} {{\n{body}  }}\n"


def main():
    glass = sys.argv[1]
    toward = rgb(sys.argv[2])
    amount = int(sys.argv[3]) / 100
    out = Path(sys.argv[4])
    out.mkdir()
    stock = {step: rgb(hex_) for step, hex_ in STOCK.items()}
    # Lighter shades move further, so surfaces step toward the bar and text keeps its contrast.
    dimmed = {step: mix(color, toward, amount * colorsys.rgb_to_hls(*color)[1]) for step, color in stock.items()}
    (out / "claude.css").write_text(
        "@media (prefers-color-scheme: light) {\n"
        + block(":root", declare(dimmed))
        # The bar's dark scope reads the light end of the ramp for its text.
        + block(".cds-dark-scope", declare(stock, legacy=True))
        # Text that inherits its color rather than taking a token would keep the page's.
        + block(".dframe-chrome-bar.cds-dark-scope", ["color: var(--cds-text-primary)"])
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
    page = to_hex(dimmed[10])
    sidebar = to_hex(mix(dimmed[20], dimmed[10], 0.5))
    (out / "shell.css").write_text(
        block(
            "body:not(.darkTheme)",
            [f"background: linear-gradient(transparent 0 36px, {page} 0)"],
        )
        + block(
            "body:not(.darkTheme) #boot-placeholder-sidebar",
            [f"background: linear-gradient(transparent 0 36px, {sidebar} 0)"],
        )
    )


main()

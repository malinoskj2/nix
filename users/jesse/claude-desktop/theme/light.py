import colorsys
from collections.abc import Iterator

from css import Color, block, glass, media, mix, rgb, shell, to_hex, to_hsl

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

# How far the page's white moves toward the bar's crust.
DIM = 0.08

# The bar is dark glass, so its window controls take the symbol color the app uses in dark mode.
TITLE_BAR_SYMBOL = "#c2c0b6"


def stock() -> dict[int, Color]:
    return {step: rgb(hex_) for step, hex_ in STOCK.items()}


# Lighter shades move further, so surfaces step toward the bar and text keeps its contrast.
def dimmed(crust: Color) -> dict[int, Color]:
    return {step: mix(color, crust, DIM * colorsys.rgb_to_hls(*color)[1]) for step, color in stock().items()}


def declare(ramp: dict[int, Color], legacy: bool = False) -> Iterator[str]:
    for step, color in ramp.items():
        yield f"--cds-gray-{step}: {to_hex(color)}"
        yield f"--cds-hsl-gray-{step}: {to_hsl(color)}"
        # The older tokens read copies of the ramp that :root resolves once.
        if legacy:
            yield f"--_gray-{step}: {to_hsl(color)}"


def claude_css(mocha: dict[str, Color], chrome: str) -> str:
    return media(
        "light",
        [
            block(":root", declare(dimmed(mocha["crust"]))),
            # The bar's dark scope reads the light end of the ramp for its text.
            block(".cds-dark-scope", declare(stock(), legacy=True)),
            # Text that inherits its color rather than taking a token would keep the page's.
            block(".dframe-chrome-bar.cds-dark-scope", ["color: var(--cds-text-primary)"]),
            *glass(chrome),
        ],
    )


def shell_css(mocha: dict[str, Color]) -> str:
    ramp = dimmed(mocha["crust"])
    return shell("body:not(.darkTheme)", to_hex(ramp[10]), to_hex(mix(ramp[20], ramp[10], 0.5)))

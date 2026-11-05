import colorsys
from collections.abc import Iterable

type Color = tuple[float, float, float]

# The window's own page has no chrome-bar variable, so it repeats the bar's height.
BAR_HEIGHT = "36px"


def rgb(hex_: str) -> Color:
    return tuple(int(hex_[i : i + 2], 16) / 255 for i in (0, 2, 4))


def mix(a: Color, b: Color, t: float) -> Color:
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def to_hex(color: Color) -> str:
    return "#" + "".join(f"{round(c * 255):02x}" for c in color)


def to_hsl(color: Color) -> str:
    hue, lightness, saturation = colorsys.rgb_to_hls(*color)
    return f"{hue * 360:.4g} {saturation * 100:.4g}% {lightness * 100:.4g}%"


def block(selector: str, declarations: Iterable[str]) -> str:
    body = "".join(f"    {d} !important;\n" for d in declarations)
    return f"  {selector} {{\n{body}  }}\n"


def media(scheme: str, blocks: Iterable[str]) -> str:
    return f"@media (prefers-color-scheme: {scheme}) {{\n" + "".join(blocks) + "}\n"


# The window is transparent, so the chrome bar shows glass through the content's top edge, which
# runs under the sidebar too.
def glass(chrome: str) -> list[str]:
    return [
        block(
            "body:has(.dframe-root[data-wco]), .bg-surface-1:has(.dframe-root[data-wco])",
            ["background: transparent"],
        ),
        block(
            ".dframe-root[data-wco] .dframe-content",
            [f"background: linear-gradient({chrome} 0 var(--df-chrome-bar-height), var(--df-bg-page) 0)"],
        ),
        block(
            '.dframe-root[data-wco][data-variant="web"]:not([data-collapsed]) .dframe-sidebar',
            ["background: linear-gradient(transparent 0 var(--df-chrome-bar-height), var(--df-web-sidebar-bg) 0)"],
        ),
    ]


# The window's own page stays under claude.ai, so its chrome-bar strip is left clear.
def shell(body: str, page: str, sidebar: str) -> str:
    return block(
        body,
        [f"background: linear-gradient(transparent 0 {BAR_HEIGHT}, {page} 0)"],
    ) + block(
        f"{body} #boot-placeholder-sidebar",
        [f"background: linear-gradient(transparent 0 {BAR_HEIGHT}, {sidebar} 0)"],
    )

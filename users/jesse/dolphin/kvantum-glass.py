"""Turn a Kvantum theme's window background into translucent glass.

Reads SOURCE.kvconfig and SOURCE.svg and writes the edited pair to DESTINATION.kvconfig and
DESTINATION.svg. How Kvantum chooses between the Window and Dialog elements, which the edits rely
on, is explained in users/jesse/dolphin/kvantum-theme.nix.
"""

import argparse
import re
from pathlib import Path

CONFIG_EDITS: dict[str, dict[str, str]] = {
    "%General": {
        "translucent_windows": "true",
        "reduce_window_opacity": "1",
        # Hyprland does the blur.
        "blurring": "false",
        "popup_blurring": "false",
    },
    "Toolbar": {"interior": "false", "frame.element": "tabframe"},
    "Dialog": {"interior": "true", "interior.element": "solid"},
    # Inherits Toolbar, so it needs its own opaque interior back.
    "StatusBar": {"interior": "true", "interior.element": "toolbar"},
}
SECTION_HEADER = re.compile(r"\[(.+)\]$")
WINDOW_GROUP = re.compile(r'<g id="window-normal-[a-z]+".*?</g>', re.DOTALL)
WINDOW_RECT = re.compile(r'<rect id="window-normal"[^>]*>')


def missing_settings(section: str | None, applied: set[tuple[str, str]]) -> list[str]:
    edits = CONFIG_EDITS.get(section, {})
    return [f"{key}={value}" for key, value in edits.items() if (section, key) not in applied]


def edit_config(text: str) -> str:
    lines: list[str] = []
    section: str | None = None
    applied: set[tuple[str, str]] = set()

    for line in text.splitlines():
        header = SECTION_HEADER.match(line)
        if header:
            # Settings the section lacks go after its last entry, before the blank separator.
            if section is not None:
                while lines and lines[-1] == "":
                    lines.pop()
                lines.extend(missing_settings(section, applied))
                lines.append("")
            section = header.group(1)
            lines.append(line)
            continue

        key = line.split("=", 1)[0]
        edits = CONFIG_EDITS.get(section, {})
        if key in edits:
            lines.append(f"{key}={edits[key]}")
            applied.add((section, key))
        else:
            lines.append(line)
    lines.extend(missing_settings(section, applied))

    return "\n".join(lines) + "\n"


def edit_svg(svg: str, base: str, glass: str, opacity: str) -> str:
    def glaze(element: str) -> str:
        return element.replace(f"fill:#{base}", f"fill:#{glass};fill-opacity:{opacity}")

    def glaze_group(match: re.Match[str]) -> str:
        return glaze(match.group(0))

    # Dialog's interior points at solid-normal, an unglazed copy of the window rect, so it covers
    # the same area of the SVG.
    def glaze_rect(match: re.Match[str]) -> str:
        rect = match.group(0)
        solid = rect.replace('id="window-normal"', 'id="solid-normal"')
        return f"{solid}\n {glaze(rect)}"

    svg = WINDOW_GROUP.sub(glaze_group, svg)
    return WINDOW_RECT.sub(glaze_rect, svg, count=1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source", help="theme path without the .kvconfig and .svg suffixes")
    parser.add_argument("destination", help="output path without the .kvconfig and .svg suffixes")
    parser.add_argument("base", help="window color as the theme's SVG spells it, bare uppercase rrggbb")
    parser.add_argument("glass", help="glass color, as bare rrggbb")
    parser.add_argument("opacity", help="glass fill-opacity")
    args = parser.parse_args()

    config = Path(f"{args.source}.kvconfig").read_text()
    Path(f"{args.destination}.kvconfig").write_text(edit_config(config))

    svg = Path(f"{args.source}.svg").read_text()
    Path(f"{args.destination}.svg").write_text(edit_svg(svg, args.base, args.glass, args.opacity))


if __name__ == "__main__":
    main()

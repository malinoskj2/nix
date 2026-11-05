import argparse
import json
from pathlib import Path

import catppuccin
import light
from css import rgb


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Write a Claude Desktop theme: Catppuccin Mocha in dark mode and a dimmed light mode."
    )
    parser.add_argument("palette", type=json.loads, help="JSON object of the Mocha flavor as bare rrggbb strings")
    parser.add_argument("chrome", help="title bar glass color as #rrggbbaa")
    parser.add_argument("destination", type=Path, help="output directory, which must not exist yet")
    args = parser.parse_args()

    mocha = {name: rgb(hex_) for name, hex_ in args.palette.items()}
    # Each scheme's CSS sits in its own prefers-color-scheme query, so the app's appearance
    # setting picks one.
    files = {
        "claude.css": light.claude_css(mocha, args.chrome) + catppuccin.claude_css(mocha, args.chrome),
        "shell.css": light.shell_css(mocha) + catppuccin.shell_css(mocha),
        "title-bar-symbol": catppuccin.title_bar_symbol(mocha),
        "title-bar-symbol-light": light.TITLE_BAR_SYMBOL,
        "code-theme-dark": catppuccin.CODE_THEME,
    }

    args.destination.mkdir()
    for name, text in files.items():
        (args.destination / name).write_text(text)


if __name__ == "__main__":
    main()

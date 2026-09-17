import re
import sys

src, dst, base, glass, opacity = sys.argv[1:]

edits = {
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
out, section, done = [], None, set()


def flush():
    for k, v in edits.get(section, {}).items():
        if (section, k) not in done:
            out.append(k + "=" + v)


for line in open(src + ".kvconfig").read().splitlines():
    m = re.match(r"\[(.+)\]$", line)
    if m:
        if section is not None:
            while out and out[-1] == "":
                out.pop()
            flush()
            out.append("")
        section = m.group(1)
    else:
        key = line.split("=", 1)[0]
        if key in edits.get(section, {}):
            line = key + "=" + edits[section][key]
            done.add((section, key))
    out.append(line)
flush()
open(dst + ".kvconfig", "w").write("\n".join(out) + "\n")

svg = open(src + ".svg").read()
to_glass = lambda m: m.group(0).replace(f"fill:#{base}", f"fill:#{glass};fill-opacity:{opacity}")
svg = re.sub(r'<g id="window-normal-[a-z]+".*?</g>', to_glass, svg, flags=re.S)
svg = re.sub(r'<rect id="window-normal"[^>]*>', to_glass, svg)
svg = svg.replace(
    '<rect id="window-normal"',
    f'<rect id="solid-normal" style="fill:#{base}" width="46" height="46" x="767" y="254"/>\n <rect id="window-normal"',
    1,
)
open(dst + ".svg", "w").write(svg)

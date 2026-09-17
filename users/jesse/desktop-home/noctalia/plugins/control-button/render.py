"""Render the control button's frames: rest.png plus the hover shimmer loop.

Needs ImageMagick with librsvg.
"""

import argparse
import json
import math
import os
import subprocess
import tempfile

SUPERSAMPLE = 8
LOGO_SIZE = 17
# Not a Catppuccin colour: a hotter pink between peach and mauve in the shimmer.
SHIMMER_ROSE = "f5a3d0"


def magick(*args):
    subprocess.run(["magick", *args], check=True)


def pill_svg(colors, width, height, hover, angle=0.0):
    radius = height / 2
    fill_opacity = 0.10 if hover else 0.05
    center_x, center_y = width / 2, height / 2
    half_length = width / 2
    offset_x = math.cos(math.radians(angle)) * half_length
    offset_y = math.sin(math.radians(angle)) * half_length
    iridescent = [colors["peach"], SHIMMER_ROSE, colors["mauve"], colors["blue"], colors["sky"], colors["peach"]]
    stops = "".join(
        f'<stop offset="{i / (len(iridescent) - 1):.3f}" stop-color="#{color}"/>' for i, color in enumerate(iridescent)
    )
    shape = f'x="0" y="0" width="{width}" height="{height}" rx="{radius}"'
    edge_shape = f'x="0.5" y="0.5" width="{width - 1}" height="{height - 1}" rx="{radius - 0.5}"'
    defs = f"""
    <linearGradient id="iri" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#{colors["peach"]}" stop-opacity="0.07"/>
      <stop offset="0.5" stop-color="#{SHIMMER_ROSE}" stop-opacity="0.06"/>
      <stop offset="1" stop-color="#{colors["blue"]}" stop-opacity="0.08"/>
    </linearGradient>
    <linearGradient id="shimmer" gradientUnits="userSpaceOnUse" spreadMethod="reflect"
      x1="{center_x - offset_x:.3f}" y1="{center_y - offset_y:.3f}"
      x2="{center_x + offset_x:.3f}" y2="{center_y + offset_y:.3f}">{stops}</linearGradient>
    <clipPath id="clip"><rect {shape}/></clipPath>"""
    body = (
        f'<g clip-path="url(#clip)"><rect {shape} fill="#fff" fill-opacity="{fill_opacity}"/>'
        f'<rect {shape} fill="url(#iri)"/></g>'
    )
    if hover:
        body += f'<rect {edge_shape} fill="none" stroke="url(#shimmer)" stroke-width="1" stroke-opacity="0.95"/>'
    else:
        body += f'<rect {edge_shape} fill="none" stroke="#fff" stroke-opacity="0.30" stroke-width="1"/>'
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width * SUPERSAMPLE}" height="{height * SUPERSAMPLE}" '
        f'viewBox="0 0 {width} {height}"><defs>{defs}</defs>{body}</svg>'
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("logo_template", help="SVG with @lambda1@..@lambda6@ fill placeholders")
    parser.add_argument("out")
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    parser.add_argument("--frames", type=int, required=True)
    parser.add_argument(
        "--colors", type=json.loads, required=True, help='JSON: {"palette": {name: hex}, "lambdas": [hex, ...]}'
    )
    args = parser.parse_args()
    width, height = args.width, args.height
    palette = args.colors["palette"]

    os.makedirs(args.out, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        with open(args.logo_template) as f:
            logo_svg = f.read()
        for i, color in enumerate(args.colors["lambdas"], start=1):
            logo_svg = logo_svg.replace(f"@lambda{i}@", color)
        logo_svg_path = os.path.join(tmp, "logo.svg")
        with open(logo_svg_path, "w") as f:
            f.write(logo_svg)

        logo = os.path.join(tmp, "logo.png")
        magick("-background", "none", "-density", "1200", logo_svg_path, "-resize", f"{LOGO_SIZE}x{LOGO_SIZE}", logo)
        logo_x, logo_y = round(width / 2 - LOGO_SIZE / 2), round(height / 2 - LOGO_SIZE / 2)

        def emit(svg, name):
            src = os.path.join(tmp, name + ".svg")
            with open(src, "w") as f:
                f.write(svg)
            # Timestamp chunks would make the output depend on when it was built.
            magick(
                "-background", "none", src, "-filter", "lanczos", "-resize", f"{width}x{height}",
                logo, "-geometry", f"+{logo_x}+{logo_y}", "-composite",
                "-define", "png:exclude-chunks=date,time", os.path.join(args.out, name + ".png"),
            )  # fmt: skip

        emit(pill_svg(palette, width, height, False), "rest")
        for i in range(args.frames):
            emit(pill_svg(palette, width, height, True, angle=360 * i / args.frames), f"hover-{i:02d}")


if __name__ == "__main__":
    main()

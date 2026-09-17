"""Render the control button's frames: rest.png plus the hover shimmer loop.

Requires ImageMagick with librsvg.
"""

import argparse
import json
import math
import subprocess
import tempfile
from pathlib import Path

SUPERSAMPLE = 8
LOGO_SIZE = 17
FILL_OPACITY = 0.05
HOVER_FILL_OPACITY = 0.10
EDGE_OPACITY = 0.30
SHIMMER_OPACITY = 0.95

# This pink stays outside the palette because the shimmer needs a hotter step from peach to mauve.
SHIMMER_ROSE = "f5a3d0"


def run_magick(*args: str | Path) -> None:
    subprocess.run(["magick", *args], check=True)


def build_pill_svg(
    palette: dict[str, str],
    *,
    width: int,
    height: int,
    hover: bool,
    angle: float = 0.0,
) -> str:
    radius = height / 2
    fill_opacity = HOVER_FILL_OPACITY if hover else FILL_OPACITY
    center_x, center_y = width / 2, height / 2
    half_length = width / 2
    offset_x = math.cos(math.radians(angle)) * half_length
    offset_y = math.sin(math.radians(angle)) * half_length
    shimmer_colors = [
        palette["peach"],
        SHIMMER_ROSE,
        palette["mauve"],
        palette["blue"],
        palette["sky"],
        palette["peach"],
    ]
    last = len(shimmer_colors) - 1
    stops = "".join(f'<stop offset="{i / last:.3f}" stop-color="#{color}"/>' for i, color in enumerate(shimmer_colors))
    shape = f'x="0" y="0" width="{width}" height="{height}" rx="{radius}"'
    edge_shape = f'x="0.5" y="0.5" width="{width - 1}" height="{height - 1}" rx="{radius - 0.5}"'
    defs = f"""
    <linearGradient id="tint" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#{palette["peach"]}" stop-opacity="0.07"/>
      <stop offset="0.5" stop-color="#{SHIMMER_ROSE}" stop-opacity="0.06"/>
      <stop offset="1" stop-color="#{palette["blue"]}" stop-opacity="0.08"/>
    </linearGradient>
    <linearGradient id="shimmer" gradientUnits="userSpaceOnUse" spreadMethod="reflect"
      x1="{center_x - offset_x:.3f}" y1="{center_y - offset_y:.3f}"
      x2="{center_x + offset_x:.3f}" y2="{center_y + offset_y:.3f}">{stops}</linearGradient>
    <clipPath id="clip"><rect {shape}/></clipPath>"""
    body = (
        f'<g clip-path="url(#clip)"><rect {shape} fill="#fff" fill-opacity="{fill_opacity}"/>'
        f'<rect {shape} fill="url(#tint)"/></g>'
    )
    if hover:
        stroke = f'stroke="url(#shimmer)" stroke-width="1" stroke-opacity="{SHIMMER_OPACITY:.2f}"'
    else:
        stroke = f'stroke="#fff" stroke-width="1" stroke-opacity="{EDGE_OPACITY:.2f}"'
    body += f'<rect {edge_shape} fill="none" {stroke}/>'
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" '
        f'width="{width * SUPERSAMPLE}" height="{height * SUPERSAMPLE}" '
        f'viewBox="0 0 {width} {height}"><defs>{defs}</defs>{body}</svg>'
    )


def render_logo(template: Path, *, lambdas: list[str], work_dir: Path) -> Path:
    svg = template.read_text()
    for i, color in enumerate(lambdas, start=1):
        svg = svg.replace(f"@lambda{i}@", color)

    svg_path = work_dir / "logo.svg"
    svg_path.write_text(svg)

    logo_path = work_dir / "logo.png"
    run_magick(
        "-background", "none", "-density", "1200", svg_path,
        "-resize", f"{LOGO_SIZE}x{LOGO_SIZE}", logo_path,
    )  # fmt: skip
    return logo_path


def render_frame(
    name: str,
    svg: str,
    *,
    logo_path: Path,
    width: int,
    height: int,
    work_dir: Path,
    out_dir: Path,
) -> None:
    svg_path = work_dir / f"{name}.svg"
    svg_path.write_text(svg)

    logo_x, logo_y = round(width / 2 - LOGO_SIZE / 2), round(height / 2 - LOGO_SIZE / 2)
    # Timestamp chunks would make the output depend on when it was built.
    run_magick(
        "-background", "none", svg_path, "-filter", "lanczos", "-resize", f"{width}x{height}",
        logo_path, "-geometry", f"+{logo_x}+{logo_y}", "-composite",
        "-define", "png:exclude-chunks=date,time", out_dir / f"{name}.png",
    )  # fmt: skip


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--logo", type=Path, required=True, help="SVG with @lambda1@..@lambda6@ fill placeholders")
    parser.add_argument("--out-dir", type=Path, required=True, help="directory that receives the PNG frames")
    parser.add_argument("--width", type=int, required=True, help="button width in pixels")
    parser.add_argument("--height", type=int, required=True, help="button height in pixels")
    parser.add_argument("--frame-count", type=int, required=True, help="frames in the hover loop")
    parser.add_argument("--palette", type=json.loads, required=True, help="JSON: {name: hex}")
    parser.add_argument("--lambdas", type=json.loads, required=True, help="JSON: [hex, ...]")
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temp_dir:
        work_dir = Path(temp_dir)
        logo_path = render_logo(args.logo, lambdas=args.lambdas, work_dir=work_dir)

        frames = [("rest", build_pill_svg(args.palette, width=args.width, height=args.height, hover=False))]
        for i in range(args.frame_count):
            angle = 360 * i / args.frame_count
            svg = build_pill_svg(args.palette, width=args.width, height=args.height, hover=True, angle=angle)
            frames.append((f"hover-{i:02d}", svg))

        for name, svg in frames:
            render_frame(
                name,
                svg,
                logo_path=logo_path,
                width=args.width,
                height=args.height,
                work_dir=work_dir,
                out_dir=args.out_dir,
            )


if __name__ == "__main__":
    main()

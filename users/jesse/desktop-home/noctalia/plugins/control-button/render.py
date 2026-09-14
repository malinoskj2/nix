#!/usr/bin/env python3
# Regenerates frames/: rest.png plus the hover shimmer loop. Needs ImageMagick with librsvg.
import math, os, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "frames")
LOGO_SVG = os.path.join(HERE, "snowflake.svg")

W, H = 52, 24
PW, PH, PX, PY = 52, 24, 0, 0
R = PH / 2
SS = 8
FRAMES = 48
LOGO = 17
GLINT = False

IRIDESCENT = ["#fab387", "#f5a3d0", "#cba6f7", "#89b4fa", "#89dceb", "#fab387"]


def run(*a):
    subprocess.run(a, check=True)


def perimeter_point(t):
    """Point at fraction t (clockwise from top-left straight) around the stadium outline."""
    straight = PW - PH
    arc = math.pi * R
    total = 2 * straight + 2 * arc
    d = (t % 1.0) * total
    x0, x1, cy = PX + R, PX + PW - R, PY + R
    if d < straight:
        return x0 + d, PY
    d -= straight
    if d < arc:
        a = -math.pi / 2 + d / R
        return x1 + R * math.cos(a), cy + R * math.sin(a)
    d -= arc
    if d < straight:
        return x1 - d, PY + PH
    d -= straight
    a = math.pi / 2 + d / R
    return x0 + R * math.cos(a), cy + R * math.sin(a)


def pill_svg(hover, angle=0.0, glint=None):
    fill = 0.10 if hover else 0.05
    cx, cy = PX + PW / 2, PY + PH / 2
    L = PW / 2
    ax, ay = math.cos(math.radians(angle)) * L, math.sin(math.radians(angle)) * L
    stops = "".join(f'<stop offset="{i/(len(IRIDESCENT)-1):.3f}" stop-color="{c}"/>' for i, c in enumerate(IRIDESCENT))
    shape = f'x="{PX}" y="{PY}" width="{PW}" height="{PH}" rx="{R}"'
    edge_shape = f'x="{PX+0.5}" y="{PY+0.5}" width="{PW-1}" height="{PH-1}" rx="{R-0.5}"'
    defs = f'''
    <linearGradient id="iri" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#fab387" stop-opacity="0.07"/>
      <stop offset="0.5" stop-color="#f5a3d0" stop-opacity="0.06"/>
      <stop offset="1" stop-color="#89b4fa" stop-opacity="0.08"/>
    </linearGradient>
    <linearGradient id="shimmer" gradientUnits="userSpaceOnUse" spreadMethod="reflect"
      x1="{cx-ax:.3f}" y1="{cy-ay:.3f}" x2="{cx+ax:.3f}" y2="{cy+ay:.3f}">{stops}</linearGradient>
    <clipPath id="clip"><rect {shape}/></clipPath>'''
    if glint:
        gx, gy = glint
        defs += (f'<radialGradient id="glint" gradientUnits="userSpaceOnUse" cx="{gx:.3f}" cy="{gy:.3f}" r="10">'
                 '<stop offset="0" stop-color="#fff" stop-opacity="1"/><stop offset="1" stop-color="#fff" stop-opacity="0"/>'
                 '</radialGradient>')
    body = (f'<g clip-path="url(#clip)"><rect {shape} fill="#fff" fill-opacity="{fill}"/>'
            f'<rect {shape} fill="url(#iri)"/></g>')
    if hover:
        body += f'<rect {edge_shape} fill="none" stroke="url(#shimmer)" stroke-width="1" stroke-opacity="0.95"/>'
        if glint and GLINT:
            body += f'<rect {edge_shape} fill="none" stroke="url(#glint)" stroke-width="1.6"/>'
    else:
        body += f'<rect {edge_shape} fill="none" stroke="#fff" stroke-opacity="0.30" stroke-width="1"/>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W*SS}" height="{H*SS}" viewBox="0 0 {W} {H}">'
            f'<defs>{defs}</defs>{body}</svg>')


def main():
    os.makedirs(OUT, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        logo = os.path.join(tmp, "logo.png")
        run("magick", "-background", "none", "-density", "1200", LOGO_SVG, "-resize", f"{LOGO}x{LOGO}", logo)
        lx, ly = round(PX + PW / 2 - LOGO / 2), round(PY + PH / 2 - LOGO / 2)

        def emit(svg, name):
            src = os.path.join(tmp, name + ".svg")
            open(src, "w").write(svg)
            run("magick", "-background", "none", src, "-filter", "lanczos", "-resize", f"{W}x{H}",
                logo, "-geometry", f"+{lx}+{ly}", "-composite", os.path.join(OUT, name + ".png"))

        emit(pill_svg(False), "rest")
        for i in range(FRAMES):
            t = i / FRAMES
            emit(pill_svg(True, angle=360 * t, glint=perimeter_point(t)), f"hover-{i:02d}")


if __name__ == "__main__":
    main()

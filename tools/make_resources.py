#!/usr/bin/env python3
"""Generates the Settings row icon the package ships.

The stage draws everything else it shows with Core Graphics at runtime, so this
is the only artwork in the repository, and it can be rebuilt rather than trusted.

    python3 tools/make_resources.py

Writes Library/PreferenceLoader/Preferences/DynamicStage/icon{,@2x,@3x}.png.
"""

from __future__ import annotations

import math
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "layout", "Library", "PreferenceLoader",
                   "Preferences", "DynamicStage")

SUPERSAMPLE = 8


def superellipse(box, exponent=5.0, steps=720):
    """Points tracing an iOS-style squircle inscribed in `box`."""
    x0, y0, x1, y1 = box
    cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
    rx, ry = (x1 - x0) / 2.0, (y1 - y0) / 2.0

    points = []
    for step in range(steps):
        theta = 2.0 * math.pi * step / steps
        ct, st = math.cos(theta), math.sin(theta)
        x = cx + rx * math.copysign(abs(ct) ** (2.0 / exponent), ct)
        y = cy + ry * math.copysign(abs(st) ** (2.0 / exponent), st)
        points.append((x, y))
    return points


def bezier(p0, p1, p2, p3, steps=64):
    points = []
    for step in range(steps + 1):
        t = step / steps
        u = 1.0 - t
        x = u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0]
        y = u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1]
        points.append((x, y))
    return points


def arrow_path(side, offset=(0.0, 0.0)):
    """The mark's arrow: tail out of the bottom-right corner into an up head.

    Traced on the same 100x100 grid DSLogoView uses so the Settings icon and the
    one the intro draws at runtime are the same shape.
    """
    u = side / 100.0
    ox, oy = offset

    def point(x, y):
        return (ox + x * u, oy + y * u)

    path = [point(84, 90)]
    path += bezier(point(84, 90), point(58, 82), point(50, 66), point(50, 46))
    path += [point(50, 34), point(32, 34), point(50, 13), point(68, 34), point(58, 34), point(58, 46)]
    path += bezier(point(58, 46), point(58, 60), point(64, 68), point(78, 73))
    return path


def render(size, draw_calls):
    """Draws at 8x and downsamples, which is the cheapest decent antialiasing."""
    canvas = Image.new("RGBA", (size * SUPERSAMPLE, size * SUPERSAMPLE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    draw_calls(draw, size * SUPERSAMPLE)
    return canvas.resize((size, size), Image.LANCZOS)


def write_icon(size, name):
    """Settings row icon: black app tile, white squircle, black arrow."""
    inset_ratio = 0.115

    def calls(draw, side):
        draw.polygon(superellipse((0, 0, side, side), exponent=5.0), fill=(8, 8, 10, 255))
        inset = side * inset_ratio
        draw.polygon(
            superellipse((inset, inset, side - inset, side - inset), exponent=4.6),
            fill=(255, 255, 255, 255),
        )
        arrow_side = side - inset * 2.0
        draw.polygon(arrow_path(arrow_side, offset=(inset, inset)), fill=(8, 8, 10, 255))

    render(size, calls).save(os.path.join(OUT, name))


def main():
    os.makedirs(OUT, exist_ok=True)
    write_icon(29, "icon.png")
    write_icon(58, "icon@2x.png")
    write_icon(87, "icon@3x.png")
    print("wrote", OUT)


if __name__ == "__main__":
    main()

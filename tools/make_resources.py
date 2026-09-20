#!/usr/bin/env python3
"""Generates the PNGs the preference bundle ships with.

Everything the bundle draws is either rendered at runtime with Core Graphics or
produced here, so the repository carries no binary artwork it cannot rebuild.

    python3 tools/make_resources.py

Writes prefs/Resources/{icon,icon@2x,icon@3x,logo@3x,bg,double,tripple}.png.
"""

from __future__ import annotations

import math
import os

import numpy
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "prefs", "Resources")

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


def write_logo(size=72):
    """White squircle with the arrow punched straight through it."""

    def calls(draw, side):
        draw.polygon(superellipse((0, 0, side, side)), fill=(255, 255, 255, 255))

    image = render(size, calls)

    hole = render(size, lambda draw, side: draw.polygon(arrow_path(side), fill=(0, 0, 0, 255)))
    mask = hole.split()[3].point(lambda value: 255 - value)
    alpha = Image.new("L", image.size, 0)
    alpha.paste(image.split()[3], mask=mask)
    image.putalpha(alpha)

    image.save(os.path.join(OUT, "logo@3x.png"))


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


def wallpaper(size):
    """Soft colour field standing in for the clip the stock banner loops."""
    width, height = size
    xs = numpy.linspace(0.0, 1.0, width)[None, :]
    ys = numpy.linspace(0.0, 1.0, height)[:, None]

    field = numpy.zeros((height, width, 3), dtype=numpy.float64)
    weight = numpy.full((height, width), 1e-6)

    blobs = [
        ((0.16, 0.04), 0.40, (238, 140, 32)),
        ((0.80, 0.00), 0.34, (198, 58, 44)),
        ((0.50, 0.42), 0.52, (34, 56, 146)),
        ((0.06, 0.60), 0.40, (84, 46, 140)),
        ((0.90, 0.70), 0.42, (214, 104, 132)),
        ((0.40, 1.00), 0.46, (232, 160, 150)),
    ]
    aspect = height / float(width)
    for (cx, cy), radius, colour in blobs:
        distance = numpy.sqrt((xs - cx) ** 2 + ((ys - cy) * aspect) ** 2)
        falloff = numpy.exp(-(distance / radius) ** 2)
        weight += falloff
        for channel in range(3):
            field[:, :, channel] += falloff * colour[channel]

    field /= weight[:, :, None]
    image = Image.fromarray(numpy.clip(field, 0, 255).astype(numpy.uint8), "RGB")
    return image.filter(ImageFilter.GaussianBlur(radius=width * 0.03))


def write_background(size=(430, 460)):
    wallpaper(size).save(os.path.join(OUT, "bg.png"))


def write_rows_preview(rows, name, size=(168, 246)):
    """Stage mock used by the Double / Tripple picker on the pinned apps page."""
    width, height = size
    scale = 3
    canvas = wallpaper((width * scale, height * scale)).convert("RGBA")
    draw = ImageDraw.Draw(canvas, "RGBA")

    card_inset = 14 * scale
    card_top = int(height * scale * 0.34)
    card = (card_inset, card_top, width * scale - card_inset, height * scale - card_inset)
    radius = 18 * scale

    plate = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(plate).rounded_rectangle(card, radius=radius, fill=(255, 255, 255, 92))
    canvas = Image.alpha_composite(canvas, plate)
    draw = ImageDraw.Draw(canvas, "RGBA")

    inner = 10 * scale
    left = card[0] + inner
    right = card[2] - inner
    y = card[1] + inner
    pill_height = 13 * scale
    draw.rounded_rectangle((left, y, right, y + pill_height), radius=pill_height / 2.0, fill=(255, 255, 255, 120))

    y += pill_height + 7 * scale
    gap = 5 * scale
    column = (right - left - gap) / 2.0
    for row in range(rows):
        for column_index in range(2):
            x0 = left + column_index * (column + gap)
            shade = 150 - row * 26
            draw.rounded_rectangle(
                (x0, y, x0 + column, y + pill_height),
                radius=pill_height / 2.0,
                fill=(shade + 60, shade + 60, shade + 70, 150),
            )
        y += pill_height + gap

    canvas.convert("RGB").resize(size, Image.LANCZOS).save(os.path.join(OUT, name))


def main():
    os.makedirs(OUT, exist_ok=True)
    write_logo()
    write_icon(29, "icon.png")
    write_icon(58, "icon@2x.png")
    write_icon(87, "icon@3x.png")
    write_background()
    write_rows_preview(2, "double.png")
    write_rows_preview(3, "tripple.png")
    print("wrote", OUT)


if __name__ == "__main__":
    main()

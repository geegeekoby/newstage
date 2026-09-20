#!/usr/bin/env python3
"""Builds the Sileo/APT repository that ships alongside the tweak.

The repository is a flat one: a Release file, a package index and the .deb, all
served from the same directory. Everything under public/ and the package index
the serverless handler reads are produced here, so the hosted repo can always be
rebuilt from the .deb rather than hand edited.

    make package FINALPACKAGE=1
    python3 tools/make_repo.py

Absolute URLs (the package icon, its depiction, the featured banner) are filled
in per request by api/repo.js, which knows the host it is answering on, so the
same output works on any domain. Pass --url to bake them in instead and get a
static Packages file for hosting that cannot run the handler:

    python3 tools/make_repo.py --url https://example.com
"""

from __future__ import annotations

import argparse
import email.utils
import glob
import gzip
import hashlib
import json
import os
import shutil
import subprocess

import numpy
from PIL import Image, ImageFilter

from make_resources import arrow_path, render, superellipse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PUBLIC = os.path.join(ROOT, "public")
API = os.path.join(ROOT, "api")

# Fields lifted from the package's own control file, in the order a Packages
# stanza conventionally carries them.
CONTROL_FIELDS = [
    "Package",
    "Name",
    "Version",
    "Architecture",
    "Description",
    "Depends",
    "Conflicts",
    "Replaces",
    "Provides",
    "Section",
    "Tag",
    "Author",
    "Maintainer",
    "Installed-Size",
]


def newest_deb() -> str:
    debs = sorted(glob.glob(os.path.join(ROOT, "packages", "*.deb")), key=os.path.getmtime)
    if not debs:
        raise SystemExit("no .deb in packages/ - run `make package FINALPACKAGE=1` first")
    return debs[-1]


def control_fields(deb: str) -> dict:
    out = subprocess.run(
        ["dpkg-deb", "-f", deb] + CONTROL_FIELDS,
        check=True,
        capture_output=True,
        text=True,
    ).stdout

    fields = {}
    key = None
    for line in out.splitlines():
        if line.startswith((" ", "\t")) and key:
            fields[key] += "\n" + line
            continue
        if ": " not in line:
            continue
        key, value = line.split(": ", 1)
        fields[key] = value
    return fields


def write_repo_icon(size=512):
    """Repo tile Sileo shows in the sources list: the tweak's own mark."""
    inset_ratio = 0.115

    def calls(draw, side):
        draw.polygon(superellipse((0, 0, side, side), exponent=5.0), fill=(8, 8, 10, 255))
        inset = side * inset_ratio
        draw.polygon(
            superellipse((inset, inset, side - inset, side - inset), exponent=4.6),
            fill=(255, 255, 255, 255),
        )
        draw.polygon(arrow_path(side - inset * 2.0, offset=(inset, inset)), fill=(8, 8, 10, 255))

    icon = render(size, calls)
    icon.save(os.path.join(PUBLIC, "CydiaIcon.png"))
    icon.save(os.path.join(PUBLIC, "assets", "icon.png"))


def banner_field(size):
    """Wide colour field for the depiction header.

    The Settings banner's gradient is mixed for a portrait canvas; stretched this
    flat its blobs average out into one muddy tone, so the header gets its own
    mix with tighter blobs spread along the width.
    """
    width, height = size
    xs = numpy.linspace(0.0, 1.0, width)[None, :]
    ys = numpy.linspace(0.0, 1.0, height)[:, None]
    aspect = height / float(width)

    field = numpy.zeros((height, width, 3), dtype=numpy.float64)
    weight = numpy.full((height, width), 1e-6)

    blobs = [
        ((0.02, 0.10), 0.20, (244, 148, 36)),
        ((0.18, 0.92), 0.19, (206, 58, 46)),
        ((0.36, 0.06), 0.18, (150, 42, 116)),
        ((0.52, 0.86), 0.20, (74, 44, 152)),
        ((0.70, 0.12), 0.19, (30, 58, 156)),
        ((0.86, 0.88), 0.18, (196, 74, 128)),
        ((1.00, 0.24), 0.18, (234, 128, 118)),
    ]
    for (cx, cy), radius, colour in blobs:
        distance = numpy.sqrt((xs - cx) ** 2 + ((ys - cy) * aspect) ** 2)
        falloff = numpy.exp(-(distance / radius) ** 2)
        weight += falloff
        for channel in range(3):
            field[:, :, channel] += falloff * colour[channel]

    field /= weight[:, :, None]
    image = Image.fromarray(numpy.clip(field, 0, 255).astype(numpy.uint8), "RGB")
    return image.filter(ImageFilter.GaussianBlur(radius=width * 0.01))


def write_banner(size=(1024, 400)):
    """Depiction header: the tweak's mark over its own colour field."""
    width, height = size
    canvas = banner_field(size).convert("RGBA")

    # Darkened so the white mark reads against every part of the gradient.
    shade = Image.new("RGBA", canvas.size, (0, 0, 0, 58))
    canvas = Image.alpha_composite(canvas, shade)

    mark_side = int(height * 0.44)
    mark = render(
        mark_side,
        lambda draw, side: draw.polygon(superellipse((0, 0, side, side), exponent=4.6), fill=(255, 255, 255, 255)),
    )

    # The arrow is knocked out of the squircle rather than drawn over it, the same
    # way DSLogoView builds the mark at runtime.
    hole = render(mark_side, lambda draw, side: draw.polygon(arrow_path(side), fill=(255, 255, 255, 255)))
    alpha = Image.new("L", mark.size, 0)
    alpha.paste(mark.split()[3], mask=hole.split()[3].point(lambda v: 255 - v))
    mark.putalpha(alpha)

    canvas.alpha_composite(mark, ((width - mark_side) // 2, (height - mark_side) // 2))
    canvas.convert("RGB").save(os.path.join(PUBLIC, "assets", "banner.png"), quality=92)


def packages_stanza(fields: dict, deb_name: str, digests: dict, base_url: str | None) -> str:
    lines = []
    for key in CONTROL_FIELDS:
        if key in fields:
            lines.append(f"{key}: {fields[key]}")

    lines.append(f"Filename: debs/{deb_name}")
    lines.append(f"Size: {digests['size']}")
    lines.append(f"MD5sum: {digests['md5']}")
    lines.append(f"SHA1: {digests['sha1']}")
    lines.append(f"SHA256: {digests['sha256']}")

    if base_url:
        base = base_url.rstrip("/")
        lines.append(f"Icon: {base}/assets/icon.png")
        lines.append(f"Depiction: {base}/depiction.json")
        lines.append(f"SileoDepiction: {base}/depiction.json")

    return "\n".join(lines) + "\n"


def write_release(stanza: str):
    """Release for the static, fixed-URL form of the repo.

    A package manager that finds no hash for the index it just downloaded may
    ignore that index, and on the device that is indistinguishable from the repo
    having nothing new in it - so Release carries the digests of the exact
    Packages bytes written alongside it. The dynamic form has no file here at all:
    api/repo.js composes Release and the index together per request, because the
    index names its own host and only the deployment knows what that is.
    """
    index_bytes = stanza.encode()
    gzipped = gzip.compress(index_bytes, mtime=0)

    def entries(algorithm):
        return "\n".join(
            f" {algorithm(payload).hexdigest()} {len(payload)} {name}"
            for payload, name in ((index_bytes, "Packages"), (gzipped, "Packages.gz"))
        )

    release = "\n".join(
        [
            "Origin: Dynamic Stage",
            "Label: Dynamic Stage",
            "Suite: stable",
            "Version: 1.0",
            "Codename: ios",
            "Architectures: iphoneos-arm64",
            "Components: main",
            "Description: Stage Manager Reimagined for iPhone, rebuilt for rootless jailbreaks",
            "Date: " + email.utils.formatdate(usegmt=True),
            "MD5Sum:",
            entries(hashlib.md5),
            "SHA256:",
            entries(hashlib.sha256),
        ]
    ) + "\n"
    with open(os.path.join(PUBLIC, "Release"), "w") as handle:
        handle.write(release)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--deb", help="package to publish (defaults to the newest in packages/)")
    parser.add_argument("--url", help="bake absolute URLs in and emit a static Packages file")
    args = parser.parse_args()

    deb = args.deb or newest_deb()
    os.makedirs(os.path.join(PUBLIC, "debs"), exist_ok=True)
    os.makedirs(os.path.join(PUBLIC, "assets"), exist_ok=True)
    os.makedirs(API, exist_ok=True)

    # Only ever one build in the repo: Sileo offers the newest anyway, and a
    # directory of stale debs is just weight in git.
    for stale in glob.glob(os.path.join(PUBLIC, "debs", "*.deb")):
        os.remove(stale)

    deb_name = os.path.basename(deb)
    shutil.copy2(deb, os.path.join(PUBLIC, "debs", deb_name))

    payload = open(deb, "rb").read()
    digests = {
        "size": len(payload),
        "md5": hashlib.md5(payload).hexdigest(),
        "sha1": hashlib.sha1(payload).hexdigest(),
        "sha256": hashlib.sha256(payload).hexdigest(),
    }

    fields = control_fields(deb)
    write_repo_icon()
    write_banner()

    # What the handler needs to compose a stanza with the host filled in.
    index = {
        "stanza": packages_stanza(fields, deb_name, digests, None),
        "package": fields.get("Package", ""),
        "name": fields.get("Name", ""),
        "version": fields.get("Version", ""),
        "description": fields.get("Description", ""),
        "author": fields.get("Author", ""),
        "size": digests["size"],
        "deb": deb_name,
    }
    with open(os.path.join(API, "package-index.json"), "w") as handle:
        json.dump(index, handle, indent=2)
        handle.write("\n")

    if args.url:
        stanza = packages_stanza(fields, deb_name, digests, args.url)
        with open(os.path.join(PUBLIC, "Packages"), "w") as handle:
            handle.write(stanza)
        with gzip.open(os.path.join(PUBLIC, "Packages.gz"), "wb", mtime=0) as handle:
            handle.write(stanza.encode())
        write_release(stanza)
        print("wrote static Packages for", args.url)
    else:
        # Left to api/repo.js. A file here would win over the rewrite that routes
        # these to the handler, and a Release whose hashes do not match the index
        # the handler serves is worse than no Release file.
        for name in ("Packages", "Packages.gz", "Release"):
            stale = os.path.join(PUBLIC, name)
            if os.path.exists(stale):
                os.remove(stale)

    print(f"repository ready in {PUBLIC} ({deb_name}, {digests['size']} bytes)")


if __name__ == "__main__":
    main()

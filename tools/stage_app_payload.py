#!/usr/bin/env python3
"""Copies the in-app dylib into Application Support as an install fallback.

On this device ElleKit has repeatedly been left without DynamicStageApp.dylib
under DynamicLibraries / TweakInject even though the .deb contains it. SpringBoard
restores the files from this payload on boot when they are missing.
"""

from __future__ import annotations

import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Theos stages rootless packages under Library/… and remaps to var/jb/Library
# when the .deb is assembled. Prefer whichever layout is present.
LIB_CANDIDATES = (
    "Library/MobileSubstrate/DynamicLibraries",
    "var/jb/Library/MobileSubstrate/DynamicLibraries",
)
SUPPORT_CANDIDATES = (
    "Library/Application Support/DynamicStage",
    "var/jb/Library/Application Support/DynamicStage",
)


def first_existing(staging: str, relatives: tuple[str, ...], filename: str) -> str | None:
    for relative in relatives:
        path = os.path.join(staging, relative, filename)
        if os.path.isfile(path):
            return path
    return None


def support_dir(staging: str) -> str:
    for relative in SUPPORT_CANDIDATES:
        parent = os.path.join(staging, os.path.dirname(relative))
        if os.path.isdir(parent) or relative.startswith("Library/"):
            path = os.path.join(staging, relative)
            os.makedirs(path, exist_ok=True)
            return path
    path = os.path.join(staging, SUPPORT_CANDIDATES[0])
    os.makedirs(path, exist_ok=True)
    return path


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: stage_app_payload.py <staging-dir>")
    staging = sys.argv[1]
    src_dylib = first_existing(staging, LIB_CANDIDATES, "DynamicStageApp.dylib")
    if not src_dylib:
        raise SystemExit(
            "missing staged app dylib under "
            + " or ".join(LIB_CANDIDATES)
        )

    payload_dir = support_dir(staging)
    dst_dylib = os.path.join(payload_dir, "DynamicStageApp.dylib")
    dst_plist = os.path.join(payload_dir, "DynamicStageApp.plist")
    shutil.copy2(src_dylib, dst_dylib)
    with open(dst_plist, "w", encoding="utf-8") as handle:
        handle.write(
            "{\n"
            "    Filter = {\n"
            '        Bundles = ( "com.facebook.Messenger" );\n'
            "    };\n"
            "}\n"
        )
    # Same OpenStep filter SpringBoard's own plist uses. ElleKit loads that one.
    libs_plist = os.path.join(os.path.dirname(src_dylib), "DynamicStageApp.plist")
    shutil.copy2(dst_plist, libs_plist)
    print(f"stage_app_payload: wrote {dst_dylib} and OpenStep plists")


if __name__ == "__main__":
    main()

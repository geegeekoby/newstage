#!/usr/bin/env python3
"""Converts staged arm64e binaries to the iOS 14 ptrauth ABI.

Theos' Linux toolchain can compile arm64e, but it emits the pre-iOS-14 ("old")
ptrauth ABI, and the linker changes needed for the new one were never open
sourced. iOS 14.5 and later dropped support for the old ABI, so an arm64e slice
built here is refused by dyld: the tweak never injects into SpringBoard and
Settings cannot load the preference bundle. Dropping arm64e is not an option
either, because PreferenceLoader will not load an arm64 bundle on an arm64e
device and the system processes this tweak hooks are all arm64e.

The fix is a post-link patch, in two parts:

  * `allemande` (p0358's C++ port of evelyn's `allemand`) rewrites the pointer
    signing the two ABIs disagree on - Objective-C class isa and superclass
    pointers and CFString ISAs - which is what would otherwise crash the objc
    runtime on load;
  * the slice is then marked as using the versioned ptrauth ABI
    (CPU_SUBTYPE_PTRAUTH_ABI in its cpusubtype, 0x2 -> 0x80000002), which is the
    bit dyld looks at to decide whether to accept it at all. The linker in this
    toolchain never sets it, and allemande deliberately leaves the header alone
    so it can run on binaries from linkers that do.

This runs from the root Makefile's after-stage hook, over the staged tree, before
the .deb is built:

    python3 tools/newabi.py .theos/_

Signing comes last, since both steps invalidate the signature Theos applied while
staging. Point ALLEMANDE at an existing build to skip fetching one.
"""

from __future__ import annotations

import os
import shutil
import struct
import subprocess
import sys

ALLEMANDE_REPO = "https://github.com/p0358/allemande.git"
ALLEMANDE_COMMIT = "43b2ca59ad3f6a55735b1f7b5cba8c34b55bd8f9"

FAT_MAGIC = (0xCAFEBABE, 0xBEBAFECA)
MACHO_MAGIC = (0xFEEDFACF, 0xCFFAEDFE, 0xFEEDFACE, 0xCEFAEDFE)

CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2
# The top byte of a subtype carries feature flags rather than the subtype itself.
CPU_SUBTYPE_FEATURE_MASK = 0xFF000000
# Set once a slice uses the versioned (iOS 14 and later) ptrauth ABI.
CPU_SUBTYPE_PTRAUTH_ABI = 0x80000000


def arm64e_slices(path: str) -> list[dict]:
    """Every arm64e slice in the file, described by where its subtype is written.

    The subtype appears twice in a fat file - once in the table of contents and
    once in the slice's own header - and the loader reads the slice header, so
    both offsets are reported and both get patched.
    """
    with open(path, "rb") as handle:
        head = handle.read(8)
        if len(head) < 8:
            return []

        magic = struct.unpack(">I", head[:4])[0]
        entries = []

        if magic in FAT_MAGIC:
            count = struct.unpack(">I", head[4:8])[0]
            if count > 32:
                return []
            for index in range(count):
                entry_offset = 8 + index * 20
                handle.seek(entry_offset)
                arch = handle.read(20)
                if len(arch) < 20:
                    break
                _, _, offset, _, _ = struct.unpack(">iiIII", arch)
                entries.append((entry_offset, offset))
        elif magic in MACHO_MAGIC:
            entries.append((None, 0))
        else:
            return []

        found = []
        for entry_offset, header_offset in entries:
            handle.seek(header_offset)
            header = handle.read(12)
            if len(header) < 12:
                continue
            slice_magic, cputype, cpusubtype = struct.unpack("<III", header)
            if slice_magic not in MACHO_MAGIC:
                continue
            if cputype != CPU_TYPE_ARM64:
                continue
            if cpusubtype & ~CPU_SUBTYPE_FEATURE_MASK != CPU_SUBTYPE_ARM64E:
                continue
            found.append(
                {
                    "entry_offset": entry_offset,
                    "header_offset": header_offset,
                    "cpusubtype": cpusubtype,
                }
            )
        return found


def arm64e_state(path: str) -> str | None:
    """"old", "new", or None when the file has no arm64e slice."""
    states = {
        "new" if entry["cpusubtype"] & CPU_SUBTYPE_PTRAUTH_ABI else "old"
        for entry in arm64e_slices(path)
    }
    if not states:
        return None
    return "old" if "old" in states else "new"


def mark_versioned(path: str):
    """Flags the arm64e slices as using the versioned ptrauth ABI."""
    with open(path, "r+b") as handle:
        for entry in arm64e_slices(path):
            if entry["cpusubtype"] & CPU_SUBTYPE_PTRAUTH_ABI:
                continue
            versioned = entry["cpusubtype"] | CPU_SUBTYPE_PTRAUTH_ABI

            handle.seek(entry["header_offset"] + 8)
            handle.write(struct.pack("<I", versioned))

            if entry["entry_offset"] is not None:
                handle.seek(entry["entry_offset"] + 4)
                handle.write(struct.pack(">I", versioned))


def find_allemande() -> str:
    """The converter, building it from a pinned commit the first time."""
    override = os.environ.get("ALLEMANDE")
    if override:
        if not os.path.exists(override):
            raise SystemExit(f"ALLEMANDE is set to {override}, which does not exist")
        return override

    on_path = shutil.which("allemande")
    if on_path:
        return on_path

    theos = os.environ.get("THEOS", os.path.expanduser("~/theos"))
    cache = os.path.join(os.environ.get("THEOS_BUILD_DIR", "."), ".theos", "allemande")
    binary = os.path.join(cache, "allemande")
    if os.path.exists(binary):
        return binary

    source = os.path.join(cache, "src")
    print("newabi: building allemande (arm64e ABI converter)", flush=True)
    os.makedirs(cache, exist_ok=True)
    if not os.path.exists(os.path.join(source, "main.cpp")):
        subprocess.run(["git", "init", "-q", source], check=True)
        subprocess.run(["git", "-C", source, "fetch", "-q", "--depth", "1", ALLEMANDE_REPO, ALLEMANDE_COMMIT], check=True)
        subprocess.run(["git", "-C", source, "checkout", "-q", "FETCH_HEAD"], check=True)

    # The host compiler, not the iOS toolchain that is on PATH during a build.
    compiler = shutil.which("g++", path="/usr/bin:/bin") or shutil.which("clang++", path="/usr/bin:/bin")
    if not compiler:
        raise SystemExit(
            "newabi: need g++ (or clang++) to build allemande, or set ALLEMANDE to a prebuilt one\n"
            f"        source is in {source}; see {ALLEMANDE_REPO}"
        )

    subprocess.run(
        [compiler, "-std=c++20", "-O2", "-o", binary, os.path.join(source, "main.cpp")],
        check=True,
        env={"PATH": "/usr/bin:/bin", "HOME": os.environ.get("HOME", "/tmp")},
    )
    if theos and not os.path.exists(binary):
        raise SystemExit("newabi: allemande did not build")
    return binary


def codesign(path: str):
    """Re-sign after patching; the tool's own README prescribes both passes."""
    ldid = os.environ.get("TARGET_CODESIGN") or shutil.which("ldid")
    if not ldid:
        theos = os.environ.get("THEOS", os.path.expanduser("~/theos"))
        candidate = os.path.join(theos, "toolchain", "linux", "iphone", "bin", "ldid")
        ldid = candidate if os.path.exists(candidate) else None
    if not ldid:
        raise SystemExit("newabi: cannot find ldid to re-sign the patched binary")

    for flag in ("-s", "-S"):
        subprocess.run([ldid, flag, path], check=True)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: newabi.py <staging directory>")

    root = sys.argv[1]
    if not os.path.isdir(root):
        raise SystemExit(f"newabi: {root} is not a directory")

    targets = []
    for directory, _, names in os.walk(root):
        for name in names:
            path = os.path.join(directory, name)
            if os.path.islink(path):
                continue
            try:
                state = arm64e_state(path)
            except OSError:
                continue
            if state == "old":
                targets.append(path)

    if not targets:
        return

    allemande = find_allemande()
    for path in targets:
        subprocess.run([allemande, path], check=True, stdout=subprocess.DEVNULL)
        mark_versioned(path)
        codesign(path)

        if arm64e_state(path) != "new":
            raise SystemExit(f"newabi: {path} is still on the old arm64e ABI after conversion")
        print(f"newabi: {os.path.relpath(path, root)} -> new arm64e ABI", flush=True)


if __name__ == "__main__":
    main()

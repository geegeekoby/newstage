#!/usr/bin/env python3
"""Check that a built .deb contains binaries this device will actually load.

The tweak failing to load is quiet: dyld refuses the image, the hooks never
install, Settings says it cannot load the preference bundle, and nothing in the
build output looks wrong. Every property that has to hold for the package to load
on an A12 or newer device running iOS 14.5+ is therefore asserted here, over the
finished .deb rather than over the staging directory.

Run by the root Makefile after packaging; also usable on any .deb by hand:

    python3 tools/verify_package.py packages/com.recreated.dynamicstage_1.2.2_iphoneos-arm64.deb
"""

import os
import shutil
import struct
import subprocess
import sys
import tempfile

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
MACHO_MAGIC_64 = 0xFEEDFACF

CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64_ALL = 0
CPU_SUBTYPE_ARM64E = 2
CPU_SUBTYPE_PTRAUTH_ABI = 0x80000000

LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D

# The high 32 bits allemande writes into each signed pointer: bit 63 marks the
# pointer as authenticated, and the discriminator identifies what it points at.
AUTH_BIT = 1 << 63
DISCRIMINATOR_ISA = 0x0D6AE1
DISCRIMINATOR_SUPERCLASS = 0x0DB5AB
DISCRIMINATOR_METHODLIST = 0x05C310
DISCRIMINATOR_CFSTRING = 0x156AE1


class Failure(Exception):
    pass


def slices(data):
    """Every (cputype, cpusubtype, offset) in a fat or thin Mach-O."""
    magic = struct.unpack(">I", data[:4])[0]
    if magic not in (FAT_MAGIC, FAT_MAGIC_64):
        cputype, cpusubtype = struct.unpack("<ii", data[4:12])
        return [(cputype, cpusubtype & 0xFFFFFFFF, 0, None)]

    wide = magic == FAT_MAGIC_64
    count = struct.unpack(">I", data[4:8])[0]
    entry_size = 32 if wide else 20
    out = []
    for index in range(count):
        entry = data[8 + index * entry_size : 8 + (index + 1) * entry_size]
        cputype, cpusubtype = struct.unpack(">ii", entry[:8])
        offset = struct.unpack(">Q" if wide else ">I", entry[8:16] if wide else entry[8:12])[0]
        out.append((cputype, cpusubtype & 0xFFFFFFFF, offset, 8 + index * entry_size))
    return out


def sections_and_commands(data, base):
    """Section table plus the set of load command types in one slice."""
    if struct.unpack("<I", data[base : base + 4])[0] != MACHO_MAGIC_64:
        raise Failure("not a 64-bit Mach-O")

    count = struct.unpack("<I", data[base + 16 : base + 20])[0]
    offset = base + 32
    sections = {}
    commands = set()
    for _ in range(count):
        command, size = struct.unpack("<II", data[offset : offset + 8])
        commands.add(command)
        if command == LC_SEGMENT_64:
            nsects = struct.unpack("<I", data[offset + 64 : offset + 68])[0]
            cursor = offset + 72
            for _ in range(nsects):
                name = data[cursor : cursor + 16].rstrip(b"\0").decode()
                segment = data[cursor + 16 : cursor + 32].rstrip(b"\0").decode()
                addr, sect_size, fileoff = struct.unpack("<QQI", data[cursor + 32 : cursor + 52])
                sections[f"{segment},{name}"] = (addr, sect_size, fileoff)
                cursor += 80
        offset += size
    return sections, commands


def signed_pointers(data, base, section, stride, field_offsets):
    """Count how many of the given fields in a section carry an auth signature."""
    if section not in data[1]:
        return []
    _, size, fileoff = data[1][section]
    blob = data[0]
    results = []
    for index in range(size // stride):
        record = base + fileoff + index * stride
        for offset, discriminator in field_offsets:
            value = struct.unpack("<Q", blob[record + offset : record + offset + 8])[0]
            if value == 0:
                continue
            ok = bool(value & AUTH_BIT) and ((value >> 32) & 0xFFFFFF) == discriminator
            results.append(ok)
    return results


def check_macho(path, name, problems):
    with open(path, "rb") as handle:
        data = handle.read()

    found = slices(data)
    architectures = {
        (cputype, subtype & ~CPU_SUBTYPE_PTRAUTH_ABI) for cputype, subtype, _, _ in found
    }
    if (CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL) not in architectures:
        problems.append(f"{name}: no arm64 slice, App Store apps could not load it")
    if (CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E) not in architectures:
        problems.append(
            f"{name}: no arm64e slice, so SpringBoard and Settings on an A12 or "
            "newer device could not load it"
        )
        return

    for cputype, subtype, offset, fat_entry in found:
        if cputype != CPU_TYPE_ARM64:
            continue
        sections, commands = sections_and_commands(data, offset)
        label = "arm64e" if subtype & ~CPU_SUBTYPE_PTRAUTH_ABI == CPU_SUBTYPE_ARM64E else "arm64"

        if LC_CODE_SIGNATURE not in commands:
            problems.append(f"{name} ({label}): unsigned, dyld would reject it")

        if label != "arm64e":
            continue

        if not subtype & CPU_SUBTYPE_PTRAUTH_ABI:
            problems.append(
                f"{name} ({label}): fat header still says the old ptrauth ABI, "
                "which iOS 14.5 and later refuse to load"
            )
        header_subtype = struct.unpack("<I", data[offset + 8 : offset + 12])[0]
        if not header_subtype & CPU_SUBTYPE_PTRAUTH_ABI:
            problems.append(f"{name} ({label}): Mach-O header still says the old ptrauth ABI")

        context = (data, sections)
        classes = signed_pointers(
            context,
            offset,
            "__DATA,__objc_data",
            40,
            [(0, DISCRIMINATOR_ISA), (8, DISCRIMINATOR_SUPERCLASS)],
        )
        strings = signed_pointers(
            context,
            offset,
            "__DATA_CONST,__cfstring" if "__DATA_CONST,__cfstring" in sections else "__DATA,__cfstring",
            32,
            [(0, DISCRIMINATOR_CFSTRING)],
        )

        for description, results in (("class", classes), ("CFString", strings)):
            if not results:
                continue
            bad = results.count(False)
            if bad:
                problems.append(
                    f"{name} ({label}): {bad} of {len(results)} {description} pointers "
                    "are not signed for the new ABI"
                )


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    package = sys.argv[1]
    if not os.path.exists(package):
        print(f"verify: no such package {package}", file=sys.stderr)
        return 1

    root = tempfile.mkdtemp(prefix="dsverify-")
    try:
        subprocess.run(["dpkg-deb", "-x", package, root], check=True)

        problems = []
        binaries = 0
        for directory, _, files in os.walk(root):
            for filename in files:
                path = os.path.join(directory, filename)
                if os.path.islink(path) or os.path.getsize(path) < 4:
                    continue
                with open(path, "rb") as handle:
                    magic = struct.unpack(">I", handle.read(4))[0]
                if magic not in (FAT_MAGIC, FAT_MAGIC_64) and magic != 0xCFFAEDFE:
                    continue
                binaries += 1
                check_macho(path, os.path.relpath(path, root), problems)

        if not binaries:
            problems.append("no Mach-O binaries in the package at all")

        for problem in problems:
            print(f"verify: {problem}", file=sys.stderr)
        if problems:
            return 1

        print(f"verify: {binaries} binaries, arm64 + new-ABI arm64e, signed")
        return 0
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())

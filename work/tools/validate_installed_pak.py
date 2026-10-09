#!/usr/bin/env python3
"""Byte-compare a pak's ssl_cache entries against build output and re-check
every module's header size invariant (the 3.0 crash class).

--configs must name exactly the entries the installed package patches. The
slim package writes 'release' only, so validating it against all three would
compare the untouched debug/profile entries with modded build output and
report a spurious failure.
"""

from __future__ import annotations

import argparse
import struct
import sys
import zipfile
from pathlib import Path

from proto_decode import parse_fields
from sslbundle_tool import parse_bundle

CONFIG_KEYS = ("debug", "profile", "release")


def count_bad_modules(data: bytes) -> tuple[int, int]:
    """Return (module count, modules violating the header size invariant)."""
    names, lengths, start = parse_bundle(data)
    bad = 0
    cursor = start
    for length in lengths:
        module = data[cursor : cursor + length]
        cursor += length
        declared = struct.unpack_from("<I", module, 12)[0]
        if module[:4] != b"SSLB" or declared != len(module) - 16:
            bad += 1
            continue
        try:
            parse_fields(module, 16, 16 + declared)  # loader-view parse
        except ValueError:
            bad += 1
    return len(names), bad


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("pak", type=Path, help="installed initial.pak")
    parser.add_argument("build_dir", type=Path, help="directory holding *.sslbundle.modified")
    parser.add_argument(
        "--configs",
        nargs="+",
        choices=CONFIG_KEYS,
        default=["release"],
        help="entries the installed package patches (default: release, i.e. the slim build)",
    )
    args = parser.parse_args()

    ok = True
    with zipfile.ZipFile(args.pak) as zf:
        for key in args.configs:
            data = zf.read(f"[ssl_cache]/initial_{key}.sslbundle")
            expected = (args.build_dir / f"initial_{key}.sslbundle.modified").read_bytes()
            same = data == expected
            modules, bad = count_bad_modules(data)
            print(f"  {key}: identical_to_build={same} modules={modules} bad={bad}")
            ok = ok and same and bad == 0
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

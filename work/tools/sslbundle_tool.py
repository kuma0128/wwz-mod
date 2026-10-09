#!/usr/bin/env python3
"""List, extract, and patch fixed-width bytes in Saber S3DB SSL bundles."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


def parse_bundle(data: bytes) -> tuple[list[str], list[int], int]:
    if data[:4] != b"S3DB":
        raise ValueError("not an S3DB SSL bundle")
    count = struct.unpack_from("<I", data, 11)[0]
    pos = 20
    names: list[str] = []
    for _ in range(count):
        length = struct.unpack_from("<I", data, pos)[0]
        pos += 4
        names.append(data[pos : pos + length].decode("utf-8"))
        pos += length
    if data[pos] != 1:
        raise ValueError(f"unexpected module-table marker: {data[pos]}")
    pos += 1
    lengths = list(struct.unpack_from(f"<{count}I", data, pos))
    modules_start = pos + count * 4
    if modules_start + sum(lengths) != len(data):
        raise ValueError("module lengths do not cover the bundle")
    return names, lengths, modules_start


def module_span(names: list[str], lengths: list[int], modules_start: int, name: str) -> tuple[int, int, int]:
    index = names.index(name)
    start = modules_start + sum(lengths[:index])
    return index, start, start + lengths[index]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--extract", action="append", default=[])
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--find", action="append", default=[])
    args = parser.parse_args()

    data = args.bundle.read_bytes()
    names, lengths, modules_start = parse_bundle(data)
    print(f"modules={len(names)} modules_start=0x{modules_start:X} size={len(data)}")

    for pattern in args.find:
        for index, name in enumerate(names):
            if pattern.lower() in name.lower():
                start = modules_start + sum(lengths[:index])
                print(f"index={index} start=0x{start:X} size={lengths[index]} name={name}")

    if args.extract:
        if args.output_dir is None:
            parser.error("--output-dir is required with --extract")
        args.output_dir.mkdir(parents=True, exist_ok=True)
        for name in args.extract:
            index, start, end = module_span(names, lengths, modules_start, name)
            target = args.output_dir / f"{index:04d}_{name.rsplit('.', 1)[-1]}.sslb"
            target.write_bytes(data[start:end])
            print(f"extracted index={index} start=0x{start:X} size={end-start} path={target}")


if __name__ == "__main__":
    main()

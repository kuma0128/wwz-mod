#!/usr/bin/env python3
"""Small offset-aware protobuf wire-format dumper for reverse-engineering assets."""

from __future__ import annotations

import argparse
import math
import struct
from pathlib import Path


def read_varint(data: bytes, pos: int, end: int) -> tuple[int, int]:
    value = 0
    shift = 0
    start = pos
    while pos < end and shift < 70:
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, pos
        shift += 7
    raise ValueError(f"bad varint at 0x{start:X}")


def printable(blob: bytes) -> str | None:
    if not blob:
        return ""
    try:
        text = blob.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if all(ch.isprintable() or ch in "\r\n\t" for ch in text):
        return text
    return None


def parse_fields(data: bytes, start: int, end: int) -> list[dict]:
    fields: list[dict] = []
    pos = start
    while pos < end:
        key_start = pos
        key, pos = read_varint(data, pos, end)
        number = key >> 3
        wire = key & 7
        if number == 0 or wire in (3, 4, 6, 7):
            raise ValueError(f"invalid key at 0x{key_start:X}")
        item = {"offset": key_start, "number": number, "wire": wire}
        if wire == 0:
            item["value"], pos = read_varint(data, pos, end)
        elif wire == 1:
            if pos + 8 > end:
                raise ValueError("truncated fixed64")
            item["raw"] = data[pos : pos + 8]
            pos += 8
        elif wire == 2:
            length, pos = read_varint(data, pos, end)
            if pos + length > end:
                raise ValueError("truncated length-delimited field")
            item["data_start"] = pos
            item["raw"] = data[pos : pos + length]
            pos += length
        elif wire == 5:
            if pos + 4 > end:
                raise ValueError("truncated fixed32")
            item["raw"] = data[pos : pos + 4]
            pos += 4
        fields.append(item)
    return fields


def try_nested(blob: bytes) -> list[dict] | None:
    if not blob:
        return None
    try:
        return parse_fields(blob, 0, len(blob))
    except (ValueError, IndexError):
        return None


def dump(data: bytes, start: int, end: int, depth: int, max_depth: int) -> None:
    for field in parse_fields(data, start, end):
        indent = "  " * depth
        head = f"{indent}0x{field['offset']:X} field {field['number']} wire {field['wire']}"
        wire = field["wire"]
        if wire == 0:
            print(f"{head}: {field['value']} (0x{field['value']:X})")
        elif wire == 1:
            value = struct.unpack("<Q", field["raw"])[0]
            number = struct.unpack("<d", field["raw"])[0]
            print(f"{head}: 0x{value:016X} double={number!r}")
        elif wire == 5:
            value = struct.unpack("<I", field["raw"])[0]
            number = struct.unpack("<f", field["raw"])[0]
            print(f"{head}: 0x{value:08X} float={number!r}")
        else:
            blob = field["raw"]
            text = printable(blob)
            nested = try_nested(blob) if depth < max_depth else None
            if text is not None and (len(text) < 300 or not nested):
                print(f"{head}: len={len(blob)} text={text!r}")
            elif nested:
                print(f"{head}: len={len(blob)} message @0x{field['data_start']:X}")
                dump(data, field["data_start"], field["data_start"] + len(blob), depth + 1, max_depth)
            else:
                preview = blob[:48].hex(" ")
                suffix = " ..." if len(blob) > 48 else ""
                print(f"{head}: len={len(blob)} bytes={preview}{suffix}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--skip", type=lambda value: int(value, 0), default=0)
    parser.add_argument("--length", type=lambda value: int(value, 0))
    parser.add_argument("--max-depth", type=int, default=5)
    args = parser.parse_args()
    data = args.path.read_bytes()
    start = args.skip
    end = len(data) if args.length is None else start + args.length
    dump(data, start, end, 0, args.max_depth)


if __name__ == "__main__":
    main()

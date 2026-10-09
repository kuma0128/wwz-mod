#!/usr/bin/env python3
"""Build the WWZ reward payloads from the pristine SSL bundles.

Every size-changed module gets its SSLB header body-size (u32 @ offset 12)
rewritten. Skipping that step is what made 3.0 crash at reward confirmation:
the appended firearm constant pushed the module tail past the declared body
size, truncating the trailing __initializer method.

Verification simulates the loader's view: each patched module must re-parse
to its exact declared end, and every module in the rebuilt bundle must keep
the "declared body size == actual body size" invariant that all 4057
original modules satisfy.

Two patch profiles are supported:

* full: preserves the 4.1 offline-oriented behaviour, including the
  size-changing firearm reward rewrites
* friends: keeps every module length unchanged to maximise compatibility in
  private / friends-only online sessions

--multiplier is required on purpose. The shipped 4.1 build is x90, and a
default here would silently produce payloads whose SHA-256 no longer matches
the hashes baked into the installer script.
"""

from __future__ import annotations

import argparse
import binascii
import hashlib
import struct
import zlib
from pathlib import Path

from proto_decode import parse_fields, read_varint
from sslbundle_tool import parse_bundle


WORK = Path(__file__).resolve().parent.parent
SOURCE = WORK / "source"
DEFAULT_OUTPUT = WORK / "payloads"

ONE = struct.pack("<f", 1.0)
FIVE = struct.pack("<f", 5.0)

PVE_BASE = "game_mode.modes.game_mode_pve_base_client"
PVE_REWARD = "main.user.progression.pve.pve_match_reward_creator"
FIREARM = "main.user.progression.weapons.firearm_match_reward_creator"
FIREARM_REVAMP = "main.user.progression.weapons.firearm_match_reward_creator_revamp"

# The slim package ships "release" only; debug/profile exist for the full
# package and to cross-check that the patch generalises across configs.
# All three here are pristine originals -- the x10-era patched copy that used
# to sit beside them is quarantined under source/_quarantine/.
CONFIGS = {
    "debug": SOURCE / "initial_debug.sslbundle",
    "profile": SOURCE / "initial_profile.sslbundle",
    "release": SOURCE / "initial_release.sslbundle",
}

LOAD_PARAM2 = 0x80000207  # push parameter #2 (explicit reward scale)
LOAD_PARAM3 = 0x80000307  # push parameter #3 (firearm rewardScale)
LOAD_LOCAL0 = 0x80000006  # push f4 record #0
PROFILES = ("full", "friends")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def raw_deflate(data: bytes) -> bytes:
    compressor = zlib.compressobj(level=9, wbits=-15)
    return compressor.compress(data) + compressor.flush()


def raw_inflate(data: bytes) -> bytes:
    return zlib.decompress(data, wbits=-15)


def encode_varint(value: int) -> bytes:
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def child_fields(data: bytes, field: dict) -> list[dict]:
    start = field["data_start"]
    return parse_fields(data, start, start + len(field["raw"]))


def nested_varint(data: bytes, field: dict, number: int) -> int | None:
    return next(
        (
            child["value"]
            for child in child_fields(data, field)
            if child["number"] == number and child["wire"] == 0
        ),
        None,
    )


def module_strings(module: bytes) -> list[str]:
    return [
        field["raw"].decode("utf-8", "replace")
        for field in parse_fields(module, 16, len(module))
        if field["number"] == 6 and field["wire"] == 2
    ]


def method_field(module: bytes, method_name: str) -> dict:
    strings = module_strings(module)
    matches: list[dict] = []
    for record in parse_fields(module, 16, len(module)):
        if record["number"] != 8 or record["wire"] != 2:
            continue
        sub = child_fields(module, record)
        name_ref = next(
            (item for item in sub if item["number"] == 2 and item["wire"] == 2),
            None,
        )
        name_index = nested_varint(module, name_ref, 1) if name_ref else None
        name = strings[name_index] if name_index is not None else None
        if name == method_name:
            matches.append(record)
    if len(matches) != 1:
        raise ValueError(f"expected one method {method_name}, found {len(matches)}")
    return matches[0]


def method_words(module: bytes, record: dict) -> list[int]:
    code = [
        item
        for item in child_fields(module, record)
        if item["number"] == 5 and item["wire"] == 2
    ]
    if len(code) != 1:
        raise ValueError("expected one instruction field")
    return [
        item["value"]
        for item in child_fields(module, code[0])
        if item["number"] == 1 and item["wire"] == 0
    ]


def method_locals(module: bytes, record: dict) -> list[list[dict]]:
    return [
        child_fields(module, item)
        for item in child_fields(module, record)
        if item["number"] == 4 and item["wire"] == 2
    ]


def walk_fixed32(data: bytes, fields: list[dict]) -> list[dict]:
    found: list[dict] = []
    for field in fields:
        if field["wire"] == 5:
            found.append(field)
        elif field["wire"] == 2 and field["raw"]:
            try:
                nested = child_fields(data, field)
            except ValueError:
                continue
            found.extend(walk_fixed32(data, nested))
    return found


def patch_unique_method_float(
    module: bytes, method_name: str, old: bytes, new: bytes, label: str
) -> bytes:
    record = method_field(module, method_name)
    fixed = [
        item
        for item in walk_fixed32(module, child_fields(module, record))
        if item["raw"] == old
    ]
    if len(fixed) != 1:
        raise ValueError(
            f"{method_name}: expected one {struct.unpack('<f', old)[0]} float, "
            f"found {len(fixed)}"
        )
    offset = fixed[0]["offset"] + 1  # fixed32 field key is one byte here
    out = bytearray(module)
    if out[offset : offset + 4] != old:
        raise ValueError(f"{method_name}: fixed32 data offset mismatch")
    out[offset : offset + 4] = new
    print(f"    float 0x{offset:X}: {label}")
    return bytes(out)


def patch_method_word(
    module: bytes, method_name: str, old_word: int, new_word: int, label: str
) -> bytes:
    record = method_field(module, method_name)
    sub = child_fields(module, record)
    code = [item for item in sub if item["number"] == 5 and item["wire"] == 2]
    if len(code) != 1:
        raise ValueError(f"{method_name}: expected one instruction field")
    words = [
        item
        for item in child_fields(module, code[0])
        if item["number"] == 1 and item["wire"] == 0 and item["value"] == old_word
    ]
    if len(words) != 1:
        raise ValueError(
            f"{method_name}: expected one instruction 0x{old_word:08X}, found {len(words)}"
        )
    field = words[0]
    _, value_start = read_varint(module, field["offset"], len(module))
    _, value_end = read_varint(module, value_start, len(module))
    encoded = encode_varint(new_word)
    if len(encoded) != value_end - value_start:
        raise ValueError(f"{method_name}: replacement varint changes width")
    out = bytearray(module)
    out[value_start:value_end] = encoded
    print(f"    word 0x{value_start:X}: {label}")
    return bytes(out)


def append_constant_and_force_reward_scale(
    module: bytes, method_name: str, multiplier: float
) -> bytes:
    """Append a float local and repoint the rewardScale load at it.

    The caller must fix the module header size afterwards (fix_module_header);
    forgetting that step is exactly the 3.0 crash.
    """
    packed = struct.pack("<f", multiplier)
    record = method_field(module, method_name)
    sub = child_fields(module, record)
    locals_fields = [item for item in sub if item["number"] == 4 and item["wire"] == 2]
    constant_index = len(locals_fields)
    new_word = LOAD_LOCAL0 | (constant_index << 8)

    raw = bytearray(record["raw"])
    code = [item for item in sub if item["number"] == 5 and item["wire"] == 2]
    if len(code) != 1:
        raise ValueError(f"{method_name}: expected one instruction field")
    candidates = [
        item
        for item in child_fields(module, code[0])
        if item["number"] == 1 and item["wire"] == 0 and item["value"] == LOAD_PARAM3
    ]
    if len(candidates) != 1:
        raise ValueError(
            f"{method_name}: expected one rewardScale load 0x{LOAD_PARAM3:08X}, "
            f"found {len(candidates)}"
        )
    word_field = candidates[0]
    _, value_start = read_varint(module, word_field["offset"], len(module))
    _, value_end = read_varint(module, value_start, len(module))
    rel_start = value_start - record["data_start"]
    rel_end = value_end - record["data_start"]
    replacement = encode_varint(new_word)
    if len(replacement) != rel_end - rel_start:
        raise ValueError(f"{method_name}: replacement varint changes width")
    raw[rel_start:rel_end] = replacement

    code_start = code[0]["offset"] - record["data_start"]
    constant_record = b"\x22\x07\x08\x03\x25" + packed
    raw[code_start:code_start] = constant_record

    outer = encode_varint((8 << 3) | 2) + encode_varint(len(raw)) + bytes(raw)
    start = record["offset"]
    end = record["data_start"] + len(record["raw"])
    out = module[:start] + outer + module[end:]
    if len(out) != len(module) + len(constant_record):
        raise ValueError(f"{method_name}: unexpected module size change")
    print(
        f"    insert 0x{record['data_start'] + code_start:X}: "
        f"local[{constant_index}]={multiplier} and force rewardScale"
    )
    return out


def fix_module_header(module: bytes) -> bytes:
    if module[:4] != b"SSLB":
        raise ValueError("module missing SSLB magic")
    declared = struct.unpack_from("<I", module, 12)[0]
    actual = len(module) - 16
    if declared == actual:
        return module
    out = bytearray(module)
    struct.pack_into("<I", out, 12, actual)
    print(f"    header body size: {declared} -> {actual}")
    return bytes(out)


def bundle_layout(data: bytes) -> tuple[list[str], list[int], int, int]:
    names, lengths, modules_start = parse_bundle(data)
    pos = 20
    for _ in names:
        length = struct.unpack_from("<I", data, pos)[0]
        pos += 4 + length
    if data[pos] != 1:
        raise ValueError("unexpected module-table marker")
    lengths_pos = pos + 1
    return names, lengths, lengths_pos, modules_start


def split_modules(data: bytes) -> tuple[list[str], list[bytes], int]:
    names, lengths, lengths_pos, modules_start = bundle_layout(data)
    modules: list[bytes] = []
    cursor = modules_start
    for length in lengths:
        modules.append(data[cursor : cursor + length])
        cursor += length
    return names, modules, lengths_pos


def patch_firearm_full(module: bytes, packed: bytes, multiplier: float) -> bytes:
    module = patch_unique_method_float(
        module,
        "GrantFirearmRewards",
        ONE,
        packed,
        f"signature fallback 1.0 -> {multiplier}",
    )
    return append_constant_and_force_reward_scale(
        module, "RewardByProgress", multiplier
    )


def patch_firearm_friends(module: bytes, packed: bytes, multiplier: float) -> bytes:
    # Keep the method body the same size for private / friends-only sessions.
    return patch_unique_method_float(
        module,
        "GrantFirearmRewards",
        ONE,
        packed,
        f"signature fallback 1.0 -> {multiplier}",
    )


def patch_config(
    config: str, original: bytes, multiplier: float, profile: str
) -> bytes:
    packed = struct.pack("<f", multiplier)
    names, modules, lengths_pos = split_modules(original)

    def update(name: str, patcher) -> None:
        index = names.index(name)
        print(f"  module[{index}] {name}")
        patched = patcher(modules[index])
        modules[index] = fix_module_header(patched)

    update(
        PVE_BASE,
        lambda m: patch_unique_method_float(
            m, "GetRewardsScale", ONE, packed, f"fallback normal scale 1.0 -> {multiplier}"
        ),
    )

    def patch_pve(module: bytes) -> bytes:
        module = patch_unique_method_float(
            module,
            "RewardByMatchProgressInternal",
            ONE,
            packed,
            f"internal fallback 1.0 -> {multiplier}",
        )
        module = patch_unique_method_float(
            module,
            "ScaleAndRoundGeneralReward",
            FIVE,
            packed,
            f"round unit / forced scale 5.0 -> {multiplier}",
        )
        module = patch_method_word(
            module,
            "ScaleAndRoundGeneralReward",
            LOAD_PARAM2,
            LOAD_LOCAL0,
            "load explicit scale -> load forced constant",
        )
        module = patch_unique_method_float(
            module,
            "ScaleAndRoundChallengeCurrency",
            ONE,
            packed,
            f"round unit / forced scale 1.0 -> {multiplier}",
        )
        module = patch_method_word(
            module,
            "ScaleAndRoundChallengeCurrency",
            LOAD_PARAM2,
            LOAD_LOCAL0,
            "load explicit scale -> load forced constant",
        )
        return module

    update(PVE_REWARD, patch_pve)

    if profile == "full":
        update(FIREARM, lambda m: patch_firearm_full(m, packed, multiplier))
        update(FIREARM_REVAMP, lambda m: patch_firearm_full(m, packed, multiplier))
        expected_delta = 18
    elif profile == "friends":
        update(FIREARM, lambda m: patch_firearm_friends(m, packed, multiplier))
        update(
            FIREARM_REVAMP,
            lambda m: patch_firearm_friends(m, packed, multiplier),
        )
        expected_delta = 0
    else:
        raise ValueError(f"unknown profile: {profile}")

    new_lengths = [len(module) for module in modules]
    header = original[:lengths_pos] + struct.pack(f"<{len(new_lengths)}I", *new_lengths)
    modified = header + b"".join(modules)
    if len(modified) != len(original) + expected_delta:
        raise ValueError(
            f"{config}/{profile}: expected {expected_delta:+d} bytes, "
            f"got {len(modified) - len(original):+d}"
        )
    return modified


def assert_words_diff(
    original: list[int], patched: list[int], expected: dict[int, int], where: str
) -> None:
    if len(original) != len(patched):
        raise ValueError(f"{where}: word count changed {len(original)} -> {len(patched)}")
    diffs = {
        index: (old, new)
        for index, (old, new) in enumerate(zip(original, patched))
        if old != new
    }
    wanted = dict(expected)
    for index, (old, new) in diffs.items():
        if wanted.get(old) != new:
            raise ValueError(f"{where}: unexpected word change [{index}] 0x{old:08X}->0x{new:08X}")
        del wanted[old]
    if wanted:
        raise ValueError(f"{where}: missing word changes {wanted}")


def local_float(module: bytes, locals_list: list[list[dict]], index: int) -> float:
    entry = locals_list[index]
    type_tag = next(k["value"] for k in entry if k["number"] == 1 and k["wire"] == 0)
    if type_tag != 3:
        raise ValueError(f"local[{index}] is not float-typed (tag={type_tag})")
    raw = next(k["raw"] for k in entry if k["number"] == 4 and k["wire"] == 5)
    return struct.unpack("<f", raw)[0]


def verify_config(
    config: str, original: bytes, modified: bytes, multiplier: float, profile: str
) -> None:
    names, orig_modules, _ = split_modules(original)
    mod_names, mod_modules, _ = split_modules(modified)
    if mod_names != names:
        raise ValueError(f"{config}: module name table changed")

    size_changes: dict[str, int] = {}
    for name, before, after in zip(names, orig_modules, mod_modules):
        if len(before) != len(after):
            size_changes[name] = len(after) - len(before)
        declared = struct.unpack_from("<I", after, 12)[0]
        if after[:4] != b"SSLB" or declared != len(after) - 16:
            raise ValueError(f"{config}: module header size invariant broken: {name}")
        if before[8:12] != after[8:12]:
            raise ValueError(f"{config}: module id hash changed: {name}")
    expected_size_changes = (
        {FIREARM: 9, FIREARM_REVAMP: 9} if profile == "full" else {}
    )
    if size_changes != expected_size_changes:
        raise ValueError(f"{config}: unexpected module size changes {size_changes}")

    by_name_orig = dict(zip(names, orig_modules))
    by_name_mod = dict(zip(names, mod_modules))

    # loader-view parse of every patched module: must consume to declared end
    for name in (PVE_BASE, PVE_REWARD, FIREARM, FIREARM_REVAMP):
        module = by_name_mod[name]
        declared = struct.unpack_from("<I", module, 12)[0]
        parse_fields(module, 16, 16 + declared)  # raises on truncation

    # pve: forced scale words + constants
    pve_orig = by_name_orig[PVE_REWARD]
    pve_mod = by_name_mod[PVE_REWARD]
    for method in ("ScaleAndRoundGeneralReward", "ScaleAndRoundChallengeCurrency"):
        rec_o = method_field(pve_orig, method)
        rec_m = method_field(pve_mod, method)
        assert_words_diff(
            method_words(pve_orig, rec_o),
            method_words(pve_mod, rec_m),
            {LOAD_PARAM2: LOAD_LOCAL0},
            f"{config}/{method}",
        )
        value = local_float(pve_mod, method_locals(pve_mod, rec_m), 0)
        if value != multiplier:
            raise ValueError(f"{config}/{method}: local[0] float is {value}")

    for name in (FIREARM, FIREARM_REVAMP):
        module_orig = by_name_orig[name]
        module_mod = by_name_mod[name]

        rec_o = method_field(module_orig, "GrantFirearmRewards")
        rec_m = method_field(module_mod, "GrantFirearmRewards")
        before = [
            item["raw"]
            for item in walk_fixed32(module_orig, child_fields(module_orig, rec_o))
            if item["raw"] == ONE
        ]
        after = [
            item["raw"]
            for item in walk_fixed32(module_mod, child_fields(module_mod, rec_m))
            if item["raw"] == struct.pack("<f", multiplier)
        ]
        if len(before) != 1 or len(after) != 1:
            raise ValueError(
                f"{config}/{name}/GrantFirearmRewards: unexpected firearm scale patch"
            )

        if profile == "full":
            rec_o = method_field(module_orig, "RewardByProgress")
            rec_m = method_field(module_mod, "RewardByProgress")
            locals_o = method_locals(module_orig, rec_o)
            locals_m = method_locals(module_mod, rec_m)
            if len(locals_m) != len(locals_o) + 1:
                raise ValueError(
                    f"{config}/{name}: locals count {len(locals_o)}->{len(locals_m)}"
                )
            index = len(locals_o)
            value = local_float(module_mod, locals_m, index)
            if value != multiplier:
                raise ValueError(f"{config}/{name}: appended local float is {value}")
            assert_words_diff(
                method_words(module_orig, rec_o),
                method_words(module_mod, rec_m),
                {LOAD_PARAM3: LOAD_LOCAL0 | (index << 8)},
                f"{config}/{name}/RewardByProgress",
            )
        else:
            rec_o = method_field(module_orig, "RewardByProgress")
            rec_m = method_field(module_mod, "RewardByProgress")
            if method_words(module_orig, rec_o) != method_words(module_mod, rec_m):
                raise ValueError(
                    f"{config}/{name}/RewardByProgress changed in friends profile"
                )


def build_config(
    config: str, source: Path, output: Path, multiplier: float, profile: str
) -> list[str]:
    print(f"{config}: {source}")
    original = source.read_bytes()
    modified = patch_config(config, original, multiplier, profile)
    verify_config(config, original, modified, multiplier, profile)
    compressed = raw_deflate(modified)
    if raw_inflate(compressed) != modified:
        raise ValueError(f"{config}: deflate roundtrip failed")
    (output / f"initial_{config}.sslbundle.modified").write_bytes(modified)
    (output / f"initial_{config}.sslbundle.deflate").write_bytes(compressed)
    return [
        f"{config}: original_size={len(original)} original_crc={crc32(original):08X} "
        f"original_sha={sha256(original)}",
        f"{config}: profile={profile} mod_size={len(modified)} mod_crc={crc32(modified):08X} "
        f"mod_sha={sha256(modified)} deflate_size={len(compressed)} "
        f"deflate_crc={crc32(compressed):08X} deflate_sha={sha256(compressed)}",
    ]


def main() -> None:
    parser = argparse.ArgumentParser(description="Build WWZ reward payloads.")
    parser.add_argument(
        "--multiplier",
        type=float,
        required=True,
        help="reward multiplier to bake in; the shipped 4.1 build uses 90",
    )
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--configs",
        nargs="+",
        choices=sorted(CONFIGS),
        default=sorted(CONFIGS),
        help="bundles to build; the slim package ships 'release' only",
    )
    parser.add_argument(
        "--profile",
        choices=PROFILES,
        default="full",
        help="full keeps the 4.1 firearm rewrites; friends keeps every module size unchanged",
    )
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    manifest: list[str] = [f"multiplier={args.multiplier}", f"profile={args.profile}"]
    for config in args.configs:
        lines = build_config(
            config, CONFIGS[config], args.output, args.multiplier, args.profile
        )
        for line in lines:
            print(line)
        manifest.extend(lines)
    (args.output / "manifest.txt").write_text("\n".join(manifest) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()

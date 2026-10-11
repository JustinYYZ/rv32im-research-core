#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

"""Convert an ELF32 little-endian RISC-V image into 32-bit readmemh words."""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path


ELF_HEADER = struct.Struct("<HHIIIIIHHHHHH")
PROGRAM_HEADER = struct.Struct("<IIIIIIII")
PT_LOAD = 1
EM_RISCV = 243
EF_RISCV_RVC = 0x1


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="input RV32 ELF file")
    parser.add_argument("output", type=Path, help="output 32-bit memory image")
    return parser.parse_args()


def load_elf(path: Path) -> tuple[int, dict[int, int], list[tuple[int, int]]]:
    data = path.read_bytes()
    if len(data) < 16 + ELF_HEADER.size or data[:4] != b"\x7fELF":
        raise ValueError(f"{path} is not an ELF file")
    if data[4] != 1:
        raise ValueError("only ELF32 images are supported")
    if data[5] != 1:
        raise ValueError("only little-endian ELF images are supported")

    fields = ELF_HEADER.unpack_from(data, 16)
    machine = fields[1]
    entry = fields[3]
    phoff = fields[4]
    flags = fields[6]
    phentsize = fields[8]
    phnum = fields[9]

    if machine != EM_RISCV:
        raise ValueError(f"expected a RISC-V ELF image, found machine {machine}")
    if flags & EF_RISCV_RVC:
        raise ValueError("the ELF image uses the unsupported RVC extension")
    if phentsize < PROGRAM_HEADER.size:
        raise ValueError("ELF program-header entries are too small")
    if phoff + phentsize * phnum > len(data):
        raise ValueError("ELF program-header table extends beyond the file")

    memory: dict[int, int] = {}
    ranges: list[tuple[int, int]] = []

    for index in range(phnum):
        offset = phoff + index * phentsize
        p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, _, _ = PROGRAM_HEADER.unpack_from(data, offset)
        if p_type != PT_LOAD or p_memsz == 0:
            continue
        if p_filesz > p_memsz:
            raise ValueError(f"load segment {index} has file size larger than memory size")
        if p_offset + p_filesz > len(data):
            raise ValueError(f"load segment {index} extends beyond the ELF file")

        address = p_paddr if p_paddr != 0 else p_vaddr
        end_address = address + p_memsz
        if end_address > 0x1_0000_0000:
            raise ValueError(f"load segment {index} exceeds the 32-bit address space")

        for byte_address in range(address, end_address):
            memory.setdefault(byte_address, 0)
        for byte_offset, value in enumerate(data[p_offset:p_offset + p_filesz]):
            byte_address = address + byte_offset
            previous = memory.get(byte_address)
            if previous not in (None, 0, value):
                raise ValueError(f"conflicting load segments at address 0x{byte_address:08x}")
            memory[byte_address] = value

        ranges.append((address, end_address))

    if not ranges:
        raise ValueError("ELF image contains no loadable segments")
    if entry & 0x3:
        raise ValueError(f"entry point 0x{entry:08x} is not 4-byte aligned")

    return entry, memory, ranges


def write_memh(path: Path, memory: dict[int, int]) -> int:
    word_addresses = sorted({address >> 2 for address in memory})
    path.parent.mkdir(parents=True, exist_ok=True)

    with path.open("w", encoding="ascii") as output:
        previous_word_address = None
        for word_address in word_addresses:
            if previous_word_address is None or word_address != previous_word_address + 1:
                output.write(f"@{word_address:08x}\n")

            byte_address = word_address << 2
            word = sum(memory.get(byte_address + lane, 0) << (8 * lane) for lane in range(4))
            output.write(f"{word:08x}\n")
            previous_word_address = word_address

    return len(word_addresses)


def main() -> None:
    args = parse_arguments()
    entry, memory, ranges = load_elf(args.input)
    word_count = write_memh(args.output, memory)

    print(f"ELF entry: 0x{entry:08x}")
    for start, end in ranges:
        print(f"LOAD:      0x{start:08x}-0x{end:08x}")
    print(f"Words:     {word_count}")
    print(f"Image:     {args.output}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"elf_to_memh: error: {error}", file=sys.stderr)
        raise SystemExit(1) from error

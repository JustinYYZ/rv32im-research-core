#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Streaming comparison of RV32IM RTL and Spike architectural effects."""

import argparse
import csv
import re
import sys
from collections import deque
from itertools import zip_longest


HALT_INSTRUCTIONS = {0x00000063, 0x0000006f, 0xf0002013}
SPIKE_COMMIT_RE = re.compile(r"^core\s+0:\s+3\s+0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)(?:\s+x(\d+)\s+0x([0-9a-fA-F]+))?(?:\s+mem\s+0x([0-9a-fA-F]+)(?:\s+0x([0-9a-fA-F]+))?)?$")
FIELDS = ("pc", "instr", "rd", "rd_wdata", "mem_valid", "mem_write", "mem_addr", "mem_width", "mem_wdata")


def parse_integer(value, base, bits, context):
    if value is None or not re.fullmatch(r"[0-9]+" if base == 10 else r"[0-9a-fA-F]+", value):
        raise ValueError(f"{context}: invalid integer {value!r}")
    result = int(value, base)
    if not 0 <= result < (1 << bits):
        raise ValueError(f"{context}: value does not fit {bits} bits")
    return result


def memory_width(instr):
    opcode = instr & 0x7f
    funct3 = (instr >> 12) & 7
    widths = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2} if opcode == 0x03 else {0: 1, 1: 2, 2: 4}
    if opcode not in (0x03, 0x23) or funct3 not in widths:
        raise ValueError(f"unsupported memory instruction 0x{instr:08x}")
    return widths[funct3]


def read_rtl_trace(path):
    required = {"order", "pc", "instr", "rd_write", "rd", "rd_wdata", "mem_valid", "mem_write", "mem_addr", "rmask", "wmask", "mem_rdata", "mem_wdata", "trap"}
    halted = False
    with open(path, newline="", encoding="utf-8") as trace_file:
        reader = csv.DictReader(trace_file)
        if reader.fieldnames is None or len(reader.fieldnames) != len(set(reader.fieldnames)) or not required.issubset(reader.fieldnames):
            raise ValueError(f"{path}: missing or duplicate required CSV columns")
        for order, row in enumerate(reader, 1):
            context = f"{path}: line {reader.line_num}, order {order}"
            if halted:
                raise ValueError(f"{context}: RTL commits after its first magic halt")
            if None in row or any(row[name] is None for name in required):
                raise ValueError(f"{context}: malformed CSV row")
            integer = lambda name, base=16, bits=32: parse_integer(row[name], base, bits, f"{context}: {name}")
            if integer("order", 10, 64) != order:
                raise ValueError(f"{context}: non-contiguous retirement order")
            if integer("trap", 10, 1):
                raise ValueError(f"{context}: unexpected RTL trap; privileged trap handling is outside this comparator")
            instr = integer("instr")
            rd = integer("rd", 10, 5)
            rd_write = bool(integer("rd_write", 10, 1)) and rd != 0
            valid = bool(integer("mem_valid", 10, 1))
            write = bool(integer("mem_write", 10, 1)) if valid else None
            address = width = data = None
            opcode = instr & 0x7f
            if valid != (opcode in (0x03, 0x23)):
                raise ValueError(f"{context}: memory-valid disagrees with instruction")
            if valid:
                if write != (opcode == 0x23):
                    raise ValueError(f"{context}: memory direction disagrees with instruction")
                width = memory_width(instr)
                mask = integer("wmask" if write else "rmask", bits=4)
                unused_mask = integer("rmask" if write else "wmask", bits=4)
                offset = (mask & -mask).bit_length() - 1
                if mask == 0 or unused_mask != 0 or mask != ((1 << width) - 1) << offset or offset + width > 4 or offset % width:
                    raise ValueError(f"{context}: invalid byte mask 0x{mask:x}")
                base = integer("mem_addr")
                if base & 3:
                    raise ValueError(f"{context}: RTL memory address is not word aligned")
                address = base + offset
                raw = integer("mem_wdata" if write else "mem_rdata")
                value = (raw >> (8 * offset)) & ((1 << (8 * width)) - 1)
                if write:
                    data = value
                elif rd_write:
                    if ((instr >> 12) & 7) in (0, 1) and value & (1 << (8 * width - 1)):
                        value |= 0xffffffff ^ ((1 << (8 * width)) - 1)
                    if integer("rd_wdata") != value:
                        raise ValueError(f"{context}: load writeback disagrees with masked read data")
            halted = instr in HALT_INSTRUCTIONS
            yield dict(order=order, pc=integer("pc"), instr=instr, rd=rd if rd_write else None, rd_wdata=integer("rd_wdata") if rd_write else None,
                       mem_valid=valid, mem_write=write, mem_addr=address, mem_width=width, mem_wdata=data)
    if not halted:
        raise ValueError(f"{path}: no magic halt at the end of RTL trace")


def read_spike_trace(path):
    order = 0
    with open(path, encoding="utf-8") as trace_file:
        for line_number, line in enumerate(trace_file, 1):
            line = line.strip()
            if not line:
                continue
            match = SPIKE_COMMIT_RE.fullmatch(line)
            if match is None:
                raise ValueError(f"{path}:{line_number}: unsupported Spike log record: {line[:180]}")
            order += 1
            pc, instr = int(match[1], 16), int(match[2], 16)
            if pc > 0xffffffff or instr > 0xffffffff:
                raise ValueError(f"{path}:{line_number}: non-RV32 record")
            rd = int(match[3]) if match[3] is not None else None
            if rd is not None and not 0 <= rd < 32:
                raise ValueError(f"{path}:{line_number}: invalid destination register")
            rd_write = rd is not None and rd != 0
            valid = match[5] is not None
            if valid != ((instr & 0x7f) in (0x03, 0x23)):
                raise ValueError(f"{path}:{line_number}: memory instruction has missing or unexpected access")
            write = (instr & 0x7f) == 0x23 if valid else None
            width = memory_width(instr) if valid else None
            if valid and ((match[6] is not None) != write):
                raise ValueError(f"{path}:{line_number}: unexpected or missing memory write data")
            yield dict(order=order, pc=pc, instr=instr, rd=rd if rd_write else None, rd_wdata=int(match[4], 16) if rd_write else None, mem_valid=valid,
                       mem_write=write, mem_addr=int(match[5], 16) if valid else None, mem_width=width,
                       mem_wdata=int(match[6], 16) & ((1 << (8 * width)) - 1) if write else None)
            # Spike does not know the testbench halt convention. Ignore execution after its first marker.
            if instr in HALT_INSTRUCTIONS:
                return
    raise ValueError(f"{path}: Spike did not reach a magic halt within its instruction budget")


def format_value(field, value):
    if value is None:
        return "-"
    if field == "rd":
        return f"x{value}"
    if field in ("mem_valid", "mem_write", "mem_width"):
        return str(value)
    return f"0x{value:08x}"


def compare_traces(rtl_trace, spike_trace):
    history = deque(maxlen=4)
    count = 0
    for rtl, spike in zip_longest(read_rtl_trace(rtl_trace), read_spike_trace(spike_trace)):
        if rtl is None or spike is None:
            raise ValueError(f"trace lengths differ after {count} matching commits")
        differences = [field for field in FIELDS if rtl[field] != spike[field]]
        if differences:
            for previous in history:
                print(f"previous: order={previous['order']} pc=0x{previous['pc']:08x} instr=0x{previous['instr']:08x}", file=sys.stderr)
            print(f"FAIL: order={rtl['order']} RTL PC=0x{rtl['pc']:08x} Spike PC=0x{spike['pc']:08x}", file=sys.stderr)
            for field in differences:
                print(f"{field}: RTL={format_value(field, rtl[field])}, Spike={format_value(field, spike[field])}", file=sys.stderr)
            return None
        count += 1
        history.append(rtl)
    if count == 0:
        raise ValueError("empty retirement traces")
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rtl_trace")
    parser.add_argument("spike_trace")
    args = parser.parse_args()
    try:
        count = compare_traces(args.rtl_trace, args.spike_trace)
    except (OSError, ValueError, csv.Error) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    if count is None:
        return 1
    print(f"PASS: {count} commits match in PC, instruction, register writeback, and memory effects; both reach the same first halt")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check that matching traces pass and damaged traces cannot silently pass."""

import contextlib
import csv
import io
from pathlib import Path
import tempfile
import unittest

from compare_commit_trace import compare_traces


class TraceComparisonTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.rtl = Path(self.temporary.name) / "rtl.csv"
        self.spike = Path(self.temporary.name) / "spike.log"
        self.header = "order,pc,instr,rd_write,rd,rd_wdata,mem_valid,mem_write,mem_addr,rmask,wmask,mem_rdata,mem_wdata,trap,cause".split(",")
        self.rows = [
            ["1", "aaaaa000", "00100093", "1", "1", "00000001", "0", "0", "00000000", "0", "0", "00000000", "00000000", "0", "15"],
            ["2", "aaaaa004", "f0002013", "0", "0", "00000000", "0", "0", "00000000", "0", "0", "00000000", "00000000", "0", "15"],
        ]
        self.spike.write_text("core   0: 3 0xaaaaa000 (0x00100093) x1  0x00000001\ncore   0: 3 0xaaaaa004 (0xf0002013)\n")

    def write_rtl(self):
        with self.rtl.open("w", newline="") as output:
            writer = csv.writer(output)
            writer.writerow(self.header)
            writer.writerows(self.rows)

    def test_matching_trace(self):
        self.write_rtl()
        self.assertEqual(compare_traces(self.rtl, self.spike), 2)

    def test_wrong_writeback(self):
        self.rows[0][5] = "00000002"
        self.write_rtl()
        with contextlib.redirect_stderr(io.StringIO()) as output:
            self.assertIsNone(compare_traces(self.rtl, self.spike))
        self.assertIn("rd_wdata", output.getvalue())

    def test_truncated_trace(self):
        self.rows.pop()
        self.write_rtl()
        with self.assertRaisesRegex(ValueError, "no magic halt"):
            compare_traces(self.rtl, self.spike)


if __name__ == "__main__":
    unittest.main()

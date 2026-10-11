# SPDX-License-Identifier: Apache-2.0
.section .text
.option norvc
.option norelax
.globl _start
_start:
    la x1, test_data
    li x2, 0x11223344
    sw x2, 0(x1)
    li x3, 0xaa
    sb x3, 1(x1)
    lb x4, 1(x1)
    lbu x5, 1(x1)
    li x6, 0xbbcc
    sh x6, 2(x1)
    lh x7, 2(x1)
    lhu x8, 2(x1)
    lw x9, 0(x1)
    lw x0, 0(x1)
    slti x0, x0, -256

.section .data
.align 2
test_data:
    .word 0

# SPDX-License-Identifier: Apache-2.0

.section .init
.option norvc
.option norelax
.globl _start
.type _start, @function

_start:
    la gp, __global_pointer$
    la sp, __stack_top

    la t0, __bss_start
    la t1, __bss_end
.Lclear_bss:
    bgeu t0, t1, .Lcall_main
    sw zero, 0(t0)
    addi t0, t0, 4
    jal zero, .Lclear_bss

.Lcall_main:
    call main

    # Benchmark-monitor halt marker. It writes x0 and has no architectural
    # side effect; the benchmark monitor stops when this instruction commits.
    .word 0xf0002013

.Lhalt:
    jal zero, .Lhalt

.size _start, .-_start

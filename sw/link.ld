/* SPDX-License-Identifier: Apache-2.0 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

/* Match the external RV32IM workload address convention without allocating a
 * flat memory between the program and the high stack address. */
PROGRAM_BASE = 0xAAAAA000;
__stack_top = 0xF0000000;

PHDRS
{
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}

SECTIONS
{
  . = PROGRAM_BASE;

  .init : ALIGN(4)
  {
    KEEP(*(.init))
  } :text

  .text : ALIGN(4)
  {
    *(.text .text.*)
  } :text

  .rodata : ALIGN(4)
  {
    *(.rodata .rodata.*)
  } :text

  . = ALIGN(0x1000);
  .data : ALIGN(4)
  {
    *(.data .data.*)
    *(.sdata .sdata.*)
  } :data

  __global_pointer$ = . + 0x800;

  .bss (NOLOAD) : ALIGN(4)
  {
    __bss_start = .;
    *(.bss .bss.*)
    *(.sbss .sbss.*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } :data

  . = ALIGN(16);
  __heap_start = .;
  __image_end = .;

  /DISCARD/ :
  {
    *(.comment)
    *(.eh_frame .eh_frame.*)
    *(.riscv.attributes)
  }
}

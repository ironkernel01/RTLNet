/*
 * rtlnet_fw.ld -- linker script of the RTLNet Nexys Video firmware
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Memory: the 128 KiB LMB block RAM at 0x0000_0000 (RTLNET_CPU_LMB_BASE /
 * _SIZE in rtlnet_cpu_microblaze.h), split into
 *   lmb_rom 0x0000_0000 .. 0x0001_7FFF  vectors, code, read-only data, and the
 *                                       load image of .sdata/.data
 *   lmb_ram 0x0001_8000 .. 0x0001_FFFF  .sdata/.data (copied by crt0), .sbss,
 *                                       .bss, stack (no heap)
 * "rom" is still RAM; the split keeps a pristine .data image so a soft
 * restart (jump to 0) starts from initial values. updatemem loads the whole
 * ELF (both regions) into the block RAM of the bitstream.
 *
 * Symbols for crt0.S: _stack_top, _SDA_BASE_, _SDA2_BASE_, __data_load,
 * __data_start, __data_end, __bss_start, __bss_end.
 */
OUTPUT_FORMAT("elf32-microblazeel")
OUTPUT_ARCH(microblaze)
ENTRY(_start)

STACK_SIZE = 0x2000;

MEMORY
{
    lmb_rom (rx)  : ORIGIN = 0x00000000, LENGTH = 0x00018000
    lmb_ram (rw)  : ORIGIN = 0x00018000, LENGTH = 0x00008000
}

SECTIONS
{
    /* Vectors at their fixed addresses (one section each, see crt0.S). */
    .vectors.reset 0x00000000 : {
        KEEP(*(.vectors.reset))
    } > lmb_rom
    .vectors.user_exception 0x00000008 : {
        KEEP(*(.vectors.user_exception))
    } > lmb_rom
    .vectors.interrupt 0x00000010 : {
        KEEP(*(.vectors.interrupt))
    } > lmb_rom
    .vectors.break 0x00000018 : {
        KEEP(*(.vectors.break))
    } > lmb_rom
    .vectors.hw_exception 0x00000020 : {
        KEEP(*(.vectors.hw_exception))
    } > lmb_rom

    .text 0x00000050 : {
        KEEP(*(.text.start))
        *(.text .text.* .gnu.linkonce.t.*)
    } > lmb_rom

    .rodata : ALIGN(4) {
        *(.rodata .rodata.* .gnu.linkonce.r.*)
    } > lmb_rom

    .sdata2 : ALIGN(4) {
        __sdata2_start = .;
        *(.sdata2 .sdata2.* .gnu.linkonce.s2.*)
        __sdata2_end = .;
    } > lmb_rom

    .sbss2 : ALIGN(4) {
        __sbss2_start = .;
        *(.sbss2 .sbss2.* .gnu.linkonce.sb2.*)
        __sbss2_end = .;
    } > lmb_rom

    .data : ALIGN(4) {
        __data_start = .;
        *(.data .data.* .gnu.linkonce.d.*)
        . = ALIGN(4);
    } > lmb_ram AT > lmb_rom

    .sdata : ALIGN(4) {
        __sdata_start = .;
        *(.sdata .sdata.* .gnu.linkonce.s.*)
        __sdata_end = .;
        . = ALIGN(4);
        __data_end = .;
    } > lmb_ram AT > lmb_rom

    .sbss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        __sbss_start = .;
        *(.sbss .sbss.* .gnu.linkonce.sb.*)
        __sbss_end = .;
    } > lmb_ram

    .bss (NOLOAD) : ALIGN(4) {
        *(.bss .bss.* .gnu.linkonce.b.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > lmb_ram

    .stack (NOLOAD) : ALIGN(8) {
        _stack_end = .;
        . += STACK_SIZE;
        . = ALIGN(8);
        _stack_top = .;
    } > lmb_ram

    __data_load = LOADADDR(.data);
    _SDA_BASE_  = __sdata_start + ((__sbss_end - __sdata_start) / 2);
    _SDA2_BASE_ = __sdata2_start + ((__sbss2_end - __sdata2_start) / 2);

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame)
    }
}

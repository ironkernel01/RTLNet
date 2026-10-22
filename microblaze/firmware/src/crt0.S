/*
 * crt0.S -- MicroBlaze start-up of the RTLNet Nexys Video firmware
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the vector table at address 0 (C_BASE_VECTORS = 0 in the block
 * design) and the reset entry _start. No vendor BSP.
 *
 * Vectors, one 8-byte slot each (the assembler emits imm + brai for a
 * 32-bit target address):
 *   0x00 reset           -> _start
 *   0x08 user exception  -> _rtlnet_trap_user   (brki/brk from software)
 *   0x10 interrupt       -> rtlnet_isr          (C, interrupt_handler attribute)
 *   0x18 break           -> _rtlnet_trap_break
 *   0x20 HW exception    -> _rtlnet_trap_hw
 *
 * _start:
 *   1. r1 = top of stack (_stack_top, linker script).
 *   2. r2 = _SDA2_BASE_ (read-only small data), r13 = _SDA_BASE_ (small data).
 *   3. Copy the .sdata/.data image from its load address (__data_load) to
 *      __data_start..__data_end, so a soft restart starts from pristine data.
 *   4. Clear __bss_start..__bss_end (.sbss and .bss).
 *   5. Call main; if it returns, spin.
 * The trap handlers spin in place (a debugger attached through the MDM shows
 * where execution stopped).
 */
    /* One section per vector, each placed at its fixed address by the linker
     * script: linker relaxation may shorten imm + brai to a single brai, and
     * separate sections keep every vector at its address regardless. */
    .section .vectors.reset, "ax"
    .align  2
    .globl  _vector_reset
_vector_reset:
    brai    _start

    .section .vectors.user_exception, "ax"
    .align  2
_vector_user_exception:
    brai    _rtlnet_trap_user

    .section .vectors.interrupt, "ax"
    .align  2
_vector_interrupt:
    brai    rtlnet_isr

    .section .vectors.break, "ax"
    .align  2
_vector_break:
    brai    _rtlnet_trap_break

    .section .vectors.hw_exception, "ax"
    .align  2
_vector_hw_exception:
    brai    _rtlnet_trap_hw

    .section .text.start, "ax"
    .align  2
    .globl  _start
    .type   _start, @function
_start:
    addik   r1, r0, _stack_top
    addik   r2, r0, _SDA2_BASE_
    addik   r13, r0, _SDA_BASE_

    /* .data image copy, word by word (sections are 4-byte aligned). */
    addik   r5, r0, __data_load
    addik   r6, r0, __data_start
    addik   r7, r0, __data_end
.Lcopy:
    cmpu    r18, r7, r6             /* r18 < 0 while r6 < r7 (unsigned) */
    bgei    r18, .Lcopy_done
    lwi     r3, r5, 0
    swi     r3, r6, 0
    addik   r5, r5, 4
    brid    .Lcopy
    addik   r6, r6, 4               /* delay slot */
.Lcopy_done:

    /* .sbss and .bss clear. */
    addik   r6, r0, __bss_start
    addik   r7, r0, __bss_end
.Lclear:
    cmpu    r18, r7, r6
    bgei    r18, .Lclear_done
    swi     r0, r6, 0
    brid    .Lclear
    addik   r6, r6, 4               /* delay slot */
.Lclear_done:

    brlid   r15, main
    nop                             /* delay slot */
.Lhalt:
    bri     .Lhalt
    .size   _start, . - _start

    .globl  _rtlnet_trap_user
_rtlnet_trap_user:
    bri     _rtlnet_trap_user
    .globl  _rtlnet_trap_break
_rtlnet_trap_break:
    bri     _rtlnet_trap_break
    .globl  _rtlnet_trap_hw
_rtlnet_trap_hw:
    bri     _rtlnet_trap_hw

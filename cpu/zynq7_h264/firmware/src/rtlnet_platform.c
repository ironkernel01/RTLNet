/* Purpose: own PS UART, GIC, timer and Cortex-A9 cache operations.
 * Overview: synchronous polling console, microsecond ticks and bounded UART waits;
 *   shared PL buffer ranges are widened to whole 32-byte cache lines, then barriered.
 * Revision: 11-14-2026. Initial ARM platform.
 */
#include "rtlnet_platform.h"
#include "rtlnet_board.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xil_printf.h"
#include "xscugic.h"
#include "xiltimer.h"
#include "xuartps.h"
#include "xuartps_hw.h"

static XScuGic g_gic;
static XUartPs g_uart;

/* rtlnet_fatal -- report the failing API and park with interrupts masked. */
void rtlnet_fatal(const char *api, int status)
{
    Xil_ExceptionDisable();
    xil_printf("RTLNET FATAL: %s status=%d\r\n", api, status);
    for (;;) { __asm__ volatile ("wfi"); }
}

/* plat_init -- initialize the single PS console and interrupt controller. */
void plat_init(void)
{
    XUartPs_Config *uart = XUartPs_LookupConfig(0);
    XScuGic_Config *gic = XScuGic_LookupConfig(0);
    int rc;
    Xil_ICacheEnable();
    Xil_DCacheEnable();
    if (uart == NULL || gic == NULL) rtlnet_fatal("LookupConfig", -1);
    rc = XUartPs_CfgInitialize(&g_uart, uart, uart->BaseAddress);
    if (rc != XST_SUCCESS) rtlnet_fatal("XUartPs_CfgInitialize", rc);
    rc = XUartPs_SetBaudRate(&g_uart, 115200u);
    if (rc != XST_SUCCESS) rtlnet_fatal("XUartPs_SetBaudRate", rc);
    rc = XScuGic_CfgInitialize(&g_gic, gic, gic->CpuBaseAddress);
    if (rc != XST_SUCCESS) rtlnet_fatal("XScuGic_CfgInitialize", rc);
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT, (Xil_ExceptionHandler)XScuGic_InterruptHandler, &g_gic);
    Xil_ExceptionEnable();
}

uint32_t plat_ticks(void)
{
    XTime value;
    XTime_GetTime(&value);
    return (uint32_t)((value / COUNTS_PER_SECOND) * 1000000ull +
        ((value % COUNTS_PER_SECOND) * 1000000ull) / COUNTS_PER_SECOND);
}
uint32_t plat_uptime_ms(void)
{
    XTime value;
    XTime_GetTime(&value);
    return (uint32_t)((value / COUNTS_PER_SECOND) * 1000ull +
        ((value % COUNTS_PER_SECOND) * 1000ull) / COUNTS_PER_SECOND);
}
void plat_delay_us(uint32_t us)
{
    uint32_t start = plat_ticks();
    while ((uint32_t)(plat_ticks() - start) < us) { }
}
void plat_delay_ms(uint32_t ms)
{
    while (ms-- != 0u) plat_delay_us(1000u);
}
void plat_console_write(const char *s, size_t n)
{
    for (size_t i = 0u; i < n; i++) {
        uint32_t start = plat_ticks();
        while (XUartPs_IsTransmitFull(RTLNET_PS_UART_BASE)) {
            if ((uint32_t)(plat_ticks() - start) >= 100000u) rtlnet_fatal("UART TX timeout", -1);
        }
        XUartPs_WriteReg(RTLNET_PS_UART_BASE, XUARTPS_FIFO_OFFSET, (uint8_t)s[i]);
    }
}
int plat_console_getc(void)
{
    return XUartPs_IsReceiveData(RTLNET_PS_UART_BASE) ?
        (int)(XUartPs_ReadReg(RTLNET_PS_UART_BASE, XUARTPS_FIFO_OFFSET) & 255u) : -1;
}
void plat_poll(void) { }
uint32_t plat_irq_save(void)
{
    uint32_t state;
    __asm__ volatile ("mrs %0, cpsr\n\tcpsid i" : "=r"(state) : : "memory");
    return state;
}
void plat_irq_restore(uint32_t state)
{
    if ((state & 0x80u) == 0u) __asm__ volatile ("cpsie i" : : : "memory");
}
int plat_irq_attach(unsigned input, void (*handler)(void *), void *ref)
{
    if (input > 1u) return -1;
    XScuGic_Disable(&g_gic, 61u + input);
    XScuGic_SetPriorityTriggerType(&g_gic, 61u + input, 0xa0u, input == 0u ? 3u : 1u);
    return XScuGic_Connect(&g_gic, 61u + input, (Xil_InterruptHandler)handler, ref) == XST_SUCCESS ? 0 : -1;
}
void plat_irq_enable(unsigned input, int on)
{
    if (input > 1u) rtlnet_fatal("invalid fabric IRQ", (int)input);
    if (on) XScuGic_Enable(&g_gic, 61u + input);
    else XScuGic_Disable(&g_gic, 61u + input);
}
void plat_mem_barrier(void) { __asm__ volatile ("dsb sy" : : : "memory"); }
void plat_dcache_flush_range(uintptr_t addr, size_t len)
{
    uintptr_t first = addr & ~(uintptr_t)31u;
    uintptr_t end = (addr + len + 31u) & ~(uintptr_t)31u;
    if (len != 0u) Xil_DCacheFlushRange(first, (u32)(end - first));
    plat_mem_barrier();
}
void plat_dcache_invalidate_range(uintptr_t addr, size_t len)
{
    uintptr_t first = addr & ~(uintptr_t)31u;
    uintptr_t end = (addr + len + 31u) & ~(uintptr_t)31u;
    plat_mem_barrier();
    if (len != 0u) Xil_DCacheInvalidateRange(first, (u32)(end - first));
    plat_mem_barrier();
}
int board_ddr_calibrated(void) { return 1; }

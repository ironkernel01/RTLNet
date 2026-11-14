/*
 * xaxidma.h -- desktop mock of the Xilinx AXI DMA driver calls used by rtlnet_lwip_netif.c
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: lets rtlnet_lwip_netif.c compile and run unchanged on the host. The
 * S2MM side is armed by the netif and completed by the test (mock_rx_inject);
 * the MM2S side captures what the netif sends (the buffer address and a copy
 * of the bytes at the time of the transfer) and can be kept busy for a number
 * of status reads to model a transfer in flight. Implemented in
 * netif_host_test.c.
 */
#ifndef XAXIDMA_MOCK_H
#define XAXIDMA_MOCK_H

#include <stdint.h>
#include <stddef.h>

typedef uintptr_t UINTPTR;

typedef struct { int unused; } XAxiDma_Config;
typedef struct { uintptr_t RegBase; } XAxiDma;

#define XST_SUCCESS                0
#define XAXIDMA_TX_OFFSET          0x00u
#define XAXIDMA_RX_OFFSET          0x30u
#define XAXIDMA_SR_OFFSET          0x04u
#define XAXIDMA_BUFFLEN_OFFSET     0x28u
#define XAXIDMA_HALTED_MASK        0x00000001u
#define XAXIDMA_IDLE_MASK          0x00000002u
#define XAXIDMA_ERR_ALL_MASK       0x00000770u
#define XAXIDMA_IRQ_ALL_MASK       0x00007000u
#define XAXIDMA_DEVICE_TO_DMA      0x04
#define XAXIDMA_DMA_TO_DEVICE      0x00

XAxiDma_Config *XAxiDma_LookupConfig(uintptr_t base);
int             XAxiDma_CfgInitialize(XAxiDma *dma, XAxiDma_Config *cfg);
int             XAxiDma_HasSg(XAxiDma *dma);
void            XAxiDma_Reset(XAxiDma *dma);
int             XAxiDma_ResetIsDone(XAxiDma *dma);
void            XAxiDma_IntrDisable(XAxiDma *dma, uint32_t mask, int dir);
int             XAxiDma_SimpleTransfer(XAxiDma *dma, UINTPTR buf, uint32_t len, int dir);
uint32_t        XAxiDma_ReadReg_mock(uintptr_t base, uint32_t offset);
#define XAxiDma_ReadReg(base, offset) XAxiDma_ReadReg_mock((base), (offset))

#endif /* XAXIDMA_MOCK_H */

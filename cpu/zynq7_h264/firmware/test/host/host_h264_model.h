/*
 * host_h264_model.h -- internal interface of the H.264 encoder core model of the desktop harness
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the register model of ip/rtlnet_h264_enc for the host build (host_h264_model.c), called by the register hooks of host_platform.c. The
 * model is functional enough to run the encoder session end to end: START with a busy time counted in model ticks, picture entries and bytes
 * written into the DDR3 model, STATUS, the interrupt registers and the irq line (host_irq_set_line of host_platform.c), the High profile status with
 * PROFILE_CHG at a changed profile, an older core without the interrupt registers. The harness controls are declared in host_platform.h.
 */
#ifndef HOST_H264_MODEL_H
#define HOST_H264_MODEL_H

#include <stdint.h>

int      host_h264_active(void);                          /* 1 when the core answers */
uint32_t host_h264_read(uint32_t offset);
void     host_h264_write(uint32_t offset, uint32_t value);
void     host_h264_on_access(void);                       /* called by every register access: advances the model when timing by access is set */

#endif /* HOST_H264_MODEL_H */

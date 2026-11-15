/* Purpose: run the actual local SDK PHY replacements against a Clause-22 model.
 * Overview: check E/F register selection, page restoration and bounded failures.
 * Revision: 11-14-2026. MDIO model only; no physical Ethernet claim.
 */
#include "rtlnet_phy.h"
#include <stdint.h>
#include <stdio.h>
typedef uint16_t u16_t;
typedef uint32_t u32_t;
typedef struct { int unused; } XEmacPs;
#define XST_SUCCESS 0
#define XST_FAILURE 1
#define PHY_SPEED_AUTONEG 0
#define PHY_AUTONEG_ENABLE 1
#define PHY_AUTONEG_TIMEOUT_DEFAULT 30
static uint32_t id;
static uint16_t wire_status, page, control;
static unsigned reset_reads, reads, writes, waits, sleeps, e_status_reads, f_status_reads;
static int stuck_reset, fail_read, fail_status, fail_restore, autoneg_failure;
static int failures, checks;
static XEmacPs device;
#define CHECK(x) do { checks++;if(!(x)){failures++;printf("PHY port line %d failed: %s\n",__LINE__,#x);} } while(0)
static int XEmacPs_PhyRead(XEmacPs *p,u32_t addr,unsigned reg,u16_t *out)
{
    (void)p; CHECK(addr==1u); reads++;
    if(fail_read) return XST_FAILURE;
    if(reg==2u) *out=(uint16_t)(id>>16);
    else if(reg==3u) *out=(uint16_t)id;
    else if(reg==31u) *out=page;
    else if(reg==0u) {
        if(control&0x8000u) { reset_reads++; if(!stuck_reset && reset_reads>=2u) control&=0x7fffu; }
        *out=control;
    } else if(reg==0x11u && page==0u) { e_status_reads++; *out=wire_status; return fail_status?1:0; }
    else if(reg==0x1au && page==0xa43u) { f_status_reads++; *out=wire_status; return fail_status?1:0; }
    else { CHECK(0); return XST_FAILURE; }
    return XST_SUCCESS;
}
static int XEmacPs_PhyWrite(XEmacPs *p,u32_t addr,unsigned reg,u16_t value)
{
    (void)p; CHECK(addr==1u); writes++;
    if(reg==31u) {
        if(fail_restore && value==0u) return XST_FAILURE;
        page=value;
    } else if(reg==0u) control=value;
    else CHECK(0);
    return XST_SUCCESS;
}
static void Configure_Phy_Speed(XEmacPs *p,u32_t a,unsigned speed,unsigned en)
{ (void)p; CHECK(a==1u && speed==0u && en==1u); }
static u32_t Wait_Autoneg_Complete(XEmacPs *p,u32_t a,unsigned bound)
{ (void)p; CHECK(a==1u && bound==30u); waits++; return autoneg_failure?1u:0u; }
static void usleep(unsigned us) { CHECK(us==1000u || us==100000u); sleeps++; }
/* Generated directly from the two functions compiled into the ARM application. */
#include "rtlnet_phy_functions.inc"
static void setup(uint32_t which,uint16_t status)
{
    id=which; wire_status=status; page=0u; control=0x1140u;
    reset_reads=reads=writes=waits=sleeps=e_status_reads=f_status_reads=0u;
    stuck_reset=fail_read=fail_status=fail_restore=autoneg_failure=0;
}
int main(int argc,char **argv)
{
    (void)argv;
    const uint16_t e_words[3]={0x0400,0x4400,0x8400};
    const uint16_t f_words[3]={0x0004,0x0014,0x0024};
    const unsigned speeds[3]={10,100,1000};
    for(unsigned n=0;n<3;n++) {
        setup(0x001cc915u,e_words[n]); CHECK(get_Realtek_phy_speed(&device,1u)==speeds[n]);
        CHECK(e_status_reads==1u && f_status_reads==0u && page==0u && waits==1u);
        setup(0x001cc916u,f_words[n]); CHECK(get_Realtek_phy_speed(&device,1u)==speeds[n]);
        CHECK(e_status_reads==0u && f_status_reads==1u && page==0u && writes==3u);
    }
    setup(0x001cc916u,0x0020u); CHECK(get_Realtek_phy_speed(&device,1u)==XST_FAILURE); CHECK(page==0u);
    setup(0x12345678u,0xffffu); CHECK(get_Realtek_phy_speed(&device,1u)==XST_FAILURE); CHECK(writes==0u);
    setup(0x001cc916u,0x0024u); fail_status=1; CHECK(get_Realtek_phy_speed(&device,1u)==XST_FAILURE); CHECK(page==0u);
    setup(0x001cc916u,0x0024u); fail_restore=1; CHECK(get_Realtek_phy_speed(&device,1u)==XST_FAILURE);
    setup(0x001cc915u,0x8400u); autoneg_failure=1; CHECK(get_Realtek_phy_speed(&device,1u)==XST_FAILURE); CHECK(!e_status_reads);
    setup(0x001cc915u,0x8400u); stuck_reset=1; CHECK(get_Realtek_phy_speed(&device,1u)==XST_FAILURE);
    CHECK(reset_reads==1000u && sleeps==1000u && reads==1003u && !waits);
    setup(0x001cc915u,0x8400u); fail_read=1; CHECK(Reset_Realtek_Phy(&device,1u)==XST_FAILURE); CHECK(writes==0u);
    if(argc>1) CHECK(0);
    printf("RTLNET_PHY_PORT: %s checks=%d failures=%d\n",failures?"FAIL":"PASS",checks,failures);
    return failures?1:0;
}

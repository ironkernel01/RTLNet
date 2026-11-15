/* Purpose: exercise generated MenuBuilder and real portable session setters.
 * Overview: target MMIO is mocked absent. Invalid commands must not change state.
 * Revision: 11-14-2026. Positive and deliberately failing negative control.
 */
#include "menu.h"
#include "rtlnet_venc.h"
#include "rtlnet_sensor.h"
#include "rtlnet_dphy.h"
#include <stdio.h>
#include <string.h>
static int failures,checks;
#define CHECK(x) do { checks++;if(!(x)){failures++;printf("FAIL line %d: %s\n",__LINE__,#x);} } while(0)
static void sink(const char *s,size_t n) { (void)s;(void)n; }
static void console(const char *s,size_t n) { (void)fwrite(s,1,n,stdout); }
int main(int argc,char **argv)
{
    const MenuIo io={sink}; venc_status_t s;
    venc_init();
    if(argc==2 && !strcmp(argv[1],"--run")) {
        const MenuIo terminal={console};
        int ch;
        if(Menu_Init(&terminal)) return 1;
        Menu_PrintPrompt();
        while((ch=getchar())!=EOF) Menu_InputChar(ch);
        return 0;
    }
    CHECK(Menu_Init(&io)==0);
    CHECK(Menu_ProcessLine("encoder qp 31")!=0);
    CHECK(Menu_ProcessLine("enable")==0);
    CHECK(Menu_ProcessLine("encoder qp 31")==0);
    CHECK(Menu_ProcessLine("encoder gop 45")==0);
    CHECK(Menu_ProcessLine("encoder bitrate 4000")==0);
    venc_get_status(&s); CHECK(s.qp==31u); CHECK(s.gop==45u);
    CHECK(Menu_ProcessLine("encoder qp 52")!=0);
    CHECK(Menu_ProcessLine("encoder gop 0")!=0);
    CHECK(Menu_ProcessLine("encoder bitrate 100001")!=0);
    CHECK(Menu_ProcessLine("encoder qp -1")!=0);
    CHECK(Menu_ProcessLine("encoder qp 2x")!=0);
    venc_get_status(&s); CHECK(s.qp==31u); CHECK(s.gop==45u);
    CHECK(Menu_ProcessLine("camera mode 1080p15")==0); CHECK(rtlnet_sensor_get_mode()==1u);
    CHECK(Menu_ProcessLine("camera mode 720p30")==0); CHECK(rtlnet_sensor_get_mode()==0u);
    CHECK(Menu_ProcessLine("stream start 999.1.1.1 5000")!=0);
    CHECK(Menu_ProcessLine("stream start 192.0.2.2 0")!=0);
    CHECK(Menu_ProcessLine("stream start 192.0.2.2 5000")!=0); /* absent core */
    CHECK(Menu_ProcessLine("stream stop")==0);
    CHECK(Menu_ProcessLine("show version")==0);
    CHECK(Menu_ProcessLine("show encoder")==0);
    CHECK(Menu_ProcessLine("show stream")==0);
    CHECK(Menu_ProcessLine("show ip")==0);
    CHECK(Menu_ProcessLine("show camera")==0);
    {
        rtlnet_dphy_state_t d;
        rtlnet_dphy_read(RTLNET_DPHY_BASE, &d);
        CHECK(d.control == 2u);
        CHECK(d.version == 0x00010003u);
    }
    CHECK(Menu_ProcessLine("nonsense")!=0);
    if(argc>1) CHECK(0);
    printf("RTLNET_ARM_CLI: %s checks=%d failures=%d\n",failures?"FAIL":"PASS",checks,failures);
    return failures?1:0;
}

#include "../firmware/maclink_schedule.h"
#include <cassert>
#include <cstdio>
int main() {
    const uint32_t base=1800000000;
    MacLinkSchedule s={1800,base+200000,2,true,true,{{base+100,base+10000},{base+86500,base+96000}}};
    assert(!maclinkUpdateAllowed(s,base));
    assert(maclinkSleepSeconds(s,base,0)==100);
    assert(maclinkUpdateAllowed(s,base+100));
    assert(maclinkSleepSeconds(s,base+100,1800)==1800);
    assert(!maclinkUpdateAllowed(s,base+10000));
    assert(maclinkSleepSeconds(s,base+9900,1800)==76600);
    assert(maclinkSleepSeconds(s,base+10000,0)==76500);
    // Cached policy still applies after a failed network check / RTC wake.
    MacLinkSchedule retained=s;
    assert(maclinkSleepSeconds(retained,base+10000,1800)==76500);
    retained.limited=false;
    assert(maclinkUpdateAllowed(retained,base));
    assert(maclinkSleepSeconds(retained,base,86400)==86400);
    assert(maclinkUpdateAllowed(s,0)); // Bootstrap with an unknown clock.
    assert(maclinkUpdateAllowed(s,s.expires)); // Refresh expired policy once.
    puts("Firmware scheduling checks passed");
}

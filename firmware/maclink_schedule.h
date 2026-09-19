// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Jan Kampling
// MacLink additions to OpenDisplay Firmware; see LICENSE in this directory.

#pragma once
#include <stdint.h>

struct MacLinkWindow { uint32_t start, end; };
struct MacLinkSchedule {
    uint32_t interval;
    uint32_t expires;
    uint8_t count;
    bool loaded;
    bool limited;
    MacLinkWindow windows[34];
};

inline bool maclinkScheduleKnown(const MacLinkSchedule &s, uint32_t now) {
    return s.loaded && now >= 1700000000UL && now < s.expires;
}
inline bool maclinkUpdateAllowed(const MacLinkSchedule &s, uint32_t now) {
    // One bootstrap check is needed after loss of clock/policy, or a month offline.
    if (!maclinkScheduleKnown(s, now) || !s.limited) return true;
    for (unsigned i=0; i<s.count; ++i)
        if (now >= s.windows[i].start && now < s.windows[i].end) return true;
    return false;
}
inline uint32_t maclinkSleepSeconds(const MacLinkSchedule &s, uint32_t now, uint32_t minimum) {
    if (!maclinkScheduleKnown(s, now) || !s.limited) return minimum ? minimum : 1;
    const uint64_t target = (uint64_t)now + minimum;
    for (unsigned i=0; i<s.count; ++i) {
        if (target < s.windows[i].end) {
            uint64_t wake = target > s.windows[i].start ? target : s.windows[i].start;
            if (wake > s.expires) wake = s.expires;
            return wake > now ? (uint32_t)(wake-now) : 1;
        }
    }
    return s.expires > now ? s.expires-now : 1;
}

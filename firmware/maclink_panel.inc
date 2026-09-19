// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Jan Kampling
// MacLink additions to OpenDisplay Firmware; see LICENSE in this directory.

// Included at the end of OpenDisplay display_service.cpp, where session helpers live.
// This transport intentionally supports the verified XIAO 7.5 monochrome panel only.
static uint32_t maclinkWritten = 0;
bool maclinkPanelBegin() {
    if (odWatchdogInSafeMode() || globalConfig.display_count != 1) return false;
    const auto &d = globalConfig.displays[0];
    if (d.panel_ic_type != 59 || d.pixel_width != 800 || d.pixel_height != 480 || d.color_scheme != 0) return false;
    epdSessionAcquire(false);
    epdPlanesPrepared = false;
    bbepSetAddrWindow(&bbep, 0, 0, 800, 480);
    bbepStartWrite(&bbep, getplane());
    maclinkWritten = 0;
    return true;
}
bool maclinkPanelWrite(uint8_t *data, unsigned int length) {
    if (maclinkWritten + length > 48000) return false;
    bbepWriteData(&bbep, data, length);
    maclinkWritten += length;
    return true;
}
bool maclinkPanelFinish(bool verified) {
    bool success = false;
    if (verified && maclinkWritten == 48000) {
        epdRefreshInProgress = true;
        odWatchdogFeed();
        bbepRefresh(&bbep, REFRESH_FULL);
        success = waitforrefresh(60);
        endRefresh();
    }
    epdSessionRelease(success);
    epdSessionForceOff();
    return success;
}

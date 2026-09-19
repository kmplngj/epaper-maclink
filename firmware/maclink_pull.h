// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Jan Kampling
// MacLink additions to OpenDisplay Firmware; see LICENSE in this directory.

#pragma once
[[noreturn]] void maclinkPullRun();
bool maclinkPanelBegin();
bool maclinkPanelWrite(unsigned char *data, unsigned int length);
bool maclinkPanelFinish(bool verified);

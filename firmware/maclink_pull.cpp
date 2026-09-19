// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Jan Kampling
// MacLink additions to OpenDisplay Firmware; see LICENSE in this directory.

#ifdef MACLINK_HTTP_PULL
#include "maclink_pull.h"
#include "maclink_secrets.h"
#include "display_service.h"
#include "od_log.h"
#include "watchdog.h"
#include <WiFi.h>
#include <HTTPClient.h>
#include <mbedtls/sha256.h>
#include <esp_sleep.h>
#include <sys/time.h>
#include "maclink_schedule.h"
#ifdef MACLINK_USB_PANEL_TEST
#include "maclink_panel_test.h"
#endif

RTC_DATA_ATTR static char shownHash[65] = {};
RTC_DATA_ATTR static uint32_t cycles = 0;
RTC_DATA_ATTR static MacLinkSchedule schedule = {300, 0, 0, false, false, {}};

static void receiveSchedule(HTTPClient &http) {
    const String stamp = http.header("X-Server-Time");
    const uint32_t now = strtoul(stamp.c_str(), nullptr, 10);
    const uint32_t expires = strtoul(http.header("X-Schedule-Until").c_str(), nullptr, 10);
    const int interval = http.header("X-Update-Seconds").toInt();
    const String windows = http.header("X-Update-Windows");
    if (now < 1700000000UL || expires <= now || (uint64_t)expires-now > 32ULL*86400 || interval < 60 || interval > 86400) return;
    MacLinkSchedule next = {(uint32_t)interval, expires, 0, true, windows != "*", {}};
    if (next.limited) {
        const char *cursor = windows.c_str();
        while (*cursor && next.count < 34) {
            char *end;
            const unsigned long start = strtoul(cursor, &end, 10);
            if (end == cursor || *end != '-') return;
            cursor = end+1;
            const unsigned long finish = strtoul(cursor, &end, 10);
            if (end == cursor || (*end && *end != ',') || finish <= start || start > UINT32_MAX || finish > UINT32_MAX) return;
            if (next.count && start < next.windows[next.count-1].end) return;
            next.windows[next.count++] = {(uint32_t)start, (uint32_t)finish};
            cursor = *end ? end+1 : end;
        }
        if (*cursor || !next.count) return;
    }
    schedule = next;
    const struct timeval clock = {(time_t)now, 0};
    settimeofday(&clock, nullptr);
    Serial.printf("MacLink schedule: interval %u seconds, %s, %u cached windows\n", schedule.interval, schedule.limited?"daily hours":"all day", schedule.count);
}

[[noreturn]] static void sleepFor(uint32_t seconds) {
    Serial.printf("MacLink deep sleep: %u seconds\n", seconds);
    od_log_flush(); Serial.flush(); delay(50);
    esp_sleep_enable_timer_wakeup((uint64_t)seconds*1000000ULL);
    esp_deep_sleep_start();
}

static bool validHash(const String &value) {
    if (value.length() != 64) return false;
    for (unsigned i=0; i<64; i++) if (!isxdigit(value[i]) || isupper(value[i])) return false;
    return true;
}

static void acknowledge() {
    if (!shownHash[0]) return;
    NetworkClient net;
    HTTPClient http;
    http.setConnectTimeout(5000); http.setTimeout(5000);
    http.begin(net, String(MACLINK_URL) + "/ack");
    http.addHeader("Authorization", String("Bearer ") + MACLINK_TOKEN);
    http.addHeader("Content-Type", "application/json");
    const int code = http.POST(String("{\"digest\":\"") + shownHash + "\"}");
    Serial.printf("MacLink acknowledgement: %d\n", code);
    http.end();
}

static void fetchFrame() {
    NetworkClient net;
    HTTPClient http;
    http.setConnectTimeout(5000); http.setTimeout(10000);
    http.useHTTP10(true); // Server returns a known-length, uncompressed frame.
    http.begin(net, String(MACLINK_URL) + "/frame");
    const char *keys[] = {"X-Pixel-Hash", "X-Width", "X-Height", "X-Poll-Seconds", "ETag", "X-Server-Time", "X-Update-Seconds", "X-Schedule-Until", "X-Update-Windows"};
    http.collectHeaders(keys, 9);
    http.addHeader("Authorization", String("Bearer ") + MACLINK_TOKEN);
    if (shownHash[0]) http.addHeader("If-None-Match", String("\"") + shownHash + "~raw\"");
    const int code = http.GET();
    const int next = http.header("X-Poll-Seconds").toInt();
    if (next >= 60 && next <= 86400) schedule.interval = next;
    if (code == 200 || code == 204 || code == 304 || code == 404) receiveSchedule(http);
    if (code == 204) {
        Serial.println("MacLink quiet hours: no frame downloaded or panel refresh");
        http.end(); return;
    }
    if (code == 304 && shownHash[0]) {
        Serial.println("MacLink unchanged: HTTP 304, zero frame bytes, no panel refresh");
        http.end(); acknowledge(); return;
    }
    String digest = http.header("X-Pixel-Hash");
    if (code != 200 || http.getSize() != 48000 || !validHash(digest) ||
        http.header("X-Width") != "800" || http.header("X-Height") != "480") {
        Serial.printf("MacLink frame unavailable/invalid: HTTP %d, length %d\n", code, http.getSize());
        http.end(); return;
    }
    if (!maclinkPanelBegin()) { Serial.println("MacLink panel configuration refused"); http.end(); return; }
    mbedtls_sha256_context sha;
    mbedtls_sha256_init(&sha); mbedtls_sha256_starts(&sha, 0);
    const char descriptor[] = "mono1:white=1:msb:800:480:";
    mbedtls_sha256_update(&sha, (const unsigned char*)descriptor, sizeof(descriptor)-1);
    uint8_t chunk[1024];
    uint32_t received=0, lastByte=millis(), started=millis();
    auto stream = http.getStreamPtr();
    bool valid = true;
    while (received < 48000 && millis()-lastByte < 10000 && millis()-started < 45000) {
        const int available = stream->available();
        if (available > 0) {
            const int count = stream->read(chunk, min((uint32_t)sizeof(chunk), min((uint32_t)available, 48000-received)));
            if (count <= 0) { valid=false; break; }
            mbedtls_sha256_update(&sha, chunk, count);
            if (!maclinkPanelWrite(chunk, count)) { valid=false; break; }
            received += count; lastByte=millis();
        } else if (!http.connected()) break;
        else delay(2);
        odWatchdogFeed();
    }
    uint8_t result[32]; char actual[65];
    mbedtls_sha256_finish(&sha, result); mbedtls_sha256_free(&sha);
    for (int i=0; i<32; i++) sprintf(actual+i*2, "%02x", result[i]);
    actual[64]=0;
    valid = valid && received==48000 && digest==actual;
    http.end();
    const bool refreshed = maclinkPanelFinish(valid);
    Serial.printf("MacLink frame: %u bytes, hash %s, refresh %s\n", received, valid?"verified":"FAILED", refreshed?"confirmed":"skipped/failed");
    if (refreshed) { memcpy(shownHash, actual, sizeof(shownHash)); acknowledge(); }
}

[[noreturn]] void maclinkPullRun() {
    // Run before NimBLE starts: the C3 cannot afford simultaneous BLE + Wi-Fi pools.
    Serial.printf("MacLink HTTP pull 0.1, cycle %u, wake cause %d, heap %u\n", ++cycles, (int)esp_sleep_get_wakeup_cause(), ESP.getFreeHeap());
#ifdef MACLINK_USB_PANEL_TEST
    // Offline panel validation only. The fixture lives in private build output,
    // never in tracked source. Exercise the real panel and retained sleep state
    // without pretending that an HTTP download or acknowledgement took place.
    delay(2000); // Give USB serial a chance to reconnect after flashing/wake.
    if (strcmp(shownHash, MACLINK_TEST_HASH) == 0) {
        Serial.printf("USB panel test: retained hash, refresh skipped, cycle %u\n", cycles);
    } else if (maclinkPanelBegin()) {
        mbedtls_sha256_context sha;
        mbedtls_sha256_init(&sha);mbedtls_sha256_starts(&sha,0);
        const char descriptor[]="mono1:white=1:msb:800:480:";
        mbedtls_sha256_update(&sha,(const unsigned char*)descriptor,sizeof(descriptor)-1);
        uint8_t chunk[1000]; bool complete=true;
        for (unsigned offset=0;offset<48000;offset+=sizeof(chunk)) {
            memcpy(chunk,maclinkTestPixels+offset,sizeof(chunk));
            mbedtls_sha256_update(&sha,chunk,sizeof(chunk));
            if (!maclinkPanelWrite(chunk,sizeof(chunk))) { complete=false;break; }
            odWatchdogFeed();
        }
        uint8_t result[32];char actual[65];
        mbedtls_sha256_finish(&sha,result);mbedtls_sha256_free(&sha);
        for (int i=0;i<32;i++) sprintf(actual+i*2,"%02x",result[i]);
        actual[64]=0;
        complete=complete && strcmp(actual,MACLINK_TEST_HASH)==0;
        const bool refreshed=maclinkPanelFinish(complete);
        if (refreshed) memcpy(shownHash,actual,sizeof(shownHash));
        Serial.printf("USB panel test: 48000 bytes, hash %s, refresh %s\n",complete?"verified":"FAILED",refreshed?"confirmed":"FAILED");
    } else Serial.println("USB panel test: panel configuration refused");
    od_log_flush();
    const unsigned sleepSeconds=cycles<3 ? 15 : 300;
    Serial.printf("USB panel test: deep sleep %u seconds; no Wi-Fi configured\n",sleepSeconds);
    Serial.flush();delay(100);
    esp_sleep_enable_timer_wakeup((uint64_t)sleepSeconds*1000000ULL);
    esp_deep_sleep_start();
#endif
    for (;;) {
        const uint32_t now = (uint32_t)time(nullptr);
        if (!maclinkUpdateAllowed(schedule, now)) {
            Serial.println("MacLink outside update hours: Wi-Fi remains off");
            sleepFor(maclinkSleepSeconds(schedule, now, 0));
        }
        WiFi.persistent(false); WiFi.mode(WIFI_STA);
        WiFi.setHostname("maclink-display"); WiFi.begin(MACLINK_SSID, MACLINK_PASSWORD);
        uint32_t start=millis();
        while (WiFi.status()!=WL_CONNECTED && millis()-start<20000) { delay(100); odWatchdogFeed(); }
        if (WiFi.status()==WL_CONNECTED) {
            Serial.printf("MacLink Wi-Fi connected; heap %u\n", ESP.getFreeHeap());
            fetchFrame();
        } else Serial.println("MacLink Wi-Fi unavailable; retaining the previous image");
        epdSessionForceOff();
        WiFi.disconnect(true); WiFi.mode(WIFI_OFF);
        od_log_flush();
#ifdef MACLINK_DEBUG_AWAKE
        Serial.println("MacLink debug: awake, checking again in 60 seconds");
        for (int i=0;i<600;i++) { delay(100); odWatchdogFeed(); }
#else
        sleepFor(maclinkSleepSeconds(schedule, (uint32_t)time(nullptr), schedule.interval));
#endif
    }
}
#endif

#include <TargetConditionals.h>

#if TARGET_OS_SIMULATOR && defined(__x86_64__)
#include "NovaSRT.h"
#include <stdio.h>

// The vendored xcframework advertises an Intel simulator slice but does not
// export SRT's API in it. UI tests on Intel use the app's existing unavailable
// transport/fallback path. Device and Apple Silicon builds use NovaSRT.mm.
NovaSRTConnection* NovaSRTConnect(const char*, uint16_t, int32_t, char* error, int32_t capacity) {
    if (error && capacity > 0) snprintf(error, capacity, "SRT is unavailable in the Intel simulator");
    return nullptr;
}
int32_t NovaSRTReceive(NovaSRTConnection*, uint8_t*, int32_t, char*, int32_t) { return 0; }
int32_t NovaSRTReceiveUnit(NovaSRTConnection*, uint8_t*, int32_t, char*, int32_t) { return 0; }
void NovaSRTDisconnect(NovaSRTConnection*) {}
void NovaSRTRetain(NovaSRTConnection*) {}
void NovaSRTRelease(NovaSRTConnection*) {}
void NovaSRTDestroy(NovaSRTConnection*) {}
#endif

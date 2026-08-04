#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NovaSRTConnection NovaSRTConnection;

// Creates a live-mode SRT caller. The receiver uses TSBPD and the same bounded
// ARQ latency as Iridium, so Wi-Fi jitter is absorbed here instead of reaching
// AVSampleBufferDisplayLayer.
NovaSRTConnection* NovaSRTConnect(const char* host, uint16_t port, int32_t latencyMs,
                                  char* error, int32_t errorCapacity);

// Returns a complete SRT message, 0 when disconnected, -2 on timeout, and -1
// on a transport failure.
int32_t NovaSRTReceive(NovaSRTConnection* connection, uint8_t* bytes, int32_t capacity,
                       char* error, int32_t errorCapacity);

// Reassembles the renderer's application fragments inside the native layer and
// returns one complete handshake/access unit. This avoids thousands of
// Swift/Objective-C++ crossings per second at 4K60.
int32_t NovaSRTReceiveUnit(NovaSRTConnection* connection, uint8_t* bytes, int32_t capacity,
                           char* error, int32_t errorCapacity);

// Safe to call from a different queue while Receive is blocked.
void NovaSRTDisconnect(NovaSRTConnection* connection);
// The media queue and MainActor each hold a reference while a connection is
// published. Explicit ownership prevents a disconnect callback from freeing a
// pointer that `stop()` is about to close.
void NovaSRTRetain(NovaSRTConnection* connection);
void NovaSRTRelease(NovaSRTConnection* connection);
void NovaSRTDestroy(NovaSRTConnection* connection);

#ifdef __cplusplus
}
#endif

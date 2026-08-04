#include "NovaSRT.h"

#include <libsrt/srt.h>
#include <netdb.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <vector>

struct NovaSRTConnection {
  std::atomic<SRTSOCKET> socket{SRT_INVALID_SOCK};
  std::atomic<int32_t> references{1};
  std::mutex socketMutex;
  std::array<uint8_t, 2048> packet{};
  std::vector<uint8_t> assembled;
  uint16_t sequence = 0;
  bool hasSequence = false;
};

namespace {

constexpr int kPayloadBytes = 1316;
void copyError(char* output, int32_t capacity, const char* message) {
  if (output == nullptr || capacity <= 0) return;
  std::snprintf(output, static_cast<size_t>(capacity), "%s", message != nullptr ? message : "SRT error");
}

void startLibrary() {
  static std::once_flag once;
  std::call_once(once, [] { srt_startup(); });
}

}  // namespace

NovaSRTConnection* NovaSRTConnect(const char* host, uint16_t port, int32_t latencyMs,
                                  char* error, int32_t errorCapacity) {
  startLibrary();
  if (host == nullptr || *host == '\0') {
    copyError(error, errorCapacity, "empty SRT host");
    return nullptr;
  }

  addrinfo hints{};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_DGRAM;
  char service[8]{};
  std::snprintf(service, sizeof(service), "%u", port);
  addrinfo* addresses = nullptr;
  const int resolved = getaddrinfo(host, service, &hints, &addresses);
  if (resolved != 0 || addresses == nullptr) {
    copyError(error, errorCapacity, gai_strerror(resolved));
    return nullptr;
  }

  SRTSOCKET socket = SRT_INVALID_SOCK;
  for (addrinfo* address = addresses; address != nullptr; address = address->ai_next) {
    socket = srt_create_socket();
    if (socket == SRT_INVALID_SOCK) continue;

    const int transtype = SRTT_LIVE;
    const int payload = kPayloadBytes;
    const int enabled = 1;
    const int latency = std::max(20, std::min(2000, static_cast<int>(latencyMs)));
    const int receiveTimeoutMs = 250;
    const int peerIdleMs = 5000;
    srt_setsockopt(socket, 0, SRTO_TRANSTYPE, &transtype, sizeof(transtype));
    srt_setsockopt(socket, 0, SRTO_PAYLOADSIZE, &payload, sizeof(payload));
    srt_setsockopt(socket, 0, SRTO_TSBPDMODE, &enabled, sizeof(enabled));
    srt_setsockopt(socket, 0, SRTO_LATENCY, &latency, sizeof(latency));
    srt_setsockopt(socket, 0, SRTO_RCVLATENCY, &latency, sizeof(latency));
    srt_setsockopt(socket, 0, SRTO_RCVTIMEO, &receiveTimeoutMs, sizeof(receiveTimeoutMs));
    srt_setsockopt(socket, 0, SRTO_PEERIDLETIMEO, &peerIdleMs, sizeof(peerIdleMs));

    if (srt_connect(socket, address->ai_addr, static_cast<int>(address->ai_addrlen)) != SRT_ERROR) {
      break;
    }
    srt_close(socket);
    socket = SRT_INVALID_SOCK;
  }
  freeaddrinfo(addresses);

  if (socket == SRT_INVALID_SOCK) {
    copyError(error, errorCapacity, srt_getlasterror_str());
    return nullptr;
  }

  auto* connection = new NovaSRTConnection();
  connection->socket.store(socket);
  return connection;
}

int32_t NovaSRTReceiveUnit(NovaSRTConnection* connection, uint8_t* bytes, int32_t capacity,
                           char* error, int32_t errorCapacity) {
  if (connection == nullptr || bytes == nullptr || capacity <= 0) return -1;
  // Reassemble all ~50 SRT fragments for a 4K access unit natively. Calling
  // through Swift once per fragment capped the Apple TV at about 39 fps and
  // let the SRT receive queue grow seconds late; this crosses that boundary
  // once per completed frame instead (roughly 60 calls/s).
  std::lock_guard<std::mutex> lock(connection->socketMutex);
  for (int packetCount = 0; packetCount < 512; ++packetCount) {
    const SRTSOCKET socket = connection->socket.load();
    if (socket == SRT_INVALID_SOCK) return 0;
    const int received = srt_recvmsg(socket, reinterpret_cast<char*>(connection->packet.data()),
                                     static_cast<int>(connection->packet.size()));
    if (received == SRT_ERROR) {
      int systemError = 0;
      const int code = srt_getlasterror(&systemError);
      if (connection->socket.load() == SRT_INVALID_SOCK) return 0;
      if (code == SRT_ETIMEOUT) return -2;
      copyError(error, errorCapacity, srt_getlasterror_str());
      return -1;
    }
    if (received < 4) continue;

    const uint16_t packetSequence =
        static_cast<uint16_t>((static_cast<uint16_t>(connection->packet[0]) << 8) |
                              connection->packet[1]);
    const uint8_t flags = connection->packet[2];
    if ((flags & 1) != 0) {
      connection->sequence = packetSequence;
      connection->hasSequence = true;
      connection->assembled.clear();
    }
    if (!connection->hasSequence || connection->sequence != packetSequence) {
      connection->hasSequence = false;
      connection->assembled.clear();
      continue;
    }
    connection->assembled.insert(connection->assembled.end(), connection->packet.begin() + 4,
                                 connection->packet.begin() + received);
    if ((flags & 2) == 0) continue;

    connection->hasSequence = false;
    if (connection->assembled.size() > static_cast<size_t>(capacity)) {
      connection->assembled.clear();
      copyError(error, errorCapacity, "SRT access unit exceeds client buffer");
      return -1;
    }
    const int32_t unitBytes = static_cast<int32_t>(connection->assembled.size());
    std::memcpy(bytes, connection->assembled.data(), connection->assembled.size());
    connection->assembled.clear();
    return unitBytes;
  }
  // Release the socket lock periodically even while packets are flowing, so a
  // stop/reconnect can never wait behind an indefinitely incomplete unit.
  return -2;
}

int32_t NovaSRTReceive(NovaSRTConnection* connection, uint8_t* bytes, int32_t capacity,
                       char* error, int32_t errorCapacity) {
  if (connection == nullptr || bytes == nullptr || capacity <= 0) return -1;
  // srt_close racing a blocked srt_recvmsg can dereference freed libsrt state
  // on 1.5.4. The receive timeout bounds this lock to 250 ms, after which a
  // disconnect can close deterministically.
  std::lock_guard<std::mutex> lock(connection->socketMutex);
  const SRTSOCKET socket = connection->socket.load();
  if (socket == SRT_INVALID_SOCK) return 0;
  const int received = srt_recvmsg(socket, reinterpret_cast<char*>(bytes), capacity);
  if (received != SRT_ERROR) return received;

  int systemError = 0;
  const int code = srt_getlasterror(&systemError);
  if (connection->socket.load() == SRT_INVALID_SOCK) return 0;
  if (code == SRT_ETIMEOUT) return -2;
  copyError(error, errorCapacity, srt_getlasterror_str());
  return -1;
}

void NovaSRTDisconnect(NovaSRTConnection* connection) {
  if (connection == nullptr) return;
  std::lock_guard<std::mutex> lock(connection->socketMutex);
  const SRTSOCKET socket = connection->socket.exchange(SRT_INVALID_SOCK);
  connection->assembled.clear();
  connection->hasSequence = false;
  if (socket != SRT_INVALID_SOCK) srt_close(socket);
}

void NovaSRTRetain(NovaSRTConnection* connection) {
  if (connection != nullptr) connection->references.fetch_add(1);
}

void NovaSRTRelease(NovaSRTConnection* connection) {
  if (connection == nullptr) return;
  if (connection->references.fetch_sub(1) == 1) {
    NovaSRTDisconnect(connection);
    delete connection;
  }
}

void NovaSRTDestroy(NovaSRTConnection* connection) {
  if (connection == nullptr) return;
  NovaSRTDisconnect(connection);
  NovaSRTRelease(connection);
}

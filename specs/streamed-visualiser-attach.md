# Streamed visualiser: attaching to the GPU renderer

The Apple TV draws the Phonoscope itself (Metal, A10X) until the stream from
`nova-visualiser` on iridium is delivering frames, then shows the stream
(`PhonoscopeView.usesStreamedRenderer` = `PhonoscopeStreamClient.hasPresentedFrame`).
Plan: `~/.claude/plans/we-re-working-on-the-lazy-heron.md`.

## Failure being fixed

On first load the picture often stayed on the local engine and never switched.
The local engine is much slower on this hardware, its dots and lines run at a low
frame rate, and its simulation clamps `dt` to 1/30 s, so it looks slow and
exaggerated next to the streamed picture.

Measured 2026-10-15/16 against iridium `/status`:

- With the TV stuck, `clientConnectionState` stayed `connecting` with 0 reconnects
  while iridium sent about 55 frames/s to one SRT client. The socket was healthy and
  nothing was ever presented.
- Cause: the SRT receive loop discarded every unit until it had seen the
  `NOVAVIS1` handshake, which the server sends once. SRT live mode drops late
  packets, so a lost handshake discarded the whole session.
- Second path: `startStreamingIfAvailable` asked `/api/phonoscope/renderer` once.
  One failed answer meant no stream for the rest of the visit.

## Required behaviour

1. **The handshake is optional on SRT.** Each unit is classified by its first 8
   bytes: `NOVAVIS1` is a header, anything else is an access unit. The format
   description comes from the header or from the in-band VPS/SPS/PPS of the next
   IDR, whichever arrives first. An access unit that arrives with no format
   description is skipped and a keyframe is requested (existing 0.5 s limit).
2. **Attach watchdog** (`PhonoscopeAttachWatchdog`):
   - no sample enqueued within 8 s of connecting: disconnect with
     `stalled: no header` or `stalled: no decodable frame`. 8 s because the
     renderer releases its GPU when nobody watches and wakes it after accepting;
   - once streaming, no sample for 3 s: `stalled: no frames`.
   The disconnect goes through the existing `handleSRTDisconnect` backoff, and the
   reason reaches iridium `/status` as `clientDisconnectReason`. TCP is unchanged.
3. **Renderer lookup retries** while the view is visible: 2, 4, 8, then every 10 s
   until `/api/phonoscope/renderer` answers `available: true`. The local engine
   stays on screen meanwhile. Cancelled when the view disappears.

## Done when

Ten close/reopen cycles on the real Apple TV each reach
`clientConnectionState: "streaming"` within 10 s with `clientDecodedFps` near 60,
and the picture runs at normal speed with the normal look.

## Not covered

The local fallback engine's frame rate and look. No change to `nova-visualiser`.

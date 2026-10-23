# High performance connection — experimental TestFlight integration

## 2026-10-21 audio completion and release evidence

Short AAC-ELD packet gaps now use a persistent native PCM decoder and bounded
waveform continuation/crossfade (maximum 40 ms). Longer gaps fade out and resume
at the original sender PTS; this does not reconstruct missing original audio.
Prepared chunks and the initial sample PTS survive renderer backpressure, so a
new sender report or partial enqueue cannot decode an AU twice. Reconnect clears
converter, pending output and concealment history.

- Full simulator suite: 31 XCTest + 19 Swift Testing tests passed (50 total).
- Native iPad AAC-to-PCM rendering test passed with skipped source AUs, exact
  subsequent PTS, rendering status and shared-clock advancement.
- Wire 480-frame ELD, initial priming, 10/20 ms gaps, 40 ms cap, long-gap reset,
  RTP wrap, partial backpressure and SR-anchor retries passed offline tests.
- Actual Mac 6016×3384 connection rendered video and continuously decoded the
  live 480-frame audio stream. At 1,500 enqueued AUs the decoder had processed
  719,968 frames and synthesized 5,771 gap frames, including one capped long gap,
  without a playback error. A subsequent manual reconnect also presented video
  and restarted PCM decoding. One earlier attempt lost the initial video frame
  and timed out. The client now retries that authenticated first-frame deadline
  once after awaiting UDP port release; cancellation, generation changes and
  authentication/trust/media errors are excluded. The retry policy regression passes.
- An independent review checked reference/decoder generations, audio retry
  identity, partial output, long-gap history and reconnect resets.

The high-performance connection remains explicitly experimental; standard VNC
is the default. Sustained audible flash/beep validation of this final build has
not been completed. Long network losses cannot be reconstructed, and sustained
video loss can still leave the experimental stream waiting for a clean keyframe.
This is an internal-test build, not a claim of loss-free playback.
Globe hardware validation is user-owned. The following sections preserve earlier
investigation evidence and must not be read as current unresolved code failures.


The previous prototype received authenticated SRTP but did not present a visible
frame. Its virtual-display request blanked the host and the user restored the
resolution manually. That request is not part of the new mirror bootstrap. The
old `--deskpad-hp-probe` still rejects before TCP. The isolated branch exposes HP only as an explicit experimental opt-in. Stable releases remain unchanged.

## Current isolated branch

`codex/hp-completion` includes the latest stable main, preserving Korean input,
scroll settings, remote cursor handling and large framebuffer behavior.
The opt-in mode (also available via DEBUG `--deskpad-hp-mirror`) uses no SetDisplayConfiguration or alternate
user session command. It verifies/pins the RSA key before sending credentials,
uses a bounded UDP queue, validates server media answers, handles control record
fragmentation/rekey, sends rate-limited SRTCP PLI, and aborts TCP on teardown.
The initial connection is marked connected only after a decoded frame is actually
presented. A startup deadline and authenticated-media inactivity timeout bound
failed sessions. Decoder failures terminate the connection rather than leaving
an apparently connected black screen. Video codec dimensions do not replace the
remote desktop's input coordinate space.

Two independently reproduced playback blockers are fixed: waiting for audio
before video startup, and rejecting an initial non-IDR H.264 intra picture.
All VCL slices must be validated as intra; arbitrary type-1 packets are not
accepted as keyframes. Late audio retains its independent sender-report clock.
The native synchronizer no longer waits for an empty audio renderer.

## Earlier recovery investigation (2026-10-21, before PCM concealment)

The following notes record the pre-PCM investigation. See the release evidence
above for the current implementation and remaining verification limits.

- Added bounded authenticated audio reorder/NACK and dual-port video feedback.
  The actual server has not retransmitted any observed missing packets yet.
- Added opt-in HEVC LTR negotiation, exact DON acknowledgements, a bounded RPS
  reference guard, and serial VideoToolbox decode completion before ACK. Native
  H264/HEVC 420/444 fixture tests and invalid-frame/no-ACK tests pass.
- Live single-bank HEVC offer with LTR enabled receives answer field 7 = 1 but
  field 2 = 0. Both parameter AP and contiguous VCL fragments lack DON. Thus no
  clean-frame acknowledgement is sent. The native two-bank offer produced the
  same no-DON result and is not enabled in the session. The answer parser now
  validates bounded capability lists separately from actual RTP codec selection.
- Native RPS validation now works without DON (never sending ACK). Actual 6K
  IDR and P pictures decoded successfully, missing-reference pictures were
  rejected, and later valid pictures resumed. Initial parameter/IDR loss is
  gated until a complete configured IDR arrives. Live first frame ~1.6 s.
- Separate audio 48kHz RR feedback reports loss/jitter with the correct audio
  SSRC/key/SR clock. Actual audio loss remains roughly 5%; retransmission has
  not been observed. Public AudioCodec AAC-ELD PLC probes returned no concealed
  frame, so no unsupported concealment behavior is claimed.
- Full simulator suite: 31 XCTest cases and 18 Swift Testing cases passed.
  Debug simulator and Release device compilation passed. The project now targets
  iPadOS 26 consistently with the runtime used for verification.
- These earlier checks alone did not establish sustained audible loss recovery.

## Verified on 2026-10-20

- Seven native iPad media tests pass: H.264 and HEVC 4:2:0/4:4:4 presentation,
  video-first startup, non-IDR intra-frame display, AAC-ELD decode and a delayed
  sender report with a coherent 120-frame HEVC chain. Startup buffering is bounded
  at 120 frames/12MiB and begins at the latest presentation time.
- 28 existing input XCTest cases passed on the same integration build.
- Offline media clocks, packet bounds, SRTP/SRTCP vectors, record encryption and
  rekey, native decoder, pipeline, bounded receive queue, control/answer parser,
  mirror handshake, lifecycle and server-trust harnesses passed.
- Independent review of credential verification, display-changing messages,
  failure propagation and initial encryption boundary; identified issues fixed.

## Remaining release acceptance

Live testing after unlock now authenticates against the saved remote Mac and
negotiates 6016×3384 HEVC (payload type 100). Authenticated audio and video RTP
and both sender reports arrive. H.264 at this canvas produced no video packets;
a separate local synthetic encoder probe also failed at 6016×3384 for H.264,
while HEVC succeeded. This is supporting evidence, not a remote encoder log.

The first live remote desktop was visibly presented at 22:46 KST after fixing
HEVC framing (this server omits DON) and replacing the 64-packet inbox with a
queue bounded by both 8192 packets and 12 MiB. Automatic framing selection now
requires a fully validated VPS/SPS/PPS aggregation packet. Remaining UDP loss
requires periodic startup keyframe requests; no packet loss is concealed. Seven native simulator tests pass including displayed HEVC 4:2:0 and
4:4:4, but do not establish real-host playback. Non-silent remote audio,
perceptual A/V sync, sustained playback and input remain unverified. Reconnect
results are recorded below.
No display configuration command is sent. Local display measurements are not
proof of the remote physical display state.

The observed answer does not provide a validated AAC AudioSpecificConfig; its
protobuf field 12 is opaque, not assumed to be ASC. Actual supported audio
negotiation must be verified before enabling this as a release feature. Multiple
video SSRCs/HEVC compositing and unsupported control encodings fail closed.
There is no validated protocol for restoring an altered physical display mode;
therefore virtual-display/curtain configuration remains excluded, not described
as repaired. Stable main/TestFlight remain unchanged until live acceptance passes.

## Latest live acceptance (23:08 KST)

- Actual remote 6016×3384 HEVC displayed; user also confirmed the picture.
- After fixing startup reference-frame retention, two consecutive in-app
  disconnect/reconnect cycles presented video in about 2–3 seconds. A later
  high-loss connection took about 12 seconds, so startup reliability is not a
  blanket pass for every network condition.
- Sustained packet loss remains observable even with zero app inbox overflow and
  confirmed 4MiB socket buffers. A bounded 60ms reorder/NACK window and 4096-packet
  authenticated replay window are integrated; live stream still sometimes waits
  for a fresh keyframe. Do not call sustained motion acceptance complete.
- Remote audio currently decodes to 480-frame silent PCM packets. The user has
  not played the flash/beep fixture yet. Audible output and perceptual A/V sync
  remain unverified. Local fixture is served only on the development Tailscale
  address, not bundled with the app or uploaded.
- Native HP encrypted pointer envelopes and remote cursor subscription are
  implemented, but live click acceptance is not established while the remote
  user is concurrently operating the machine.
- Draft PR remains the review artifact. No local main merge or TestFlight upload.

## Live user playback feedback (23:24–23:27 KST)

The remote host fetched the flash/beep fixture at 23:23:56. The user confirmed
hearing the beep both remotely and in the simulator, approximately aligned with
the flash, but with intermittent omissions. This is perceptual confirmation, not
a quantitative synchronization measurement or a sustained-playback pass.

The earlier zero-PCM inference is invalid: the diagnostic converter exhausted its
input with an EOF response and stopped decoding subsequent packets. Its cumulative
decoded-frame count stayed at 480. A silence-then-tone regression reproduced this
meter defect; a fix is being validated independently from actual playback.

The user subsequently reported missing video. The observed simulator desktop was
still visible with the test player at its black final frame (0:20/0:20); whether
the report refers to missing flashes or a frozen whole desktop needs clarification.
Frequent keyframe recovery remains a separate observed release blocker.


## 2026-10-21 follow-up acceptance

Hardware Shift press/end/cancel now reaches UIKit as well as the remote shortcut
path. Two routing regressions failed before and pass after the fix; 28 existing
input and nine IME cases pass. The session toolbar displays the active local iPad
input language, explicitly distinguished from the remote Mac input source.
Physical Globe/Shift acceptance remains pending: automation key events failed to
reach even the native reference UITextView. The separate Input QA simulator is
left open for a manual comparison; synthetic press tests are not hardware proof.

Successive video gaps now keep independent first-seen deadlines and NACK budgets,
and an expected repair packet is accepted before checking a full reorder queue.
Authenticated RTP reception now supplies real RTCP loss/jitter/LSR/DLSR reports,
with periodic sender reports. Regression vectors and the combined simulator build
pass. These changes have not eliminated live loss: a fresh actual-host connection
at 12:35 presented its first frame after approximately 12 seconds, then continued
to expire gaps without receiving repairs. UDP send failures, peer-filter drops,
and SRTP rejections were not observed. No main merge or TestFlight release.

Audio diagnostics now separately count late/preroll drops and renderer
backpressure, plus incoming sequence holes and timestamp discontinuities. In the
12:35 connection, 1178 preroll AUs were discarded during startup; after playback
started, late drops and backpressure remained zero during observation. A new
120-second synchronized flash/beep fixture awaits remote playback. Earlier user
feedback established intermittent audible output, not sustained acceptance.

The route to the remote host uses a 1280-byte tunnel MTU while observed media
packets can exceed it. Fragmentation loss is only a hypothesis: packet-header
capture is unavailable without BPF permission. No speculative MTU negotiation
field or physical-display configuration was added.


## 2026-10-21 14:14–14:18 keyboard UI verification

The automation focus issue is resolved: accessibility activation of the inner
simulator control did not change the host keyboard focus. A coordinate click
inside the simulated text surface delivers actual key events. In the native
reference view, Shift+A produced A after switching to English. In the production
RemoteDesktopUIView hosted by the isolated QA lab, Shift+A, b, Shift+C produced
exact outgoing text `AbC`. After switching the system input language to Korean,
individual hardware key events produced `한글 때 `, including Shift+E for ㄸ.
The production input-language callback reported en-US -> ko-KR. No pasted text or
synthetic UIPress stubs were used for these UI checks.

Physical Globe acceptance is still not complete: the automation key API rejects
both fn and Globe with keyNotFound. An attempted simulator-only Caps Lock-to-Globe
mapping cannot be configured because iPadOS exposes no modifier-key entries in
this simulated hardware environment. No modifier setting was changed. Switching
through the software keyboard proves input-mode handling but does not establish
physical Globe behavior. The QA lab is not part of release sources. Main merge
and TestFlight remain gated; existing media acceptance blockers also remain.

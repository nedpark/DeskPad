# Native synchronized compressed playback

`Tests/HighPerformancePlayback/run.sh` builds and runs offline native decoder tests and typechecks for the iOS 26 simulator. No speaker playback or network calls occur.

The factory converts complete H.264 Annex-B access units into AVCC CMSampleBuffers and AAC-ELD access units into compressed audio CMSampleBuffers. MPEG-4 AudioSpecificConfig is wrapped in ESDS descriptors: CoreAudio rejects the raw ASC as a magic cookie. CoreAudio determines actual sample rate, channel count and frame duration; it accepts the experimental Apple ASC `f8e65132e000` as 48 kHz stereo AAC-ELD with 480 frames/packet. Unsupported cookies fail closed.

`HighPerformancePlayback` attaches native audio and video renderers to one AVSampleBufferRenderSynchronizer. The caller must supply timestamps from authenticated Sender Reports, enqueue initial samples and explicitly start the common clock. Backpressure is returned to the caller; no unbounded queue is allocated. Reconnect requires resetting the factory, clock and playback. This does not depacketize RTP or negotiate a codec; HEVC is unsupported in this H.264 path.

Fixtures are locally generated black 64x64 H.264 and a 440 Hz AAC-ELD access unit:

```
ffmpeg -f lavfi -i 'color=c=black:s=64x64:r=1' -frames:v 1 -c:v libx264 -preset ultrafast -tune zerolatency -f h264 black.h264
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=0.1' -ac 2 -c:a aac_at -profile:a 38 -b:a 32k tone.m4a
```

The first AAC packet was extracted with ffprobe. Its generated ASC is `f8e64000`; the test decodes this actual packet with AudioToolbox and checks positive PCM output. VideoToolbox decodes the H.264 fixture to a 64-pixel-wide image. These establish native decoder feasibility; they do not prove playback of Apple server audio or perceptual A/V sync. No live screen content or recorded user audio is included.

The iOS simulator `HighPerformancePlaybackTests` also attaches a display layer to
an actual test window, presents a generated red H.264 frame without audio, checks
that decoded pixels are available and the common clock advances, and decodes the
synthetic AAC-ELD fixture to PCM. The embedded red fixture uses libx264 baseline,
64×64, yuv420p. Audio fixture ASC remains `f8e64000`; this does not validate the
Apple wire cookie, RTP audio framing, or perceptual synchronization.

Video starts after its own authenticated Sender Report even if the Mac is silent.
Audio waits for its independent Sender Report, retaining its NTP offset; obsolete
late audio preroll is dropped. Native renderer sufficient-data gating is disabled
because an empty audio renderer must not stall video. `hasDisplayedVideoFrame`
reports an actual displayed pixel buffer and is distinct from scheduled playback.

`intra-nonidr.h264` is an independently generated type-1 I picture plus SPS/PPS,
extracted from a seven-frame x264 stream with
`open-gop=1:keyint=2:min-keyint=2:scenecut=0:bframes=1:aud=1` at 64×64/30 fps.
A fresh native decoder and the simulator display layer both decode/present it.
The startup gate checks every VCL slice's bounded Exp-Golomb `slice_type` for I
(2 or 7), requires a slice beginning at macroblock zero, and rejects mixed P/I,
truncated headers and unsupported partitioned slices. This establishes decoding
of the intra picture itself, not arbitrary subsequent open-GOP dependency safety.

Simulator tests independently confirm that both four-byte payloads `00000000`
and `00683400` decode with ASC `f8e65132e000` to 480 zero-valued PCM frames.
Do not discard a payload solely because its size is four bytes. Reference protocol
notes describe PT101 as raw AAC-ELD-SBR without AU headers or RED; the observed
payload length alone does not distinguish source silence from a heartbeat.
These silence fixtures do not prove decoding of non-silent Apple server audio.

## Single-picture HEVC

`HighPerformanceMediaPipeline(..., videoPayloadType: 100, videoCodec: .hevc)`
explicitly selects HEVC. Payload type alone never selects the codec. The bounded
receiver accepts Apple DONL single NALs, APs (one DONL, no DOND), and FUs (DONL
in every fragment), with sequence/loss checks and 8 MiB/256 NAL limits. VPS/SPS/PPS
arrive in-band and create a native HEVC format description. BLA/IDR pictures start
playback; CRA/RASL recovery and multi-SSRC tiled compositing are unsupported and
must not be negotiated. Additional video SSRCs fail explicitly.

`Tests/HighPerformanceHEVC/run.sh` checks DON removal, AP/FU assembly, sequence
wrap/loss, malformed lengths, fragment DON mismatch, and the SR-gated pipeline.
`red.hevc` and `red444.hevc` are locally generated red64×64 x265 fixtures in
4:2:0 and4:4:4 respectively, with encoder metadata SEI removed. Generation:
`ffmpeg -f lavfi -i color=c=red:s=64x64:r=30 -frames:v 1 -c:v libx265
-x265-params log-level=error:pools=1 -pix_fmt yuv420p -f hevc red.hevc`
(use `yuv444p` for the other fixture). Actual iOS26.5 simulator display tests pass
for both profiles. This is not evidence of physical-iPad6K performance or of the
remote server honoring single-picture negotiation. No AGPL source was copied.

HEVC packetization defaults to automatic selection from the first complete,
authenticated VPS/SPS/PPS aggregation packet. Both candidate layouts (no DON at
offset2; Apple DON at offset4) must consume the exact packet extent with one valid
base-layer parameter set of each type. Exactly one candidate must succeed;
ambiguous or incomplete evidence is rejected. Selection remains fixed for the
SSRC across frames. The observed 88-byte no-DON AP had parameter lengths23/50/7
at offsets2/27/79, so unconditional Apple DON stripping corrupted this server.
Tests cover both layouts and subsequent single-NAL parsing without mode changes.

Startup retains a coherent IDR dependency chain for up to120 frames/12MiB while
waiting for the first Sender Report; steady-state buffering remains2 frames.
The clock starts at the newest buffered PTS, with older reference samples marked
DoNotDisplay and obsolete audio removed, so the wait is not added as permanent
latency. A generated120-frame64×64 HEVC chain (x265 bframes=0,keyint=240,aud=1)
is covered by an actual simulator delayed-SR display test. This small fixture
establishes queue/dependency behavior, not6K decode throughput or memory capacity.

The DEBUG PCM meter must not signal EOF between RTP packets. It requests exactly
one codec packet's PCM frames and returns a temporary-no-input status if the
converter asks for another AU. `tone-sequence.aac-au` contains30 length-prefixed
AAC-ELD AUs generated by `aac_at` from a0.3-second880Hz tone (48k stereo32kbps,
ASC f8e64000 /512frames). The regression feeds20 silent AUs then all30 tone AUs
through one persistent meter and checks advancing frame count and nonzero PCM.
The former EOF callback stopped after the first silent packet, falsely reporting
zero for the remainder of a live session; this diagnostic bug did not affect the
separate native audio renderer.

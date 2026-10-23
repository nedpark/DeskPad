# HP control / media answer fixtures

Run `python3 Tests/HighPerformanceAnswer/run.py`. The runner creates synthetic binary-plist / zlib / protobuf negotiation replies in a temporary directory. No captured session bytes or SRTP keys are checked in.

`AppleHPControlParser.append` consumes **decrypted bytes**, which may be partial messages or multiple messages. It frames status, Bell, plain clipboard, bounded known metadata rectangles, cursor, DesktopSize and rekey. Unknown opcodes and rectangle encodings fail closed. It does not decode framebuffer codecs, compressed clipboard, or unverified alternate answer schemas.

For a rekey event, install the returned 36-byte payload on the existing `AppleHPRecordCipher`, preserving its counters, **before decrypting another wire record**. The parser rejects rekey followed by additional bytes in that same plaintext segment or by remaining rectangles. Feed the cipher one encrypted record at a time; never decrypt a coalesced buffer across a rekey first.

Encoding 1010 has more than one schema. Version-2 / kind-2 replies have an 18-byte header after their u16 length, followed by three length-delimited binary plists (audio, video1, optional video2). Version-1 announcements remain opaque. Confirmed reply fields include stream SSRC, selected video payload type, and video width/height. Keys remain from the original offer; the reply contains no replacement SRTP keys.

Top-level protobuf field 12 is retained as `opaqueField12`, **not AudioSpecificConfig**. Observed bytes `08 04 20 04` do not establish AAC-ELD sample rate, frame size or ASC. These parameters must not be inferred from that field. Audio description scalar semantics are intentionally retained as opaque parsed fields.

The protocol document's little-endian offer flags contradict the existing offer builder's big-endian comment. This reply fixture contains a different status word and provides no evidence to resolve offer flags; changing the offer requires a separately justified integration decision.

## Wire evidence and limits

Offline protocol notes `/tmp/apple_vnc_rfc.md`, §10.3, identify the offer flags
word at +6 as host/little endian: `screensharingd`'s unswapped word load at
`0x10003ce84` forwards the value to the agent, which tests bits 1/2/4/8.
The builder regression test failed with `[0,0,0,5]` and passes with `[5,0,0,0]`.
Bit 1 advertises first-stream 60 fps support; negotiation success alone does not
prove the resulting frame rate. No keys or generated offer bytes are logged.

§8.2.1 specifies the 16-byte `0x1f` clipboard header. The parser bounds both
compressed and declared expanded sizes, frames across records, and emits an
opaque archive event. It does not decompress or apply clipboard contents.
§8.3 specifies 1104 STORE/SELECT framing; the SELECT regression verifies that
zero compressed bytes do not swallow the next message.

1011 remains unsupported: §8.9.4 describes a u32-length TCP DCT codec, whereas
reference proxy comments describe a u16-length sibling of 1010. This conflicting
evidence is insufficient to safely guess framing. Do not advertise 1011 until
its relevant wire variant and decoder are validated. No live connection was
used for these checks.

## Live integration correction

The runtime reference negotiation.py (build_0x1c) contradicts the older RFC notes: the agent IPC/NDR boundary swaps the flags, so the wire builder uses big-endian 00000005. The original LE fixture was a mistaken inference from the daemon load alone. The integration now preserves BE and tests those bytes. Both byte orders negotiated an answer during live trials, but neither alone produced 6K H.264 video; successful answer parsing is not proof of requested frame rate. Native encoder comparison separately reproduced H.264 failure at 6016-pixel width.

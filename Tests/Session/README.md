Run from the repository root on macOS with Xcode command line tools installed:

```sh
python3 Tests/Session/run.py
```

The runner compiles the actual session model and transport with `swiftc`, opens loopback TCP listeners, and exercises RFB 3.8 exchanges. It needs no app test target, simulator, external VNC service, or Python packages. The first-frame deadline case takes about 21 seconds each; the full suite takes about 100 seconds. Use `--quick` to omit the slow Raw case and three deadline cases.

A delayed 4 MiB Raw payload takes over 20 seconds and must still connect with exact pixels. Raw reads use a fixed 20-second allowance plus one second per MiB, capped at 120 seconds; only validated nonempty Raw headers can replace the initial 20-second first-frame deadline. Continuous payload trickle does not renew the budget.

Coverage includes empty updates before first pixels, exact pixel conversion, reconnect while a read is pending, model deallocation during an active read, rejected framebuffer bounds, terminal errors followed by late network activity, an independent first-frame deadline despite continuous bells, empty updates, zero-area Raw rectangles, or repeated DesktopSize messages, Latin-1 clipboard receive/send and Unicode refusal, RFB 3.5 fallback to 3.3 with verified DES authentication and SecurityResult consumption, and 50 ordered key-down/key-up pairs. A resize regression holds Control and a pointer button, waits for DesktopSize, verifies new presses are refused while release events reach the server, and receives the next Raw frame. Bounded state predicates and explicit first-frame/input acknowledgments avoid depending on machine-speed sleeps. Apple authentication is checked against an RFC 2409 group with a known server exponent: Python derives the shared secret from the transmitted client public key, and system OpenSSL decrypts and checks the credentials. A rejected Apple authentication result without a reason string must fail promptly. The server harness propagates unexpected EOF and requires every assertion to complete. This validates the production Montgomery implementation and fixed-width secret encoding without exposing production private keys.

The clipboard deliberately uses classic RFB Latin-1 and reports a nonfatal `clipboardError` for unsupported text. Extended Unicode clipboard is not negotiated. Cursor and XCursor pseudo-encodings are negotiated independently of framebuffer compression. The tests do not claim encrypted transport or server identity verification; classic RFB and Apple screen-sharing authentication retain their protocol properties.

Server termination cases cover clean EOF while connected, a TCP reset, and EOF midway through the initial Raw payload. Each requires a distinct ended state with cleared frame/dimensions/clipboard, rejects input after termination, reconnects on a new TCP connection, and verifies fresh input reaches that connection. Locally triggered response/first-frame deadlines retain the failed state; they are not presented as server termination. No automatic reconnect is attempted. These loopback tests do not identify why a real server stopped sharing or detect a silent network blackhole.

## Compressed frames and pixel conversion

`python3 Tests/Session/run-zrle.py` builds the production decoder with optimization; add `--debug` for an unoptimized benchmark. Python's independent zlib compressor supplies all ZRLE tile modes, row padding, 65×65 edge tiles, persistent-stream rectangles, invalid palettes/runs, oversized/truncated data, a compression bomb, and expired/in-progress decode budgets. Synthetic 6016×3384 solid and incompressible frames verify the complete RGBA output (SHA-256 for noise) and measure decoding. The Raw benchmark compares every output byte with the previous conversion and checks an inset rectangle's unaffected neighbors.

The TCP suite now verifies preferred ZRLE negotiation, persistent rectangles, malformed ZRLE bounds/length/palette/bomb rejection, and a fixed stalled-payload timeout. Raw remains advertised and all original Raw tests run. ZRLE uses a single persistent zlib stream per connection, 64×64 tiles, and three-byte BGR CPIXELs for the client's negotiated pixel format. The [RFB protocol specification](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst#zrle-encoding) and [RFC 6143](https://datatracker.ietf.org/doc/html/rfc6143) define the format. Real Mac support is established by observing encoding 16 on that server, not assumed from the standard.

Compressed receive length is bounded by rectangle size and a 128 MiB absolute limit. Inflated bytes are bounded by the worst legal tile payload, and decode checks the same fixed receive deadline during inflate and tile processing. No progress or repeated message renews a payload budget. DEBUG logs include only sizes, rectangle counts, and receive/decode/update timings.

## Input latency and ordering

Run `Tests/Session/run-input-queue.sh` for deterministic suspended-transport tests.
A 4,000-movement burst must retain only the latest pending motion between button
edges, keys, clipboard commands and wheel events. The harness also checks that
cancellation removes pending input, an old suspended sender cannot drain a new
session, and a suspended send does not retain the queue owner.
## Color depth and interactive TCP

`VNCSessionModel.connect(..., colorQuality:)` selects one of two formats for the lifetime of a connection: `.fullColor` (RGB888 in 32-bit words) or `.lowLatency` (RGB565 in 16-bit words). The API default preserves full color; the interface selects the user's preference explicitly. ZRLE CPIXELs are respectively 3 or 2 bytes; Raw uses 4 or 2 bytes. RGB565 deliberately reduces color precision while output storage stays RGBA. Reconnecting is required to change quality so no old compressed stream is interpreted with a new format.

The target Mac accepted RGB565 but reset the connection for both native 8-bit RGB332 and 32-bit-padded RGB332. Neither RGB332 variant is offered by the quality API or retried automatically. Their codec-only tests remain as format coverage. The TCP RGB565 case checks exact SetPixelFormat bytes, asymmetric channel values, and subsequent Raw fallback. Decoder fixtures repeat raw/solid/packed-palette/RLE/edge/persistent-stream and malformed cases at reduced depths. Raw conversion tests exhaustively check all 65,536 RGB565 and 256 RGB332 values (including nonzero padding) against independently rounded color components. Latency depends on screen contents and network/server conditions.

TCP `noDelay` disables Nagle buffering for small interactive input events ([Apple API documentation](https://developer.apple.com/documentation/network/nwprotocoltcp/options/nodelay)). No measured millisecond gain is attributed to that flag alone. No server helper, proprietary streaming codec, or server scaling command is added. The standard SetDesktopSize extension requires prior ExtendedDesktopSize support and may change the shared desktop layout; it is separate from color-depth negotiation.

Cursor protocol regression: `python3 Tests/Session/run.py --case=cursor` verifies
negotiation, a cursor before the first framebuffer, explicit hidden cursor,
XCursor updates without republishing the framebuffer, and disconnect cleanup.
The decoder fixture can be run separately:

```sh
swiftc -parse-as-library DeskPad/VNC/RFBZRLEDecoder.swift DeskPad/VNC/RFBCursorShape.swift Tests/Session/CursorHarness.swift -o /tmp/deskpad-cursor-tests
/tmp/deskpad-cursor-tests
```

Cursor formats follow https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst
(Cursor and X Cursor pseudo-encodings). Server support is optional; advertising
these encodings alone does not establish that a particular Mac sends shapes.

`--case=apple-cursor` covers Apple CursorImage (0x450) STORE/SELECT wire
framing, unknown cache references, following message alignment, and unchanged
framebuffer revision. The decoder uses an independent bounded zlib stream per
STORE and caches at most 64 shapes / 16 MiB per connection. Pixel data is BGRA
plus a separate alpha plane, independent of the negotiated framebuffer depth.
For servers advertising Apple's 3.889 banner, the client negotiates 3.889,
sends ClientInit C1 and ViewerInfo, and advertises only cached Apple cursors.
The test asserts those exact handshake bytes and consumes a bounded status
heartbeat before cursor updates. Other VNC servers keep the standard handshake
and Cursor/XCursor encodings. No encrypted record layer, virtual display, or
automatic framebuffer streaming is enabled. Live Mac QA observed 1104 STORE and
SELECT updates using this combination; see the main live-QA report for UI checks.

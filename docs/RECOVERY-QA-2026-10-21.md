# Network recovery and app switching — 2026-10-21

## Implementation

- One explicit connection owns a maximum of three automatic retries, delayed 1/2/4 seconds. A successful retry does not refill the budget. Close invalidates pending callbacks and clears in-memory connection intent.
- Established sessions recover after transient network errors, all-media idle timeout, or active video with no clean native decode progress. Authentication, trust, invalid protocol and unsupported media errors remain terminal.
- Active video requires advancing RTP timestamps and a previously successful native decode; static/idle desktops do not trigger the eight-second progress guard.
- Inactive/background sessions mute audio and release keyboard state. Background execution has a maximum 20-second grace and may expire earlier at iPadOS discretion. Short foreground return retains a healthy session; expiration retires transport and foreground automatically reconnects.
- Foreground return also checks video flush-required / failed and audio failed states. Suspended-renderer failure in the background defers recovery until foreground, using the same bounded retry budget.
- No indefinite background entitlement, silent-audio keepalive, Mac helper or OS network changes.

## Actual native Mac + iPad simulator evidence

Debug build b4a78ef, Mandu Store iPad (iPadOS 26.5), native Mac Screen Sharing at 6016×3384. Loss injection discards incoming media/RTCP only in this Debug app process; it is not present in Release.

1. **20-second receive blackout and automatic recovery: PASS.** PID 50711 displayed its first decoded frame at 19:11:43.129 KST. Loss started 19:11:46.923 and ended 19:12:06.931. All-media timeout at 19:12:01.944 triggered retry 1. Its first-frame timeout triggered retry 2 at 19:12:18.449. Fresh PCM and decoded video resumed at 19:12:25.267/19:12:25.334 without user reconnect. A UI screenshot confirmed the remote Mac shield screen was visibly rendered, rather than a black canvas.
2. **Long app switch: PASS.** Home at 19:12:43.194 began grace; 19:13:03.429 retired transport (20.235 seconds). Foreground at 19:13:19.927 automatically resumed; fresh PCM/video appeared at 19:13:22.034/19:13:22.097.
3. **Short app switch: PASS.** Background 19:13:42.656 → foreground 19:13:48.851 (6.195 seconds). Existing PCM counters continued 2500 → 3000 with no new connection attempt or new first-frame event.
4. **5-second receive blackout: audio stream resumed.** PID 51350 lost media 19:14:20.223–19:14:25.224; PCM continued at 19:14:26.144. The remote screen was static/shielded, so this does not independently establish moving-video recovery from a short loss.
5. Explicit Close returned to the connection list; cancellation/generation invalidation is also covered by the deterministic recovery harness.

Evidence log: `/tmp/deskpad-recovery-realhost.log`. Build: `/tmp/deskpad-recovery-build.log`.

## Automated validation

- Simulator suite: 31 XCTest + 20 Swift Testing tests passed, zero failures (`/tmp/deskpad-recovery-tests.log`). Includes native H.264/HEVC decoding and input regressions.
- `Tests/SessionRecovery/run.sh`: PASS (retry budget, startup/auth exclusions, deferred background failure, pause/short-return, cancellation/stale generation).
- `Tests/HighPerformanceVideoProgress/Harness.swift`: PASS (active stall, clean progress, static idle, reset, bounded one-shot injection).
- Signed simulator Debug build: PASS.
- Final renderer-resume hardening f1d795d: all 51 simulator tests and recovery policy harness passed again (`/tmp/deskpad-recovery-final-tests.log`). Final live reconnection at 19:19 was blocked by remote port 5900 timing out independently with `nc`; the app surfaced a connection timeout. The earlier real-host loss/lifecycle results are for b4a78ef, before this narrow renderer-state hardening.

## Limits

Physical iPad suspension timing, Wi-Fi/cellular handover and force-quit/relaunch are not verified by a simulator. Automatic resume preserves intent only while the process remains alive. Retry stops after three failed attempts and exposes manual retry. This run verifies audio transport/PCM recovery, not a fresh audible flash/beep synchronization test.

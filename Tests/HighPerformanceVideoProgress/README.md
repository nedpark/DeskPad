# Active-video recovery guard

Run from the repository root:

```sh
swiftc -D DEBUG -parse-as-library DeskPad/AppleHPVideoProgressWatchdog.swift Tests/HighPerformanceVideoProgress/Harness.swift -o /tmp/hp-video-progress
/tmp/hp-video-progress
```

The guard requires a prior successful native video decode and continuing authenticated video RTP with advancing timestamps. Eight seconds without another successful decode signals `AppleHPFailure.videoStalled`. More than two seconds of video packet inactivity resets the active interval; idle desktops do not reconnect. The existing independent first-frame and all-media-idle deadlines still apply. The model decides the retry budget.

For an isolated simulator test, launch a Debug build with `--deskpad-hp-drop-after=5 --deskpad-hp-drop-for=5`, connect in HP mode, and play a moving test surface. All incoming media and RTCP are locally discarded during this single process-wide window. Replacements reuse the same expired window rather than repeatedly injecting loss. To exercise the all-media-idle timeout, use a duration above 15 seconds. Values are finite seconds within 0...60; missing/invalid/zero-duration settings disable injection. Release builds contain no injector.

Policy and injection tests are deterministic. Actual network/reconnect verification must additionally confirm a newly displayed frame after the loss window; passing these tests alone does not establish real-host recovery.

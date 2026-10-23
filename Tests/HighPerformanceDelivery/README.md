# Decoupled video ingress

```sh
swiftc -swift-version 6 DeskPad/AppleHPVideoDeliveryQueue.swift Tests/HighPerformanceDelivery/Harness.swift -o /tmp/deskpad-hp-delivery-test
/tmp/deskpad-hp-delivery-test
```

The fixture suspends a decoder callback indefinitely and verifies that ingress
can still enqueue subsequent packets and return immediately. Releasing it proves
FIFO delivery; capacity overflow and closing during suspension are also checked.
The real transport uses this same queue. One worker preserves pipeline ordering;
no detached task is created per packet. Queue memory is independently bounded at
8192 packets and 12MiB, plus one in-flight packet. Consumed entries release their
Data immediately; periodic array compaction avoids O(n) removal per packet.

Previously the sole UDP reader awaited every decoder operation. A 60ms reorder
timer could expire while the missing packet was already waiting in the inbox.
Now authenticated video ingress only awaits a short queue operation, not decoder
completion. Audio and sender-report handling retain their existing scheduling.
This removes a local false-loss mechanism but does not prove WAN loss or RTT is
below the unchanged repair deadline. DEBUG queue current/peak packet and byte
counts allow a live comparison without recording content. No host configuration
or latency/repair timeout changes are included.

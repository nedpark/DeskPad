# Native HP pointer envelope

```sh
swiftc -swift-version 6 DeskPad/HighPerformance/AppleHPRecordCipher.swift Tests/HighPerformancePointer/Harness.swift -o /tmp/deskpad-hp-pointer-test
/tmp/deskpad-hp-pointer-test
```

Wire facts: HP pointers use inner type0x10 plus one AES-128-ECB block, followed
by the existing outer authenticated control record. The 16-byte inner plaintext
is ten timing/padding zero bytes, sentinel0xff, button mask and two BE unsigned
16-bit desktop coordinates. Inner encryption uses the current control key after
rekey. No key is exported from the cipher. Existing standard VNC retains its
six-byte type0x05 message. Keyboard type0x04 remains unchanged.

The independent test decrypts both layers, checks exact plaintext at unsigned
coordinate/button boundaries, exercises several sequential records and a rekey,
and rejects use before key installation. No live input is sent. Protocol facts
were checked against the reference input controller; its implementation was not
copied. The reference identifies cursor-tracker side effects on type0x10; this
change is not proof that all prior input failures were caused by type0x05.

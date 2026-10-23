# HP session lifetime regression

Run without a remote connection:

```sh
swiftc -swift-version 6 DeskPad/AppleHPSessionLifecycle.swift Tests/HPLifecycle/Harness.swift -o /tmp/deskpad-hp-lifecycle-test
/tmp/deskpad-hp-lifecycle-test
```

Covers startup timeout, presentation cancelling the timeout, terminal-session
reuse rejection, idempotent ordered cancellation, and rejection of display
mutation when no verified restoration implementation exists.

Integration requirements:

- Create a lifecycle for every attempt, call begin before network startup.
- Supply nonblocking cancellation closures; control closure must call
  `NWConnection.forceCancel()` (abortive TCP close), not merely cancel a reader.
- Stop on user disconnect, background, error, peer close, and parent cancellation.
- Call presentationConfirmed only after actual output presentation is established.
  Authentication, received media, enqueued buffers, or pipeline.isPlaying alone
  do not prove a frame was shown or sound was rendered.
- Call validateDisplayPolicy before any 0x1d display configuration or curtain path.
  Current implementation intentionally rejects these operations. A baseline RFB
  size cannot restore the physical screen's mode, identity, scale, or arrangement.

Protocol evidence, investigated read-only:

- Local reference `src/isharescreen/proxy/session.py`,
  `_teardown_negotiation_tcp` and `close`, uses SO_LINGER {1,0} then close
  (TCP RST). Its comments report native-client no-goodbye behavior and a long
  FIN teardown delay. This justifies abortive close, not a claim of restoration.
- `src/isharescreen/proxy/protocol/rfb.py:build_virtual_display` constructs
  0x1d virtual-display creation/resize. It does not provide a documented physical
  display restoration message or a verified count-zero removal operation.
- Existing live prototype altered host display state and did not establish
  restoration after termination. Therefore this change neither sends invented
  rollback packets nor claims the host is restored when local cleanup finishes.

Source reference is AGPL; implementation here is independently authored from
protocol facts, using no copied implementation. No live-host test was performed.

## Mirror-only bootstrap

```sh
swiftc -swift-version 6 DeskPad/AppleHPMirrorHandshake.swift Tests/HPLifecycle/MirrorHarness.swift -o /tmp/deskpad-hp-mirror-test
/tmp/deskpad-hp-mirror-test
```

ClientInit 0xC1 is used by both mirror and curtain sessions. The reference's
`protocol/negotiation.py:_phase_handshake_plaintext` enables curtain by sending
0x1d SetDisplayConfiguration; the `curtain=False` branch skips that message.
The mirror builder preserves ClientInit, ViewerInfo, encryption setup and caller
selected encodings, with no display mutation API. Its wire profile constants
are compatibility identifiers, not a claim that DeskPad is Screen Sharing.app.
This is code/protocol evidence; mirror playback has not been live-validated.
Do not infer that merely omitting display configuration proves host invariance.

## Server identity integration

AppleHPAuthentication.verifyKey runs immediately after RSA DER parsing and
before wrapping/sending credentials. Never replace it with an empty closure.
The app's current CredentialKeychain stores passwords; there is no existing
server-pin confirmation UI. Add a separate Keychain service for HP server pins,
keyed by normalized connection endpoint (host plus port, not resolved IP and not
username). Hash the server's validated DER with SHA-256 and compare exactly.

On first contact, present host/port and fingerprint and suspend authentication
until explicit user trust or cancellation. This is trust-on-first-use, not
independent proof of identity. For changed keys, stop authentication and show old
and new fingerprints; never silently overwrite a saved pin. A successful user
approval persists the exact observed key hash before authentication continues.
Use connection-generation identity so a late approval cannot trust a subsequent
connection. Do not log DER or credentials. Pin trust must be revocable separately
from password deletion. Password presence is not consent to trust an unseen key.

## Server pin helper

```sh
swiftc -swift-version 6 DeskPad/AppleHPServerTrust.swift Tests/HPLifecycle/TrustHarness.swift -o /tmp/deskpad-hp-trust-test
/tmp/deskpad-hp-trust-test
```

`AppleHPServerTrust.inspect(der:host:port:)` returns `.trusted` or
`.approvalRequired(Challenge)`. The UI must display the challenge endpoint and
fingerprint, then call `approve(challenge)` only for an explicit acceptance in
the same live connection generation. On rejection/disconnect, call `cancel`.
The helper rejects superseded challenges and changed stored keys, and writes
pins through an insert-only Keychain operation to prevent competing approvals
from overwriting one another. A changed key has no automatic approval path.

The store is injected in the harness; tests do not modify the user's Keychain.
DER must already have passed the authentication helper's RSA parser. Pins use a
separate non-synchronizing, device-only Keychain service. Account is SHA-256 of
normalized host plus port; value is SHA-256 of DER. Password records are untouched.
No key material, credentials, or fingerprints are logged by the implementation.

# Transient Korean glyph discrepancy: diagnosis pending

The user reports that a physical keyboard attached to the iPad correctly types
`때`, but the iPad view shows only `ㄷ` while composition is active. The vowel or
composed syllable becomes visible after commitment. The physical Mac displays
the correct text during composition.

This is not yet a reproduced or fixed defect. Do not infer that keyboard
composition is incorrect merely from the iPad rendering discrepancy.

## Instrumentation in this branch

DEBUG builds log callback kind, callback count, UTF-16 length, ASCII/non-ASCII
scalar counts, and UIKit's current input-language identifier for insertText,
setMarkedText, and unmarkText. No text, scalar values, key values, passwords,
clipboard contents, hostnames, or document identifiers are logged. Release
builds omit the helper and calls entirely. No composition preview or refresh requests have been added. The separate
Backspace routing correction below changes input behavior.

UIKit's input language identifies the local input mode; it does not identify
the remote Mac's input source. A physical-keyboard event alone does not prove
which device performs the actual composition.

## Evidence and next bounded observation

Existing tests exercise manually invoked UITextInput callbacks; they do not
establish the event sequence produced by this physical keyboard. Current code
keeps marked text local and sends Unicode key events on commitment. A synthetic
sequence leaving earlier committed text visible during local composition would
also leave the Mac behind, so it cannot explain the user's simultaneous Mac
versus iPad discrepancy on its own.

A separate offscreen UIKit experiment used the observed 6016-to-2188 fit ratio
(0.364). The current non-tiled view matched bilinear output pixel-for-pixel and
differed from explicitly nearest-neighbor output. It did not reproduce this
transient glyph error. The explicitly nearest-neighbor path above 8192 pixels
was not tested. This argues against assuming a nearest-neighbor defect for the
observed 6K session.

The remote desktop was being actively used during the attempted live check;
focus changed and a controlled observation could not be completed. Do not claim
that attempt reproduced the bug.

Next, observe one composition in an agreed test field while these counters run.
Correlate local callbacks with the existing input-send/frame-update diagnostics.
If local marked callbacks are absent and ASCII events are sent, investigate the
Mac-side IME capture path. If local marked callbacks are present, establish their
actual ordering without logging text. A later, explicitly controlled one-shot
nonincremental refresh can distinguish stale incremental damage from a remote
composition layer that is absent even in a full capture. Do not make repeated
full-frame refreshes a production workaround without that evidence.

No merge, TestFlight release, or host configuration change is included.

## Reproduced hardware Backspace defect (separate from display report)

In the isolated local Input QA simulator, physical key presses with Korean
input produced insertText/deleteBackward replacements, with no setMarkedText.
Native UITextView and DeskPad both correctly entered 할때, 쌍자음, 때때,
까께꼬, 됐, and 입력할때. Backspace exposed a distinct mismatch:

| Physical sequence | Native UITextView | DeskPad before | DeskPad after |
| --- | --- | --- | --- |
| Shift+e, o | 때 | 때 | 때 |
| Backspace | ㄸ | empty | ㄸ |
| o | 때 | ㅐ | 때 |

Plain and Shift+Backspace now pass to UIKit even without marked text. UIKit can
remove one composing jamo and emit its replacement; deleteBackward still sends
remote Backspace when no local composition exists. Ctrl/Alt/Cmd shortcuts retain
the direct path. The after column was verified with physical pressKey events,
observing the wire text after each key. Unit coverage checks routing, both
key-down/up ordering for the observed replacement sequence, and remote deletion
without locally retained text.

This fixes a demonstrated deletion/recomposition defect. It does not establish
the cause of the original transient Mac-versus-iPad display discrepancy.

Boundary testing then exposed retained UIKit Korean composition after direct
Left-arrow and pointer-click events. With the Backspace correction alone,
`때 → Left/click → Backspace → o` incorrectly decomposed/recomposed the old
syllable. Notifying the input delegate through unmarkText before non-Shift
direct keys and new pointer-button presses clears that stale context. Physical
simulator verification now shows a plain delete callback followed by `ㅐ`,
matching native navigation behavior. A focus-away/back cycle also passed.
Hover, held-button motion, wheel events, and button releases do not reset IME.

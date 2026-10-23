# Optional single-picture HEVC offer

`AppleHPMediaOffer.make(videoProfile: .hevcSinglePicture)` emits one codec bank:
identifier 100, two resolution variants, bank selector 14 and the associated
AVC-labelled parameter string. The identifier/name mismatch is deliberate:
reference runtime observations map bank100 to HEVC output and bank123 to AVC.
This implementation was independently assembled from those wire-field facts.

Both profiles set VideoSettings field6 (tilesPerFrame) to1 and disable LTR.
The reference defaults HEVC to4, but explicitly allows field6 override1 and
states that the server honors it. This establishes a concrete requested profile,
not proof that every Mac will honor it or every iPad will decode its chroma format.
The media answer's video description field6 is the negotiated tile count; reject
anything other than1 in a single-picture renderer. Root parser already allows
payload100, but transport/pipeline must select HEVC explicitly and validate the
actual NAL/SPS format. A successful 6K encoder creation is not a decoder test.

No host display geometry or scaling request is added. Header flags remain BE5
because the runtime reference documents the agent IPC byte swap; the RFC's
host-load-only LE interpretation is contradicted by its runtime observations.

`python3 Tests/HighPerformance/run-offer.py` independently parses both generated
Swift offers through plistlib, zlib and a Python protobuf decoder. It verifies
bank identifiers, selector/count, single picture, disabled LTR, audio profile,
header framing and fresh random keys. No network or Keychain access occurs.

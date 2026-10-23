#!/usr/bin/env python3
"""Independent protobuf/plist decoder verifies Swift-generated media offers."""
import base64, pathlib, plistlib, struct, subprocess, tempfile, zlib
root = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='deskpad-offer-') as tmp:
    binary = str(pathlib.Path(tmp) / 'offer')
    subprocess.run(['swiftc', '-parse-as-library', '-warnings-as-errors', str(root/'DeskPad/HighPerformance/AppleHPMediaOffer.swift'), str(root/'Tests/HighPerformance/MediaOfferHarness.swift'), '-o', binary], check=True)
    lines = subprocess.check_output([binary], text=True).splitlines()

def decode(data):
    pos, fields = 0, {}
    def varint():
        nonlocal pos
        result = shift = 0
        while True:
            b = data[pos]; pos += 1
            result |= (b & 127) << shift
            if b < 128: return result
            shift += 7
            assert shift < 70
    while pos < len(data):
        key = varint(); field, wire = key >> 3, key & 7
        if wire == 0: value = varint()
        else:
            assert wire == 2
            count = varint(); value = data[pos:pos+count]; pos += count
        fields.setdefault(field, []).append(value)
    assert pos == len(data)
    return fields
for profile, expected_type, variants, selector in [(0, 123, 4, 1), (1, 100, 2, 14), (2, 100, 2, 14), (3, 100, 2, 14)]:
    profile_lines = lines[profile*3:profile*3+3]
    packet = base64.b64decode(profile_lines[0])
    assert packet[:2] == b'\x1c\0'
    u16 = lambda n: struct.unpack_from('>H', packet, n)[0]
    assert u16(2) == len(packet)-4 and u16(4) == 3
    assert packet[6:10] == b'\0\0\0\5'
    audio_len, video_len = u16(10), u16(12)
    assert u16(14) == 0 and packet[16:20] == bytes(4)
    assert len(packet) == 220 + audio_len + video_len
    assert len(set((packet[36:82], packet[82:128], packet[128+audio_len:174+audio_len], packet[174+audio_len:220+audio_len]))) == 4
    for video, data, ssrc in [(False, packet[128:128+audio_len], int(profile_lines[1])), (True, packet[220+audio_len:], int(profile_lines[2]))]:
        plist = plistlib.loads(data)
        assert plist['avcMediaStreamNegotiatorMode'] == (7 if video else 8)
        endpoint = decode(plist['avcMediaStreamOptionRemoteEndpointInfo'])
        assert endpoint[3] == [b'DeskPad']
        blob = decode(zlib.decompress(plist['avcMediaStreamNegotiatorMediaBlob']))
        assert blob[6] == [b'DeskPad 1.1'] and len(blob[9]) == 10
        desc = decode(blob[5 if video else 3][0])
        assert desc[1] == [ssrc]
        if video:
            assert desc[2] == [1], "video RTCP feedback must be negotiated for NACK recovery"
            assert desc[6] == [1] and desc[7] == [1 if profile >= 2 else 0]
            assert len(desc[3]) == (2 if profile == 3 else 1)
            if profile == 3:
                alternate = decode(desc[3][0])
                assert alternate[1] == [123] and alternate[4] == [1]
                assert len(alternate[2]) == 4 and b'LTR;' in alternate[3][0]
            codec = decode(desc[3][-1])
            assert codec[1] == [expected_type] and len(codec[2]) == variants and codec[4] == [selector] and b'LTR;' not in codec[3][0]
        else:
            assert desc[2] == [0] and desc[4] == [24191]
print('PASS: independent H264/HEVC single-picture offers, fresh keys, BE flags, explicit HEVC LTR only, unchanged audio')

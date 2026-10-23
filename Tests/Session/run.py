#!/usr/bin/env python3
"""Standalone real TCP RFB regression suite; no simulator or test target needed."""
import pathlib, socket, struct, subprocess, sys, tempfile, threading, time, zlib
root = pathlib.Path(__file__).resolve().parents[2]
binary = pathlib.Path(tempfile.mkdtemp(prefix='deskpad-session-')) / 'session-tests'
subprocess.run(['swiftc', '-parse-as-library', str(root/'DeskPad/Connections/ConnectionStore.swift'), str(root/'DeskPad/VNC/VNCSession.swift'), str(root/'DeskPad/VNC/RFBCursorShape.swift'), str(root/'DeskPad/VNC/RFBInputQueue.swift'), str(root/'DeskPad/VNC/RFBZRLEDecoder.swift'), str(root/'Tests/Session/Harness.swift'), '-o', str(binary)], check=True)
def exact(c,n):
    out=b''
    while len(out)<n:
        part=c.recv(n-len(out))
        if not part: raise EOFError()
        out+=part
    return out
def expect_closed(c, message):
    try:
        assert c.recv(1)==b'', message
    except ConnectionResetError:
        pass  # A fail-closed transport may abort instead of sending a FIN.
errors=[]
def serve_disconnect(listener, mode, marker):
    for attempt in range(2):
        c, _ = listener.accept()
        with c:
            c.settimeout(7)
            c.sendall(b'RFB 003.008\n'); assert exact(c,12)==b'RFB 003.008\n'
            c.sendall(b'\x01\x01'); assert exact(c,1)==b'\x01'
            c.sendall(b'\0'*4); exact(c,1)
            c.sendall(struct.pack('>HH',1,1)+b'\0'*16+struct.pack('>I',0))
            pixel_format=exact(c,20); count=struct.unpack('>H',exact(c,4)[2:])[0]; encodings=struct.unpack('>'+'i'*count,exact(c,count*4)); exact(c,10)
            if mode.startswith('zrle'): assert encodings[0]==16 and 0 in encodings
            if mode=='rgb565':
                expected_format=bytes([16,16,0,1,0,31,0,63,0,31,11,5,0,0,0,0])
                assert pixel_format==b'\0'*4+expected_format
            rectangle=b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,0)
            if attempt==0:
                if mode=='remote-payload-close':
                    c.sendall(rectangle+b'\0\0')
                else:
                    c.sendall(rectangle+b'\0\0\xff\0')
                    exact(c,10)
                deadline=time.monotonic()+5
                while not marker.exists():
                    assert time.monotonic()<deadline, 'client did not reach pre-close state'
                    time.sleep(.01)
                if mode=='remote-reset':
                    c.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,struct.pack('ii',1,0))
                else:
                    c.shutdown(socket.SHUT_WR)
            else:
                c.sendall(rectangle+b'\0\0\xff\0')
                exact(c,10)
                assert exact(c,8)==b'\x04\x01\0\0\0\0\0B', 'stale input reached retry session'
                c.sendall(b'\x03\0\0\0'+struct.pack('>I',8)+b'retry-ok')
                while c.recv(1024): pass

def serve_blackframe(listener, mode):
    fallback = mode in ('apple-black-fallback', 'apple-black-both')
    apple = mode != 'standard-black'
    for attempt in range(2 if fallback else 1):
        c,_ = listener.accept()
        with c:
            c.settimeout(5)
            banner = b'RFB 003.889\n' if apple else b'RFB 003.008\n'
            c.sendall(banner); assert exact(c,12)==banner
            c.sendall(b'\x01\x01'); assert exact(c,1)==b'\x01'
            c.sendall(b'\0'*4); assert exact(c,1)==(b'\xc1' if apple else b'\x01')
            c.sendall(struct.pack('>HH',2,2)+b'\0'*16+struct.pack('>I',0))
            if apple: exact(c,66)
            fmt=exact(c,20)
            assert fmt[4] == (32 if attempt else 16), 'fallback must renegotiate full color once'
            count=struct.unpack('>H',exact(c,4)[2:])[0]; exact(c,count*4); exact(c,10)
            w = 1 if mode=='apple-black-partial' else 2
            pixel = b'\0\0' if attempt==0 else (b'\0'*4 if mode=='apple-black-both' else b'\0\0\xff\0')
            c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,w,2,0)+pixel*(w*2))
            if fallback and attempt==0:
                expect_closed(c, 'black first frame must close before retry')
            else:
                exact(c,10)
                c.sendall(b'\x03\0\0\0'+struct.pack('>I',8)+b'black-ok')
                while c.recv(1024): pass

def serve(listener, mode, marker):
    stage = 'setup'
    try:
        if mode in ('apple-black-fallback','apple-black-both','apple-black-partial','standard-black'):
            serve_blackframe(listener,mode)
            return
        if mode in ('remote-close','remote-reset','remote-payload-close'):
            serve_disconnect(listener,mode,marker)
            return
        c,_=listener.accept()
        with c:
            c.settimeout(7)
            if mode=='deinit':
                assert c.recv(1)==b''
                return
            c.sendall(b'RFB 003.889\n' if mode=='apple-cursor' else (b'RFB 003.005\n' if mode=='vnc33' else b'RFB 003.008\n'))
            assert exact(c,12)==(b'RFB 003.889\n' if mode=='apple-cursor' else (b'RFB 003.003\n' if mode=='vnc33' else b'RFB 003.008\n'))
            if mode=='vnc33':
                challenge=bytes(range(16))
                c.sendall(struct.pack('>I',2)+challenge)
                key=bytes(int(f'{byte:08b}'[::-1],2) for byte in b'secret\0\0')
                expected=subprocess.run(['/usr/bin/openssl','enc','-des-ecb','-nopad','-K',key.hex()],input=challenge,capture_output=True,check=True).stdout
                assert exact(c,16)==expected
            elif mode in ('apple','apple-failure'):
                c.sendall(b'\x01\x1e'); assert exact(c,1)==b'\x1e'
                # RFC 2409 1024-bit MODP group, deterministic server exponent.
                prime=int('FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF',16)
                c.sendall(struct.pack('>HH',2,128)+prime.to_bytes(128,'big')+pow(2,7,prime).to_bytes(128,'big'))
                response=exact(c,256)
                shared=pow(int.from_bytes(response[128:],'big'),7,prime).to_bytes(128,'big')
                import hashlib
                credentials=subprocess.run(['/usr/bin/openssl','enc','-d','-aes-128-ecb','-nopad','-K',hashlib.md5(shared).hexdigest()],input=response[:128],capture_output=True,check=True).stdout
                assert credentials[:6]==b'alice\0' and credentials[64:71]==b'secret\0'
            else:
                c.sendall(b'\x01\x01'); exact(c,1)
            if mode=='apple-failure':
                c.sendall(struct.pack('>I',1))
                assert c.recv(1)==b'' # Apple sends no following reason length or body.
                return
            c.sendall(b'\0'*4); assert exact(c,1)==(b'\xc1' if mode=='apple-cursor' else b'\x01')
            dimensions=(18048,3384) if mode=='multi-display' else ((65535,65535) if mode=='oversized-init' else ((1024,1024) if mode in ('slow-raw','raw-chunk-timeout') else ((1031,608) if mode=='raw-chunks' else (1,1))))
            c.sendall(struct.pack('>HH',*dimensions)+b'\0'*16+struct.pack('>I',0))
            if mode=='oversized-init':
                expect_closed(c, 'oversized ServerInit must close before requesting pixels')
                return
            if mode=='apple-cursor':
                viewer=exact(c,66)
                mask=bytearray(32); mask[0]=0xb0; mask[2]=0xc; mask[3]=3; mask[4]=0x90; mask[10]=0x40
                assert viewer==struct.pack('>BBHHIIIIIII',0x21,0,62,1,2,6,1,0,15,3,0)+bytes(mask)
            pixel_format=exact(c,20); count=struct.unpack('>H',exact(c,4)[2:])[0]; encodings=struct.unpack('>'+'i'*count,exact(c,count*4)); exact(c,10)
            if mode.startswith('zrle'): assert encodings[0]==16 and 0 in encodings
            if mode=='rgb565':
                expected_format=bytes([16,16,0,1,0,31,0,63,0,31,11,5,0,0,0,0])
                assert pixel_format==b'\0'*4+expected_format
            stage = 'activity'
            if mode=='multi-display':
                def corners(width,height):
                    # Tiny Raw rectangles exercise full-frame offsets without a
                    # huge network payload or a second Python-side frame buffer.
                    result=b'\0\0\0\x04'
                    for (x,y),pixel in zip([(0,0),(width-1,0),(0,height-1),(width-1,height-1)],
                                           [b'\0\0\xff\0',b'\0\xff\0\0',b'\xff\0\0\0',b'\xff\xff\xff\0']):
                        result+=struct.pack('>HHHHi',x,y,1,1,0)+pixel
                    return result
                c.sendall(corners(*dimensions))
                exact(c,10)
                deadline=time.monotonic()+10
                while not marker.exists():
                    assert time.monotonic()<deadline, 'large initial corner validation did not finish'
                    time.sleep(.01)
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,10000,4000,-223))
                assert exact(c,10)==b'\x03\0'+struct.pack('>HHHH',0,0,10000,4000)
                c.sendall(corners(10000,4000))
                exact(c,10)
            elif mode=='oversized-resize':
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,0)+b'\0\0\xff\0')
                exact(c,10)
                deadline=time.monotonic()+5
                while not marker.exists():
                    assert time.monotonic()<deadline
                    time.sleep(.01)
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,65535,65535,-223))
                expect_closed(c, 'oversized resize must close without a new update request')
                return
            elif mode=='apple-cursor':
                assert 1104 in encodings and -239 not in encodings and -240 not in encodings
                c.sendall(bytes([0x14,0,0,4,0,1,0,12]))
                compressor=zlib.compressobj()
                payload=compressor.compress(bytes([10,20,30,0,128]))+compressor.flush(zlib.Z_SYNC_FLUSH)
                c.sendall(b'\0\0\0\x02'+struct.pack('>HHHHi',0,0,1,1,1104)+struct.pack('>II',1000,len(payload))+payload+struct.pack('>HHHHi',0,0,1,1,0)+b'\0\0\xff\0')
                exact(c,10)
                deadline=time.monotonic()+5
                while not marker.exists():
                    assert time.monotonic()<deadline
                    time.sleep(.01)
                # Unknown SELECT is ignored; known SELECT retains original geometry.
                c.sendall(b'\0\0\0\x02'+struct.pack('>HHHHi',0,0,0,0,1104)+struct.pack('>II',9999,0)+struct.pack('>HHHHi',0,0,0,0,1104)+struct.pack('>II',1000,0))
                exact(c,10)
                c.sendall(b'\x03\0\0\0'+struct.pack('>I',9)+b'cursor-ok')
            elif mode=='cursor':
                assert -239 in encodings and -240 in encodings and 1104 not in encodings
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',1,0,2,1,-239)+bytes([0,0,255,0,0,255,0,0,0xc0]))
                exact(c,10)
                deadline=time.monotonic()+5
                while not marker.exists():
                    assert time.monotonic()<deadline
                    time.sleep(.01)
                c.sendall(b'\0\0\0\x02'+struct.pack('>HHHHi',0,0,0,0,-239)+struct.pack('>HHHHi',0,0,1,1,0)+b'\0\0\xff\0')
                exact(c,10)
                deadline=time.monotonic()+5
                while not marker.with_suffix('.frame').exists():
                    assert time.monotonic()<deadline
                    time.sleep(.01)
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,-240)+bytes([255,0,0,0,255,0,128,128]))
                exact(c,10)
            elif mode=='rgb565':
                value=bytes([0x65,0x8c])
                compressor=zlib.compressobj()
                payload=compressor.compress(b'\x01'+value)+compressor.flush(zlib.Z_SYNC_FLUSH)
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,16)+struct.pack('>I',len(payload))+payload)
                exact(c,10)
                deadline=time.monotonic()+5
                while not marker.exists():
                    assert time.monotonic()<deadline
                    time.sleep(.01)
                # A server may still select Raw after ZRLE; its byte count must
                # follow the same negotiated format rather than RGBA storage.
                value=b'\xff'*(pixel_format[4]//8)
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,0)+value)
                exact(c,10)
            elif mode=='zrle':
                compressor=zlib.compressobj()
                payload=compressor.compress(b'\x01\x12\x34\x56')+compressor.flush(zlib.Z_SYNC_FLUSH)
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,16)+struct.pack('>I',len(payload))+payload)
                exact(c,10)
                deadline=time.monotonic()+5
                while not marker.exists():
                    assert time.monotonic()<deadline
                    time.sleep(.01)
                payload=compressor.compress(b'\x01\x98\x76\x54')+compressor.flush(zlib.Z_SYNC_FLUSH)
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,16)+struct.pack('>I',len(payload))+payload)
                exact(c,10)
            elif mode in ('zrle-bounds','zrle-length','zrle-bomb','zrle-palette','zrle-timeout'):
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',1 if mode=='zrle-bounds' else 0,0,1,1,16))
                if mode=='zrle-length': c.sendall(struct.pack('>I',100_000_000))
                elif mode=='zrle-timeout':
                    c.settimeout(25)
                    c.sendall(struct.pack('>I',64)+b'\x78')
                elif mode!='zrle-bounds':
                    compressor=zlib.compressobj()
                    data=b'\0'*1_000_000 if mode=='zrle-bomb' else b'\x82'+b'\0'*6+b'\x02'
                    payload=compressor.compress(data)+compressor.flush(zlib.Z_SYNC_FLUSH)
                    c.sendall(struct.pack('>I',len(payload))+payload)
            elif mode=='raw-chunks':
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',3,2,1025,600,0))
                for row in range(600):
                    c.sendall(bytes([row % 256, (row // 256) % 256, 91, 0]) * 1025)
                exact(c,10)
                c.sendall(b'\x03\0\0\0'+struct.pack('>I',8)+b'raw-done')
            elif mode=='raw-chunk-timeout':
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,0)+b'\0\0\xff\0')
                exact(c,10)
                # First frame already published: no first-frame watchdog can mask
                # the rectangle-wide deadline. A later chunk must not renew it.
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1024,1024,0)+b'\0'*(1024*1024))
                started=time.monotonic()
                time.sleep(13)
                c.sendall(b'\0'*(1024*1024))
                c.settimeout(15)
                assert c.recv(1)==b''
                assert 22 < time.monotonic()-started < 27
                return
            elif mode=='slow-raw':
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1024,1024,0))
                # A valid payload may take longer than the small-message deadline.
                time.sleep(21)
                c.sendall(b'\0\0\xff\0'*(1024*1024))
                exact(c,10)
            elif mode in ('first-frame','terminal-error'):
                c.sendall(b'\0\0\0\0') # empty update must not count as first frame
                exact(c,10)
                deadline=time.monotonic()+5
                while not marker.exists():
                    assert time.monotonic()<deadline, f'{mode}: no client readiness signal'
                    time.sleep(.01)
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,0)+b'\0\0\xff\0')
            elif mode=='resize-release':
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,0)+b'\0\0\xff\0')
                exact(c,10)
                assert exact(c,8)==b'\x04\x01\0\0\0\0\xff\xe3'
                assert exact(c,6)==b'\x05\x01\0\0\0\0'
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,2,2,-223))
                assert exact(c,10)==b'\x03\0\0\0\0\0\0\x02\0\x02'
                assert exact(c,8)==b'\x04\0\0\0\0\0\xff\xe3'
                assert exact(c,6)==b'\x05\0\0\0\0\0'
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,2,2,0)+b'\0\0\xff\0'*4)
                exact(c,10)
            elif mode=='resize-timeout':
                for _ in range(220):
                    c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,-223))
                    assert exact(c,10)==b'\x03\0\0\0\0\0\0\x01\0\x01'
                    time.sleep(.1)
            elif mode=='first-frame-timeout':
                for _ in range(430):
                    # None of these messages contains a pixel or earns more time.
                    c.sendall(b'\x02'+b'\0\0\0\0')
                    exact(c,10)
                    c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,0,0,0))
                    exact(c,10)
                    time.sleep(.05)
            elif mode in ('clipboard','apple','apple-failure','vnc33'):
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,0)+b'\0\0\xff\0')
                exact(c,10)
                if mode=='clipboard':
                    c.sendall(b'\x03\0\0\0'+struct.pack('>I',4)+b'caf\xe9')
                    assert exact(c,8)==b'\x06\0\0\0'+struct.pack('>I',4)
                    assert exact(c,4)==b'caf\xe9'
                    for _ in range(50):
                        assert exact(c,8)==b'\x04\x01\0\0\0\0\0A'
                        assert exact(c,8)==b'\x04\0\0\0\0\0\0A'
                    c.sendall(b'\x03\0\0\0'+struct.pack('>I',14)+b'input-complete')
            elif mode=='malformed':
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',1,0,1,1,0))
            if mode not in ('first-frame-timeout','resize-timeout'):
                while c.recv(1024): pass
        if mode=='reconnect':
            c,_=listener.accept()
            with c:
                c.settimeout(7)
                assert c.recv(1)==b''
    except (EOFError, BrokenPipeError, ConnectionResetError) as error:
        if stage != 'activity' or mode not in ('terminal-error','first-frame-timeout','resize-timeout'):
            errors.append(AssertionError(f'{mode}: unexpected disconnect before all protocol assertions completed: {error}'))
    except Exception as error: errors.append(error)
for mode in ['raw-chunk-timeout','raw-chunks','multi-display','oversized-init','oversized-resize','apple-cursor','cursor','rgb565','zrle','zrle-bounds','zrle-length','zrle-bomb','zrle-palette','zrle-timeout','remote-close','remote-reset','remote-payload-close','slow-raw','first-frame','reconnect','malformed','clipboard','apple','apple-failure','vnc33','deinit','terminal-error','resize-release','first-frame-timeout','resize-timeout']:
    selected = next((arg.split('=', 1)[1] for arg in sys.argv if arg.startswith('--case=')), None)
    if selected and mode != selected: continue
    if '--resize-only' in sys.argv and mode!='resize-timeout': continue
    if '--quick' in sys.argv and mode in ('raw-chunk-timeout','zrle-timeout','slow-raw','first-frame-timeout','resize-timeout'): continue
    with socket.socket() as listener:
        listener.bind(('127.0.0.1',0)); listener.listen(); listener.settimeout(3)
        marker=binary.parent / f'{mode}-ready'
        thread=threading.Thread(target=serve,args=(listener,mode,marker),daemon=True); thread.start()
        subprocess.run([str(binary),str(listener.getsockname()[1]),mode,str(marker)],check=True,timeout=30)
        thread.join(timeout=3)
        assert not thread.is_alive(), f"{mode}: fake server did not finish protocol assertions"
        if errors: raise errors[0]

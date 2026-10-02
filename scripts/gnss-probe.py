#!/usr/bin/env python3
"""Bring-up probe for the LC29H on a Pi: try bauds, send PQTMVERNO, print replies.

Runs ON the Pi (stdlib only, so it works on a fresh card). Stop rtkd first.
  usage: gnss-probe.py [device] [baud ...]
"""
import os, sys, time, termios, select

DEV = sys.argv[1] if len(sys.argv) > 1 else "/dev/serial0"
BAUDS = [int(b) for b in sys.argv[2:]] or [115200, 460800, 38400, 9600]
SPEED = {9600: termios.B9600, 38400: termios.B38400, 115200: termios.B115200,
         230400: termios.B230400, 460800: termios.B460800}

def nmea(body):
    c = 0
    for ch in body.encode():
        c ^= ch
    return "$%s*%02X\r\n" % (body, c)

def probe(baud, listen=1.5):
    fd = os.open(DEV, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = 0; a[1] = 0; a[3] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[4] = a[5] = SPEED[baud]
    a[6][termios.VMIN] = 0; a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    buf = b""
    def pump(t):
        nonlocal buf
        end = time.time() + t
        while time.time() < end:
            if select.select([fd], [], [], 0.05)[0]:
                buf += os.read(fd, 4096)
    pump(listen)
    passive = len(buf)
    os.write(fd, nmea("PQTMVERNO").encode())
    pump(1.0)
    os.close(fd)
    return passive, buf

for b in BAUDS:
    passive, buf = probe(b)
    n_nmea = buf.count(b"$G")
    n_rtcm = buf.count(b"\xd3")
    print("== %s @ %d: %d bytes passive, %d total, %d '$G' sentences, %d 0xD3 bytes"
          % (DEV, b, passive, len(buf), n_nmea, n_rtcm))
    for line in buf.split(b"\r\n"):
        if b"PQTM" in line or b"PAIR" in line:
            print("   ", line.decode("ascii", "replace"))
    if n_nmea and b"PQTMVERNO" in buf:
        print("   -> responsive at %d" % b); break
    if len(buf) == 0:
        print("   (silence)")

#!/usr/bin/env python3
"""Send NMEA command bodies to the LC29H and print the reply lines. Runs ON the Pi.
Stop rtkd first. Bodies are given without '$' and checksum.
  usage: gnss-cmd.py [-d dev] [-b baud] [-t secs] BODY [BODY ...]
  e.g.   gnss-cmd.py PQTMVERNO PQTMCFGSVIN,R
"""
import os, sys, time, termios, select, argparse

def nmea(body):
    c = 0
    for ch in body.encode():
        c ^= ch
    return "$%s*%02X\r\n" % (body, c)

ap = argparse.ArgumentParser()
ap.add_argument("-d", default="/dev/serial0"); ap.add_argument("-b", type=int, default=115200)
ap.add_argument("-t", type=float, default=1.2); ap.add_argument("bodies", nargs="+")
a = ap.parse_args()
sp = {9600: termios.B9600, 38400: termios.B38400, 115200: termios.B115200, 230400: termios.B230400, 460800: termios.B460800}[a.b]
fd = os.open(a.d, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
t = termios.tcgetattr(fd)
t[0] = t[1] = t[3] = 0; t[2] = termios.CS8 | termios.CREAD | termios.CLOCAL; t[4] = t[5] = sp
t[6][termios.VMIN] = 0; t[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, t)
termios.tcflush(fd, termios.TCIOFLUSH)

def drain(secs):
    buf = b""; end = time.time() + secs
    while time.time() < end:
        if select.select([fd], [], [], 0.05)[0]:
            buf += os.read(fd, 4096)
    return buf

drain(0.3)
for body in a.bodies:
    os.write(fd, nmea(body).encode())
    buf = drain(a.t)
    print(">> $%s" % body)
    for ln in buf.split(b"\r\n"):
        s = ln.decode("ascii", "replace")
        if "$PQTM" in s or "$PAIR" in s:
            print("   <<", s[s.index("$"):])
    print("   (%d bytes, %d RTCM sync bytes, %d NMEA lines)" % (len(buf), buf.count(b"\xd3"), buf.count(b"\r\n")))

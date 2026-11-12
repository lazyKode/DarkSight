#!/usr/bin/env python3
"""Send synthetic DSRD range-Doppler frames to DarkSight over UDP.

Stands in for a real bridge (Raspberry Pi + SDR) so the Tier 3 Wi-Fi link can
be tested from a PC:

    python mock_sdr_streamer.py <phone-ip> [--port 4210] [--fps 15]

For the Android emulator, forward the port first and target localhost:

    adb emu redir add udp:4210:4210
    python mock_sdr_streamer.py 127.0.0.1

Packet layout (little endian), version 1:
    0  char[4] "DSRD"     4  u16 version      6  u16 nRange
    8  u16 nDoppler       10 u16 reserved     12 f32 maxRange (m)
    16 f32 maxVelocity    20 u8[nRange*nDoppler] log intensity, row = range bin
"""
import argparse
import math
import random
import socket
import struct
import time

N_RANGE, N_DOPPLER = 64, 32
MAX_RANGE, MAX_VEL = 10.0, 4.0


def frame(t: float) -> bytes:
    grid = [[random.randint(20, 45) for _ in range(N_DOPPLER)] for _ in range(N_RANGE)]

    def blob(rng_m: float, vel: float, level: int, spread: int = 1) -> None:
        k = int(rng_m / MAX_RANGE * N_RANGE)
        d = int(vel / MAX_VEL * N_DOPPLER / 2 + N_DOPPLER / 2)
        for dk in range(-spread, spread + 1):
            for dd in range(-spread, spread + 1):
                kk, ddd = k + dk, d + dd
                if 0 <= kk < N_RANGE and 0 <= ddd < N_DOPPLER:
                    fall = level - 35 * (abs(dk) + abs(dd))
                    grid[kk][ddd] = max(grid[kk][ddd], fall)

    for r in (7.8, 8.0, 8.2, 8.4):          # static wall at zero Doppler
        blob(r, 0.0, 190, 0)
    r = 4.5 + 1.5 * math.sin(0.4 * t)        # a walker
    v = 1.5 * 0.4 * math.cos(0.4 * t)
    blob(r, v, 230)
    blob(r, v + 0.8 * math.sin(6 * t), 150, 0)  # limb micro-Doppler

    header = b"DSRD" + struct.pack("<HHHHff", 1, N_RANGE, N_DOPPLER, 0, MAX_RANGE, MAX_VEL)
    return header + bytes(v for row in grid for v in row)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("host")
    ap.add_argument("--port", type=int, default=4210)
    ap.add_argument("--fps", type=float, default=15)
    args = ap.parse_args()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    t0 = time.time()
    print(f"streaming DSRD frames to {args.host}:{args.port} at {args.fps} fps (Ctrl+C to stop)")
    while True:
        sock.sendto(frame(time.time() - t0), (args.host, args.port))
        time.sleep(1 / args.fps)


if __name__ == "__main__":
    main()

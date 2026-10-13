#!/usr/bin/env python3
"""Synthesizes Hushtype's UI sounds (no samples, no third-party audio). Writes 44.1 kHz mono WAVs.

Three sets, each with start / stop / cancel:
  droplet — a soft water-drop pitch glide (up to start, down to stop)
  marimba — two warm mallet notes (rising to start, falling to stop)
  glass   — a bright glass-bell ping with a short shimmer
usage: make_sounds.py <out-dir> [set]
"""
import math, struct, sys, wave, os

SR = 44100

def env(t, attack, decay):
    return (t / attack if t < attack else math.exp(-(t - attack) / decay))

def reverb(x, mix=0.18):
    # Tiny Schroeder-style room: three feedback combs, summed.
    out = list(x)
    for d_ms, g in ((29.7, 0.55), (37.1, 0.5), (41.1, 0.45)):
        d = int(SR * d_ms / 1000); buf = [0.0] * len(x)
        for i in range(len(x)):
            buf[i] = x[i] + (g * buf[i - d] if i >= d else 0)
        out = [o + mix * b / 3 for o, b in zip(out, buf)]
    return out

def normalize(x, peak=0.55):
    m = max(1e-9, max(abs(v) for v in x))
    return [v * peak / m for v in x]

def fade_tail(x, ms=30):
    n = int(SR * ms / 1000)
    for i in range(n):
        x[-n + i] *= 1 - i / n
    return x

def tone(dur, f_of_t, partials, attack=0.004, decay=0.12, click=0.0):
    n = int(SR * dur); out = []; phase = [0.0] * len(partials)
    for i in range(n):
        t = i / SR; f = f_of_t(t); v = 0.0
        for k, (mult, amp, dmul) in enumerate(partials):
            phase[k] += 2 * math.pi * f * mult / SR
            v += amp * math.sin(phase[k]) * env(t, attack, decay * dmul)
        if click and t < 0.004:
            v += click * (1 - t / 0.004) * math.sin(2 * math.pi * 3200 * t)
        out.append(v)
    return out

def seq(*parts):
    """parts: (offset_seconds, samples)"""
    n = max(int(o * SR) + len(s) for o, s in parts)
    out = [0.0] * n
    for o, s in parts:
        j = int(o * SR)
        for i, v in enumerate(s):
            out[j + i] += v
    return out

def droplet(up=True, cancel=False):
    if cancel:
        f0, f1, d = 420, 300, 0.16
    else:
        f0, f1, d = (560, 980, 0.20) if up else (900, 520, 0.20)
    glide = 0.07
    f = lambda t: f0 + (f1 - f0) * min(1, t / glide) ** 0.6
    return tone(d + 0.15, f, [(1, 1.0, 1), (2, 0.18, 0.5)], attack=0.003, decay=0.075)

MAR = [(1, 1.0, 1), (4, 0.30, 0.25), (9.8, 0.08, 0.12)]

def marimba(up=True, cancel=False):
    note = lambda hz, dec=0.16: tone(0.45, lambda t: hz, MAR, attack=0.002, decay=dec, click=0.15)
    if cancel:
        return note(330, 0.10)
    a, b = (659.25, 987.77) if up else (987.77, 659.25)
    return seq((0, note(a)), (0.085, [v * 0.9 for v in note(b)]))

def glass(up=True, cancel=False):
    def bell(hz, dec):
        # Inharmonic partials give the glassy ring.
        return tone(0.7, lambda t: hz, [(1, 1.0, 1), (2.76, 0.45, 0.55), (5.40, 0.22, 0.35), (8.93, 0.10, 0.2)],
                    attack=0.001, decay=dec)
    if cancel:
        return bell(520, 0.09)
    return bell(1568 if up else 1175, 0.22)

SETS = {"droplet": droplet, "marimba": marimba, "glass": glass}

def write(path, x):
    x = fade_tail(normalize(reverb(x)))
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v)) * 32767)) for v in x))

if __name__ == "__main__":
    out = sys.argv[1]; only = sys.argv[2] if len(sys.argv) > 2 else None
    os.makedirs(out, exist_ok=True)
    for name, fn in SETS.items():
        if only and name != only: continue
        write(f"{out}/{name}-start.wav", fn(True))
        write(f"{out}/{name}-stop.wav", fn(False))
        write(f"{out}/{name}-cancel.wav", fn(True, cancel=True))
        print(name)
